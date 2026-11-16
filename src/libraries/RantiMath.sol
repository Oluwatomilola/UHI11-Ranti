// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title RantiMath
/// @notice Pure maths for valuation, the high-water-mark fee, track-record statistics and capacity.
library RantiMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 2 ** 96;
    uint256 internal constant BPS = 10_000;

    /// @notice Value of (amount0, amount1) in token1 units at sqrtPriceX96.
    function value(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        if (amount0 == 0) return amount1;
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, Q96), sqrtPriceX96, Q96) + amount1;
    }

    /// @notice nav / hodl - 1, in WAD. Positive means the position beat simply holding.
    function excessReturn(uint256 nav, uint256 hodl) internal pure returns (int256) {
        if (hodl == 0) return 0;
        return int256(FullMath.mulDiv(nav, WAD, hodl)) - int256(WAD);
    }

    /// @notice High-water-mark performance fee, crystallised as dilutive shares.
    /// @dev The fee base is the gain per share above BOTH the previous peak and the HODL benchmark,
    /// so a curator is never paid for recovering a drawdown or for pure price drift.
    /// Share maths follows Enzyme: f = F * S / (NAV - F), which leaves price per share at p - F/S.
    /// @param nav Vault value (token1 units) before the fee.
    /// @param supply Share supply before the fee.
    /// @param hwm Current high-water mark (price per share, WAD).
    /// @param hodlPps Price per share the vault would have had by holding its start-of-epoch tokens (WAD).
    /// @param feeBps Performance fee rate.
    /// @return feeShares Shares to mint to the curator escrow.
    /// @return newHwm Updated high-water mark (never decreases).
    function performanceFee(uint256 nav, uint256 supply, uint256 hwm, uint256 hodlPps, uint256 feeBps)
        internal
        pure
        returns (uint256 feeShares, uint256 newHwm)
    {
        if (supply == 0 || nav == 0) return (0, hwm);
        uint256 pps = FullMath.mulDiv(nav, WAD, supply);
        uint256 base = hwm > hodlPps ? hwm : hodlPps;
        if (pps > base) {
            uint256 feeValue = FullMath.mulDiv(pps - base, supply, WAD) * feeBps / BPS;
            if (feeValue > 0 && feeValue < nav) {
                feeShares = FullMath.mulDiv(feeValue, supply, nav - feeValue);
            }
        }
        uint256 ppsAfter = FullMath.mulDiv(nav, WAD, supply + feeShares);
        newHwm = ppsAfter > hwm ? ppsAfter : hwm;
    }

    /// @notice One-sided significance test: is the mean excess return more than z standard errors above zero?
    /// @param n Number of observations.
    /// @param sumX Sum of excess returns (WAD).
    /// @param sumX2 Sum of squared excess returns (WAD, i.e. x*x/1e18 summed).
    /// @param zWad z-score threshold (WAD). 1e18 = one standard error.
    function passesSignificance(uint256 n, int256 sumX, uint256 sumX2, uint256 zWad) internal pure returns (bool) {
        if (n < 2 || sumX <= 0) return false;
        uint256 sum = uint256(sumX);
        uint256 mean = sum / n;
        uint256 sumSqOverN = FullMath.mulDiv(sum, mean, WAD);
        uint256 variance = sumX2 > sumSqOverN ? (sumX2 - sumSqOverN) / (n - 1) : 0;
        // mean > z * sigma / sqrt(n)  <=>  mean^2 * n > z^2 * variance
        uint256 lhs = FullMath.mulDiv(mean, mean, WAD) * n;
        uint256 rhs = FullMath.mulDiv(FullMath.mulDiv(zWad, zWad, WAD), variance, WAD);
        return lhs > rhs;
    }

    /// @notice Token amounts held by `liquidity` in [tickLower, tickUpper) at sqrtPriceX96.
    /// @dev Rounds up: holdings are over-estimated, so pro-rata deposits mint slightly fewer
    /// shares (never more) and the capacity check is conservative.
    function amountsForLiquidity(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidity == 0) return (0, 0);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, true);
        } else if (sqrtPriceX96 < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, true);
        }
    }

    function floorTick(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}

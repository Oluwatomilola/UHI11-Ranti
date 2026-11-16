// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IRantiStrategy} from "../interfaces/IRantiStrategy.sol";

/// @title CenteredRangeStrategy
/// @notice Re-centres a fixed-width range on the TWAP tick every epoch.
/// Deploy it with a small half-width for a "narrow" strategy (more fees, more IL)
/// or a large one for a "wide" strategy (fewer fees, less IL).
contract CenteredRangeStrategy is IRantiStrategy {
    int24 public immutable halfWidth;
    string private _name;

    error InvalidWidth();

    constructor(string memory name_, int24 halfWidth_) {
        if (halfWidth_ <= 0) revert InvalidWidth();
        _name = name_;
        halfWidth = halfWidth_;
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function getRange(int24 twapTick, int24 tickSpacing) external view returns (int24 tickLower, int24 tickUpper) {
        int24 centre = _floor(twapTick, tickSpacing);
        int24 half = _floor(halfWidth, tickSpacing);
        if (half < tickSpacing) half = tickSpacing;

        tickLower = centre - half;
        tickUpper = centre + half + tickSpacing;

        int24 minTick = TickMath.minUsableTick(tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(tickSpacing);
        if (tickLower < minTick) tickLower = minTick;
        if (tickUpper > maxTick) tickUpper = maxTick;
    }

    function _floor(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RantiHook} from "../src/RantiHook.sol";

/// @notice Generates swap flow on a deployed Ranti pool so shadows earn a track record.
///
///   HOOK=0x... forge script script/Flow.s.sol --rpc-url unichain_sepolia --broadcast --private-key $PK
///
/// Env: HOOK (required), ROUNDS (default 5), AMOUNT (default 3e18), TREND ("true" for one-way flow),
///      SWAP_ROUTER (default: Unichain Sepolia PoolSwapTest 0x9140a78c1a137c7ff1c151ec8231272af78a99a4)
/// Then close the epoch once it has elapsed:  cast send $HOOK "settleEpoch()" --private-key $PK
contract Flow is Script {
    address internal constant UNICHAIN_SEPOLIA_SWAP_TEST = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    function run() external {
        RantiHook hook = RantiHook(vm.envAddress("HOOK"));
        PoolSwapTest router = PoolSwapTest(vm.envOr("SWAP_ROUTER", UNICHAIN_SEPOLIA_SWAP_TEST));
        uint256 rounds = vm.envOr("ROUNDS", uint256(5));
        uint256 amount = vm.envOr("AMOUNT", uint256(3e18));
        bool trend = vm.envOr("TREND", false);

        (Currency c0, Currency c1, uint24 fee, int24 spacing, IHooks hooks) = hook.poolKey();
        PoolKey memory key = PoolKey(c0, c1, fee, spacing, hooks);
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);

        vm.startBroadcast();
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);

        for (uint256 i; i < rounds; ++i) {
            bool zeroForOne = trend ? true : i % 2 == 0;
            router.swap(key, _params(zeroForOne, amount), settings, "");
            if (!trend) router.swap(key, _params(!zeroForOne, amount * 997 / 1000), settings, "");
        }
        vm.stopBroadcast();

        (int24 twapTick, uint32 window) = hook.twap();
        console2.log("swaps done; TWAP tick", int256(twapTick));
        console2.log("TWAP window (s)", uint256(window));
    }

    function _params(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }
}

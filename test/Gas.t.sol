// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {RantiTestBase} from "./utils/RantiTestBase.sol";

/// @notice Gas measurements for the README. Run: forge test --mc RantiGas -vv
contract RantiGas is RantiTestBase {
    function test_gas_profile() public {
        _bootstrapLive(); // vault live + 2 shadows
        _register(curatorC, medium, BOND); // 3 shadows
        _settle();
        _deposit(lp, 100e18);

        vm.warp(vm.getBlockTimestamp() + 13);
        uint256 g = gasleft();
        swap(poolKey, true, -int256(1e18), ZERO_BYTES);
        console2.log("swap, first in block (oracle write):", g - gasleft());

        g = gasleft();
        swap(poolKey, false, -int256(1e18), ZERO_BYTES);
        console2.log("swap, same block (no oracle write): ", g - gasleft());

        g = gasleft();
        vm.prank(lp2);
        hook.deposit(10e18, 10e18, 0, lp2, vm.getBlockTimestamp());
        console2.log("deposit:                            ", g - gasleft());

        uint256 s = hook.balanceOf(lp2);
        g = gasleft();
        vm.prank(lp2);
        hook.withdraw(s, 0, 0, lp2, vm.getBlockTimestamp());
        console2.log("withdraw:                           ", g - gasleft());

        _churn(5, 3e18);
        vm.warp(vm.getBlockTimestamp() + EPOCH);
        g = gasleft();
        hook.settleEpoch();
        console2.log("settleEpoch (vault + 3 shadows):    ", g - gasleft());
    }
}

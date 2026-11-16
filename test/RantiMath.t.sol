// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RantiMath} from "../src/libraries/RantiMath.sol";

contract RantiMathTest is Test {
    uint256 constant WAD = 1e18;

    // ------------------------------------------------------------------
    // High-water-mark fee: worked examples
    // ------------------------------------------------------------------

    function test_feeOnlyOnGainAbovePeak() public pure {
        // pps 1.10, HWM 1.00, HODL 1.00, 20% fee on the 0.10 gain
        (uint256 f, uint256 h) = RantiMath.performanceFee(110e18, 100e18, WAD, WAD, 2_000);
        // fee value = 0.2 * 0.10 * 100 = 2 ; f = 2 * 100 / (110 - 2)
        assertEq(f, uint256(2e18) * 100e18 / 108e18);
        assertApproxEqAbs(h, 108e16, 1, "pps after fee = 1.10 - 0.02");
    }

    function test_noFeeOnRecoveryToPeak() public pure {
        // Peak was 1.00; vault dipped and is back to exactly 1.00.
        (uint256 f, uint256 h) = RantiMath.performanceFee(100e18, 100e18, WAD, 0.95e18, 2_000);
        assertEq(f, 0);
        assertEq(h, WAD);
    }

    function test_feeOnlyOnIncrementAboveOldPeak() public pure {
        // Epoch 3 down 5%, epoch 4 back to peak (no fee), epoch 5 at 1.02 -> fee on 0.02 only.
        (uint256 f,) = RantiMath.performanceFee(102e18, 100e18, WAD, 0.99e18, 1_000);
        uint256 feeValue = uint256(2e16) * 100e18 / WAD * 1_000 / 10_000; // 0.2
        assertEq(f, feeValue * 100e18 / (102e18 - feeValue));
    }

    function test_noFeeForBetaWhenHodlDidBetter() public pure {
        // Price went up: vault 1.08, but holding would have given 1.10. Above HWM, below HODL.
        (uint256 f, uint256 h) = RantiMath.performanceFee(108e18, 100e18, WAD, 1.10e18, 2_000);
        assertEq(f, 0, "no pay for beta");
        assertEq(h, 1.08e18, "peak still moves up");
    }

    function test_feeOnlyOnPartAboveHodl() public pure {
        // HWM 1.00, HODL 1.05, vault 1.08: fee on the 0.03 of skill only.
        (uint256 f,) = RantiMath.performanceFee(108e18, 100e18, WAD, 1.05e18, 2_000);
        uint256 feeValue = uint256(3e16) * 100e18 / WAD * 2_000 / 10_000;
        assertEq(f, feeValue * 100e18 / (108e18 - feeValue));
    }

    // ------------------------------------------------------------------
    // High-water-mark fee: properties
    // ------------------------------------------------------------------

    function testFuzz_hwmNeverDecreases(uint256 nav, uint256 supply, uint256 hwm, uint256 hodl, uint16 bps)
        public
        pure
    {
        nav = bound(nav, 1e6, 1e30);
        supply = bound(supply, 1e6, 1e30);
        hwm = bound(hwm, 0, 1e24);
        hodl = bound(hodl, 0, 1e24);
        bps = uint16(bound(bps, 0, 5_000));
        (, uint256 h) = RantiMath.performanceFee(nav, supply, hwm, hodl, bps);
        assertGe(h, hwm);
    }

    function testFuzz_feeNeverExceedsRateTimesGain(uint256 nav, uint256 supply, uint256 hwm, uint256 hodl, uint16 bps)
        public
        pure
    {
        nav = bound(nav, 1e9, 1e30);
        supply = bound(supply, 1e9, 1e30);
        hwm = bound(hwm, 1e9, 1e24);
        hodl = bound(hodl, 0, 1e24);
        bps = uint16(bound(bps, 1, 5_000));
        (uint256 f,) = RantiMath.performanceFee(nav, supply, hwm, hodl, bps);
        uint256 pps = nav * WAD / supply;
        uint256 base = hwm > hodl ? hwm : hodl;
        if (pps <= base) {
            assertEq(f, 0, "no gain above base, no fee");
        } else {
            // value of fee shares at post-fee price <= bps * gain * supply (+ rounding)
            uint256 feeValue = f * nav / (supply + f);
            uint256 maxFee = (pps - base) * supply / WAD * bps / 10_000;
            assertLe(feeValue, maxFee + 1);
        }
    }

    function testFuzz_lpsKeepAtLeastBaseAfterFee(uint256 nav, uint256 supply, uint256 hwm, uint16 bps) public pure {
        nav = bound(nav, 1e12, 1e30);
        supply = bound(supply, 1e12, 1e30);
        hwm = bound(hwm, 1e12, 1e24);
        bps = uint16(bound(bps, 0, 5_000));
        (uint256 f,) = RantiMath.performanceFee(nav, supply, hwm, 0, bps);
        uint256 pps = nav * WAD / supply;
        uint256 ppsAfter = nav * WAD / (supply + f);
        if (pps > hwm) assertGe(ppsAfter + 1, hwm, "a fee never pushes LPs below the old peak");
    }

    // ------------------------------------------------------------------
    // Significance test
    // ------------------------------------------------------------------

    function test_consistentPositiveReturnsPass() public pure {
        // 5 epochs of ~ +0.10% with tiny noise
        int256[5] memory xs = [int256(1.0e15), 1.1e15, 0.9e15, 1.05e15, 0.95e15];
        (int256 s, uint256 s2) = _sums(xs);
        assertTrue(RantiMath.passesSignificance(5, s, s2, WAD));
    }

    function test_noisyReturnsFail() public pure {
        // mean +0.04% but swings of +-1%: not distinguishable from luck
        int256[5] memory xs = [int256(1e16), -1e16, 1.1e16, -0.9e16, 0.2e15];
        (int256 s, uint256 s2) = _sums(xs);
        assertFalse(RantiMath.passesSignificance(5, s, s2, WAD));
    }

    function test_negativeMeanFails() public pure {
        int256[3] memory xs = [int256(-1e15), -1e15, -1e15];
        int256 s;
        uint256 s2;
        for (uint256 i; i < 3; ++i) {
            s += xs[i];
            s2 += uint256(xs[i] * xs[i]) / WAD;
        }
        assertFalse(RantiMath.passesSignificance(3, s, s2, WAD));
    }

    function test_excessReturn() public pure {
        assertEq(RantiMath.excessReturn(101e18, 100e18), 0.01e18);
        assertEq(RantiMath.excessReturn(99e18, 100e18), -0.01e18);
        assertEq(RantiMath.excessReturn(1, 0), 0);
    }

    function test_valueAtPriceOne() public pure {
        uint160 sqrtOne = uint160(1 << 96);
        assertEq(RantiMath.value(3e18, 4e18, sqrtOne), 7e18);
    }

    function testFuzz_floorTick(int24 tick) public pure {
        tick = int24(bound(int256(tick), -887_000, 887_000));
        int24 f = RantiMath.floorTick(tick, 60);
        assertEq(f % 60, 0);
        assertLe(f, tick);
        assertGt(int256(f) + 60, int256(tick));
    }

    function _sums(int256[5] memory xs) internal pure returns (int256 s, uint256 s2) {
        for (uint256 i; i < 5; ++i) {
            s += xs[i];
            s2 += uint256(xs[i] * xs[i]) / WAD;
        }
    }
}

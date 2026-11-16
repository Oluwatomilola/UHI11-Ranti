// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {RantiTestBase} from "./utils/RantiTestBase.sol";
import {RantiHook} from "../src/RantiHook.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {CenteredRangeStrategy} from "../src/strategies/CenteredRangeStrategy.sol";

/// @notice Narrated end-to-end run of the Ranti lifecycle.
/// Run: forge test --mc RantiDemo -vv
contract RantiDemo is RantiTestBase {
    uint256 internal nId;
    uint256 internal wId;
    uint256 internal cId;

    function test_demo() public {
        _h("1. SHADOW MODE: two curators bond their own capital");
        nId = _register(curatorA, narrow, BOND);
        wId = _register(curatorB, wide, BOND);
        console2.log("  Curator A registers 'Narrow +-1.2%%', bond 100 + 100   -> strategy #%s", nId);
        console2.log("  Curator B registers 'Wide +-27%%',    bond 100 + 100   -> strategy #%s", wId);
        _settle();
        console2.log("  Epoch 0 settled: both bonds deployed at their ranges in the live pool.");

        _h("2. TRACK RECORD: every epoch scored against HODL by the hook itself");
        for (uint256 i; i < 3; ++i) {
            _churnEpoch();
            uint32 e = hook.epoch() - 1;
            console2.log(
                string.concat(
                    "  Epoch ",
                    vm.toString(e),
                    ":  Narrow ",
                    _bps(registry.shadowReturn(nId, e)),
                    "   Wide ",
                    _bps(registry.shadowReturn(wId, e))
                )
            );
        }
        console2.log(string.concat("  Narrow stage: ", _stage(nId), "   Wide stage: ", _stage(wId)));

        _h("3. GRADUATION -> LIVE on probation (no incumbent, so no timelock)");
        hook.proposeUpgrade(nId);
        _settle();
        (,,, uint256 cap0) = registry.info(nId);
        console2.log(string.concat("  Live strategy: #", vm.toString(hook.liveId()), " (", _stage(nId), ")"));
        console2.log(string.concat("  Starting capacity (2x bond value): ", _fmt(cap0)));

        _h("4. PERFORMANCE-GATED CAPACITY");
        vm.prank(lp);
        try hook.deposit(250e18, 250e18, 0, lp, vm.getBlockTimestamp()) {
            console2.log("  unexpected: deposit above cap succeeded");
        } catch {
            console2.log("  LP tries to deposit 250 + 250 (~500 value): REVERTED, CapExceeded");
        }
        uint256 lpShares = _deposit(lp, 150e18);
        console2.log(string.concat("  LP deposits 150 + 150 instead: ", _fmt(lpShares), " shares"));

        _h("5. HIGH-WATER-MARK FEE, streamed from escrow");
        uint256 hwm0 = hook.highWaterMark();
        _churnEpoch();
        uint32 e5 = hook.epoch() - 1;
        console2.log(string.concat("  Vault vs HODL this epoch: ", _bps(hook.vaultReturn(e5))));
        console2.log(
            string.concat("  HWM: ", _fmt6(hwm0), " -> ", _fmt6(hook.highWaterMark()), " (price per share)")
        );
        console2.log(string.concat("  Fee shares minted to escrow: ", _fmt6(escrow.atRisk(nId))));
        (,,, uint256 cap1) = registry.info(nId);
        console2.log(string.concat("  Capacity grew on verified excess return: ", _fmt(cap0), " -> ", _fmt(cap1)));
        vm.warp(vm.getBlockTimestamp() + EPOCH / 2);
        console2.log(string.concat("  Half an epoch later, curator can claim: ", _fmt6(escrow.claimable(nId))));
        vm.prank(curatorA);
        uint256 claimed = escrow.claim(nId);
        console2.log(string.concat("  Curator A claims ", _fmt6(claimed), " shares; rest still vesting"));

        _h("6. CLAWBACK: informed flow pushes price through the range");
        uint256 atRisk = escrow.atRisk(nId);
        _trend(3, 60e18, true);
        vm.recordLogs();
        _settle();
        uint32 e6 = hook.epoch() - 1;
        console2.log(string.concat("  Vault vs HODL this epoch: ", _bps(hook.vaultReturn(e6))));
        console2.log(
            string.concat("  Escrow at risk: ", _fmt6(atRisk), " -> ", _fmt6(escrow.atRisk(nId)), " shares (burned for LPs)")
        );
        console2.log(string.concat("  Curator bond slashed into the vault (value): ", _fmt6(_lastSlash())));
        console2.log(string.concat("  Vesting paused below HWM: ", escrow.getStream(nId).paused ? "yes" : "no"));
        console2.log(string.concat("  LP shares unchanged: ", _fmt(hook.balanceOf(lp))));

        _h("7. CHALLENGER builds a record in shadow while the incumbent manages the vault");
        CenteredRangeStrategy narrower = new CenteredRangeStrategy("Narrower +-0.6%", 60);
        cId = _register(curatorC, narrower, BOND);
        console2.log("  Curator C registers 'Narrower +-0.6%%' -> strategy #%s", cId);
        for (uint256 i; i < 4; ++i) {
            _churnEpoch();
            uint32 e = hook.epoch() - 1;
            string memory c = registry.getStrategy(cId).shadowEpochs == 0 || registry.getStrategy(cId).firstMeasuredEpoch > e
                ? "(deploying)"
                : _bps(registry.shadowReturn(cId, e));
            console2.log(
                string.concat(
                    "  Epoch ",
                    vm.toString(e),
                    ":  Incumbent (shadow bond) ",
                    _bps(registry.shadowReturn(nId, e)),
                    "   Challenger ",
                    c
                )
            );
        }
        console2.log(string.concat("  Challenger stage: ", _stage(cId)));

        _h("8. MIGRATION WITHOUT LP EXIT");
        hook.proposeUpgrade(cId);
        console2.log(
            string.concat("  Upgrade proposed; executes after epoch ", vm.toString(hook.upgradeReadyEpoch()), " (LPs may exit)")
        );
        uint256 sharesBefore = hook.balanceOf(lp);
        _churnEpoch();
        uint256 hwmBefore = hook.highWaterMark();
        _churnEpoch();
        RantiHook.Bucket memory v = hook.getBucket(0);
        console2.log(string.concat("  Live strategy now: #", vm.toString(hook.liveId()), " (", _stage(cId), ")"));
        console2.log(
            string.concat("  Vault range: [", vm.toString(v.base.lower), ", ", vm.toString(v.base.upper), ")")
        );
        console2.log(
            string.concat("  LP shares: ", _fmt(sharesBefore), " -> ", _fmt(hook.balanceOf(lp)), " (no action taken)")
        );
        console2.log(string.concat("  HWM carried over: ", _fmt6(hwmBefore), " -> ", _fmt6(hook.highWaterMark())));
        console2.log(string.concat("  Old incumbent is back in shadow: ", _stage(nId)));

        _h("9. EXIT");
        uint256 b0 = _bal0(lp);
        uint256 b1 = _bal1(lp);
        uint256 s = hook.balanceOf(lp);
        vm.prank(lp);
        hook.withdraw(s, 0, 0, lp, vm.getBlockTimestamp());
        console2.log(
            string.concat("  LP withdraws all: ", _fmt(_bal0(lp) - b0), " token0 + ", _fmt(_bal1(lp) - b1), " token1")
        );
        _assertSolvent();
        console2.log("  Hook solvent: every booked token is held. Done.");
    }

    // ------------------------------------------------------------------
    // Formatting
    // ------------------------------------------------------------------

    function _h(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("== ", title));
    }

    function _stage(uint256 id) internal view returns (string memory) {
        StrategyRegistry.Stage st = registry.stageOf(id);
        if (st == StrategyRegistry.Stage.Shadow) return "SHADOW";
        if (st == StrategyRegistry.Stage.Graduated) return "GRADUATED";
        if (st == StrategyRegistry.Stage.Probation) return "PROBATION";
        if (st == StrategyRegistry.Stage.Tenured) return "TENURED";
        if (st == StrategyRegistry.Stage.Retired) return "RETIRED";
        return "NONE";
    }

    /// @dev WAD excess return -> "+12.3 bps"
    function _bps(int256 x) internal pure returns (string memory) {
        int256 tenths = x * 100_000 / 1e18;
        string memory sign = tenths < 0 ? "-" : "+";
        uint256 a = uint256(tenths < 0 ? -tenths : tenths);
        return string.concat(sign, vm.toString(a / 10), ".", vm.toString(a % 10), " bps");
    }

    function _lastSlash() internal returns (uint256 slashed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("VaultSettled(uint32,uint256,uint256,uint256,int256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (,,,,,, slashed) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, int256, uint256, uint256, uint256));
            }
        }
    }

    /// @dev WAD -> "1.000123"
    function _fmt6(uint256 wad) internal pure returns (string memory) {
        uint256 micros = wad / 1e12;
        uint256 frac = micros % 1e6;
        string memory f = vm.toString(frac);
        while (bytes(f).length < 6) f = string.concat("0", f);
        return string.concat(vm.toString(micros / 1e6), ".", f);
    }

    /// @dev WAD -> "123.45"
    function _fmt(uint256 wad) internal pure returns (string memory) {
        uint256 cents = wad / 1e16;
        uint256 frac = cents % 100;
        return string.concat(vm.toString(cents / 100), ".", frac < 10 ? "0" : "", vm.toString(frac));
    }
}

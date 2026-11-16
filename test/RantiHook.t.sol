// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {RantiTestBase} from "./utils/RantiTestBase.sol";
import {RantiHook} from "../src/RantiHook.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";
import {CuratorEscrow} from "../src/CuratorEscrow.sol";
import {IRantiStrategy} from "../src/interfaces/IRantiStrategy.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @dev Returns a range that is not aligned to tick spacing once switched on.
contract FlakyStrategy is IRantiStrategy {
    bool public broken;

    function setBroken(bool b) external {
        broken = b;
    }

    function name() external pure returns (string memory) {
        return "Flaky";
    }

    function getRange(int24 twapTick, int24 spacing) external view returns (int24, int24) {
        if (broken) return (1, 7);
        int24 c = (twapTick / spacing) * spacing;
        return (c - 10 * spacing, c + 10 * spacing);
    }
}

/// @dev Burns all the gas it is given.
contract GasBombStrategy is IRantiStrategy {
    function name() external pure returns (string memory) {
        return "GasBomb";
    }

    function getRange(int24, int24) external pure returns (int24, int24) {
        while (true) {}
        return (0, 0);
    }
}

contract RantiHookTest is RantiTestBase {
    // ------------------------------------------------------------------
    // Pool ownership
    // ------------------------------------------------------------------

    function test_poolIsBoundOnInitialize() public view {
        assertTrue(hook.poolBound());
        (,, uint24 fee, int24 spacing,) = hook.poolKey();
        assertEq(fee, 3000);
        assertEq(spacing, 60);
    }

    function test_outsideLiquidityIsRejected_noJIT() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_depositRequiresLiveStrategy() public {
        vm.prank(lp);
        vm.expectRevert(RantiHook.NoLiveStrategy.selector);
        hook.deposit(1e18, 1e18, 0, lp, vm.getBlockTimestamp());
    }

    // ------------------------------------------------------------------
    // Shadow mode
    // ------------------------------------------------------------------

    function test_registerPullsBondAndDeploysAtNextSettlement() public {
        uint256 before0 = _bal0(curatorA);
        uint256 id = _register(curatorA, narrow, BOND);
        assertEq(before0 - _bal0(curatorA), BOND);
        assertEq(uint8(registry.stageOf(id)), uint8(StrategyRegistry.Stage.Shadow));

        RantiHook.Bucket memory b = hook.getBucket(id);
        assertEq(b.base.liquidity, 0, "not deployed until settlement");

        _settle();
        b = hook.getBucket(id);
        assertGt(b.base.liquidity, 0, "bond deployed at strategy range");
        assertEq(b.base.lower, -120);
        assertEq(b.base.upper, 180);
        _assertSolvent();
    }

    function test_shadowIsScoredAgainstHodl() public {
        uint256 n = _register(curatorA, narrow, BOND);
        uint256 w = _register(curatorB, wide, BOND);
        _settle();
        _churnEpoch();

        int256 xn = registry.shadowReturn(n, 1);
        int256 xw = registry.shadowReturn(w, 1);
        assertGt(xn, 0, "narrow beats HODL in mean-reverting flow");
        assertGt(xw, 0, "wide beats HODL in mean-reverting flow");
        assertGt(xn, xw, "narrow earns more fees per unit of capital");
        _assertSolvent();
    }

    function test_graduationNeedsEnoughEpochs() public {
        uint256 n = _register(curatorA, narrow, BOND);
        _settle();
        _churnEpoch();
        _churnEpoch();
        assertFalse(registry.isGraduated(n), "2 epochs < minShadowEpochs");
        vm.expectRevert(RantiHook.CannotPromote.selector);
        hook.proposeUpgrade(n);

        _churnEpoch();
        assertTrue(registry.isGraduated(n));
        assertEq(uint8(registry.stageOf(n)), uint8(StrategyRegistry.Stage.Graduated));
    }

    function test_trendingFlowFailsGraduation() public {
        uint256 n = _register(curatorA, narrow, BOND);
        _register(curatorB, wide, BOND);
        _settle();
        for (uint256 i; i < 3; ++i) {
            _trend(3, 60e18, i % 2 == 0);
            _settle();
        }
        assertFalse(registry.isGraduated(n), "losing to HODL must not graduate");
    }

    function test_firstPromotionMakesStrategyLive() public {
        (uint256 n,) = _bootstrapLive();
        assertEq(uint8(registry.stageOf(n)), uint8(StrategyRegistry.Stage.Probation));
        (,,, uint256 cap) = registry.info(n);
        assertGe(cap, 2 * 2 * BOND, "cap0 = capMultiple * bond value (bond grew with shadow fees)");
        assertLe(cap, 2 * 2 * BOND * 102 / 100);
        RantiHook.Bucket memory v = hook.getBucket(0);
        assertEq(v.base.upper - v.base.lower, 300, "vault uses the live strategy's range");
    }

    // ------------------------------------------------------------------
    // LP flows and capacity
    // ------------------------------------------------------------------

    function test_depositAndWithdrawRoundTrip() public {
        _bootstrapLive();
        uint256 b0 = _bal0(lp);
        uint256 b1 = _bal1(lp);
        uint256 shares = _deposit(lp, 50e18);
        assertGt(shares, 0);
        _assertSolvent();

        vm.prank(lp);
        hook.withdraw(shares, 0, 0, lp, vm.getBlockTimestamp());
        assertLe(_bal0(lp), b0, "no free token0");
        assertLe(_bal1(lp), b1, "no free token1");
        assertApproxEqAbs(_bal0(lp), b0, 1e6);
        assertApproxEqAbs(_bal1(lp), b1, 1e6);
        _assertSolvent();
    }

    function test_secondDepositIsProRata() public {
        _bootstrapLive();
        uint256 s1 = _deposit(lp, 50e18);
        _churn(5, 5e18);
        uint256 s2 = _deposit(lp2, 50e18);
        assertLt(s2, s1, "later depositor pays for fees already earned");
        _assertSolvent();
    }

    function test_capacityGatesDeposits() public {
        _bootstrapLive();
        // cap0 = 400e18 of value; 250e18 of each token ~ 500e18 value
        vm.prank(lp);
        vm.expectRevert();
        hook.deposit(250e18, 250e18, 0, lp, vm.getBlockTimestamp());

        _deposit(lp, 150e18);
        vm.prank(lp2);
        vm.expectRevert();
        hook.deposit(100e18, 100e18, 0, lp2, vm.getBlockTimestamp());
    }

    function test_capacityGrowsWithVerifiedReturns() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        (,,, uint256 cap0) = registry.info(n);
        _churnEpoch();
        assertGt(hook.vaultReturn(5), 0, "vault beat HODL");
        (,,, uint256 cap1) = registry.info(n);
        assertGt(cap1, cap0, "cap grows after a verified positive epoch");
        assertLe(cap1, cap0 + cap0 / 4, "but never faster than the time ceiling");
    }

    // ------------------------------------------------------------------
    // High-water-mark fees, streaming, clawback
    // ------------------------------------------------------------------

    function test_hwmFeeMintedToEscrowWhenVaultBeatsHodl() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        uint256 supply0 = hook.totalSupply();
        uint256 hwm0 = hook.highWaterMark();

        _churnEpoch();

        uint256 fee = hook.balanceOf(address(escrow));
        assertGt(fee, 0, "fee shares minted");
        assertEq(hook.totalSupply(), supply0 + fee);
        assertGt(hook.highWaterMark(), hwm0, "HWM moves up");
        assertEq(escrow.atRisk(n), fee);
        assertEq(escrow.claimable(n), 0, "nothing vested at the settlement block");
        _assertSolvent();
    }

    function test_feeStreamsPerSecondAndCuratorClaims() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        _churnEpoch();
        uint256 fee = escrow.atRisk(n);

        vm.warp(vm.getBlockTimestamp() + EPOCH / 2);
        assertApproxEqRel(escrow.claimable(n), fee / 2, 0.01e18, "half vested half way");

        vm.prank(curatorA);
        uint256 got = escrow.claim(n);
        assertEq(hook.balanceOf(curatorA), got);

        vm.prank(curatorB);
        vm.expectRevert(CuratorEscrow.NotCurator.selector);
        escrow.claim(n);
    }

    function test_clawbackBurnsEscrowWhenVaultTrailsHodl() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        _churnEpoch(); // fee epoch
        uint256 atRiskBefore = escrow.atRisk(n);
        assertGt(atRiskBefore, 0);
        uint256 lpShares = hook.balanceOf(lp);

        // Informed flow pushes the price through the narrow range: the vault loses to HODL.
        _trend(3, 60e18, true);
        _settle();

        assertLt(hook.vaultReturn(6), 0, "vault trailed HODL");
        assertLt(escrow.atRisk(n), atRiskBefore, "escrow clawed back");
        assertEq(hook.balanceOf(lp), lpShares, "LP shares untouched");
        assertTrue(escrow.getStream(n).paused, "vesting paused below HWM");
        _assertSolvent();
    }

    function test_bondSlashedWhenEscrowIsNotEnough() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        // No fee epoch first: escrow is empty, so the bond must cover the shortfall.
        RantiHook.Bucket memory bondBefore = hook.getBucket(n);
        RantiHook.Bucket memory vaultBefore = hook.getBucket(0);
        uint256 bondValueBefore = bondBefore.idle0 + bondBefore.idle1;
        bondBefore; // silence
        vaultBefore;

        _trend(3, 60e18, false);
        vm.recordLogs();
        _settle();
        assertLt(hook.vaultReturn(5), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 slashed;
        bytes32 sig = keccak256("VaultSettled(uint32,uint256,uint256,uint256,int256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (,,,,,, slashed) = abi.decode(logs[i].data, (uint256, uint256, uint256, int256, uint256, uint256, uint256));
            }
        }
        assertGt(slashed, 0, "bond slashed into the vault");
        bondValueBefore;
        _assertSolvent();
    }

    function test_noFeeWhileBelowHighWaterMark() public {
        (uint256 n,) = _bootstrapLive();
        _deposit(lp, 150e18);
        _trend(3, 60e18, true); // drawdown epoch
        _settle();
        uint256 hwm = hook.highWaterMark();
        uint256 escrowBefore = hook.balanceOf(address(escrow));

        // A recovery epoch that still ends below the peak pays nothing.
        _trend(1, 30e18, false);
        _settle();
        if (_ppsNow() < hwm) {
            assertEq(hook.balanceOf(address(escrow)), escrowBefore, "no fee below the peak");
        }
        n;
    }

    // ------------------------------------------------------------------
    // Strategy migration
    // ------------------------------------------------------------------

    function test_inPlaceUpgradeKeepsSharesAndHwm() public {
        // Medium goes live first.
        uint256 m = _register(curatorA, medium, BOND);
        _settle();
        for (uint256 i; i < 3; ++i) {
            _churnEpoch();
        }
        hook.proposeUpgrade(m);
        _settle();
        assertEq(hook.liveId(), m);
        _deposit(lp, 150e18);

        // Narrow arrives later and builds its own record on its own bond.
        uint256 c = _register(curatorC, narrow, BOND);
        for (uint256 i; i < 4; ++i) {
            _churnEpoch();
        }
        assertTrue(registry.isGraduated(c));

        uint256 lpShares = hook.balanceOf(lp);
        hook.proposeUpgrade(c);
        assertEq(hook.upgradeReadyEpoch(), hook.epoch() + 1, "one-epoch timelock");

        _churnEpoch(); // timelock epoch: still the incumbent
        assertEq(hook.liveId(), m);
        uint256 hwmBefore = hook.highWaterMark();

        _churnEpoch(); // executes
        assertEq(hook.liveId(), c, "challenger is live");
        assertEq(uint8(registry.stageOf(m)), uint8(StrategyRegistry.Stage.Graduated), "incumbent back to shadow");
        assertEq(hook.balanceOf(lp), lpShares, "LP did nothing and kept every share");
        assertGe(hook.highWaterMark(), hwmBefore, "HWM carried over, not reset");
        RantiHook.Bucket memory v = hook.getBucket(0);
        assertEq(v.base.upper - v.base.lower, 300, "vault re-ranged to the challenger");
        _assertSolvent();

        // LP can still exit normally.
        vm.prank(lp);
        hook.withdraw(lpShares, 0, 0, lp, vm.getBlockTimestamp());
        _assertSolvent();
    }

    function test_challengerMustOutperformIncumbent() public {
        (, uint256 w) = _bootstrapLive();
        assertTrue(registry.isGraduated(w), "wide also graduates");
        vm.expectRevert(RantiHook.CannotPromote.selector);
        hook.proposeUpgrade(w); // wide trails narrow in this flow
    }

    function test_lpCanExitDuringTimelock() public {
        uint256 m = _register(curatorA, medium, BOND);
        _settle();
        for (uint256 i; i < 3; ++i) {
            _churnEpoch();
        }
        hook.proposeUpgrade(m);
        _settle();
        uint256 shares = _deposit(lp, 100e18);
        uint256 c = _register(curatorC, narrow, BOND);
        for (uint256 i; i < 4; ++i) {
            _churnEpoch();
        }
        hook.proposeUpgrade(c);
        vm.prank(lp);
        hook.withdraw(shares, 0, 0, lp, vm.getBlockTimestamp());
        assertEq(hook.balanceOf(lp), 0);
    }

    // ------------------------------------------------------------------
    // Adversarial
    // ------------------------------------------------------------------

    function test_settleRevertsWhenSpotIsManipulated() public {
        _bootstrapLive();
        _deposit(lp, 150e18);
        vm.warp(vm.getBlockTimestamp() + EPOCH);
        // Same-block price push right before settlement: TWAP doesn't move, spot does.
        swap(poolKey, true, -int256(300e18), ZERO_BYTES);
        vm.expectRevert();
        hook.settleEpoch();
    }

    function test_settleBeforeEpochEndReverts() public {
        _register(curatorA, narrow, BOND);
        vm.expectRevert(RantiHook.EpochNotOver.selector);
        hook.settleEpoch();
    }

    function test_depositSettleWithdrawSandwichIsNotProfitable() public {
        _bootstrapLive();
        _deposit(lp, 150e18);
        _churn(10, 5e18);
        vm.warp(vm.getBlockTimestamp() + EPOCH);

        uint256 a0 = _bal0(attacker);
        uint256 a1 = _bal1(attacker);
        uint256 s = _deposit(attacker, 50e18);
        hook.settleEpoch();
        vm.prank(attacker);
        hook.withdraw(s, 0, 0, attacker, vm.getBlockTimestamp());

        uint256 before = a0 + a1;
        uint256 afterV = _bal0(attacker) + _bal1(attacker);
        assertLe(afterV, before + 1e6, "joining right before settlement captures no fees");
    }

    function test_invalidStrategyIsRejectedAtRegistration() public {
        FlakyStrategy f = new FlakyStrategy();
        f.setBroken(true);
        vm.prank(curatorA);
        vm.expectRevert(RantiHook.InvalidStrategy.selector);
        hook.registerStrategy(f, BOND, BOND);
    }

    function test_gasBombStrategyIsRejected() public {
        GasBombStrategy g = new GasBombStrategy();
        vm.prank(curatorA);
        vm.expectRevert(RantiHook.InvalidStrategy.selector);
        hook.registerStrategy(g, BOND, BOND);
    }

    function test_strategyThatBreaksLaterStaysIdleAndSettlementContinues() public {
        FlakyStrategy f = new FlakyStrategy();
        uint256 id = _register(curatorA, f, BOND);
        _register(curatorB, wide, BOND);
        _settle();
        assertGt(hook.getBucket(id).base.liquidity, 0);

        f.setBroken(true);
        _churnEpoch(); // must not revert
        RantiHook.Bucket memory b = hook.getBucket(id);
        assertEq(b.base.liquidity, 0, "faulty strategy is left idle");
        _assertSolvent();
    }

    function test_bondTooSmallRejected() public {
        vm.prank(curatorA);
        vm.expectRevert(RantiHook.BondTooSmall.selector);
        hook.registerStrategy(narrow, 1e17, 1e17);
    }

    function test_maxActiveStrategies() public {
        _register(curatorA, narrow, BOND);
        _register(curatorA, medium, BOND);
        _register(curatorB, wide, BOND);
        _register(curatorC, narrow, BOND);
        vm.prank(curatorC);
        vm.expectRevert(RantiHook.TooManyStrategies.selector);
        hook.registerStrategy(wide, BOND, BOND);
    }

    function test_retireReturnsBond() public {
        uint256 id = _register(curatorA, narrow, BOND);
        _settle();
        _churnEpoch();
        uint256 b0 = _bal0(curatorA);
        uint256 b1 = _bal1(curatorA);
        vm.prank(curatorA);
        hook.retireStrategy(id);
        uint256 back = _bal0(curatorA) - b0 + _bal1(curatorA) - b1;
        assertGt(back, 2 * BOND - 1e18, "bond (plus fees, minus IL) returned");
        assertEq(uint8(registry.stageOf(id)), uint8(StrategyRegistry.Stage.Retired));
        assertEq(hook.activeStrategies().length, 0);
        _assertSolvent();
    }

    function test_liveStrategyCannotRetire() public {
        (uint256 n,) = _bootstrapLive();
        vm.prank(curatorA);
        vm.expectRevert(RantiHook.NotShadow.selector);
        hook.retireStrategy(n);
    }

    function test_settlementSurvivesEmptiedVault() public {
        _bootstrapLive();
        uint256 s = _deposit(lp, 50e18);
        _churnEpoch();
        vm.prank(lp);
        hook.withdraw(s, 0, 0, lp, vm.getBlockTimestamp());
        _trend(2, 30e18, true);
        _settle(); // only dead + escrow shares left
        _churnEpoch();
        _deposit(lp2, 20e18); // vault reopens
        _churnEpoch();
        _assertSolvent();
    }

    function test_registryAndEscrowAreHookOnly() public {
        vm.expectRevert(StrategyRegistry.OnlyHook.selector);
        registry.recordShadow(1, 0, 1e18);
        vm.expectRevert(CuratorEscrow.OnlyHook.selector);
        escrow.addTranche(1, address(this), 1e18);
    }

    // ------------------------------------------------------------------
    // Fuzz: accounting holds under random flows
    // ------------------------------------------------------------------

    function testFuzz_depositWithdrawNeverProfits(uint96 amtA, uint96 amtB, uint8 churnRounds) public {
        _bootstrapLive();
        uint256 a = bound(amtA, 1e15, 150e18);
        uint256 b = bound(amtB, 1e15, 40e18);
        _deposit(lp, a);
        _churn(bound(churnRounds, 0, 5), 3e18);

        uint256 v0 = _bal0(lp2) + _bal1(lp2);
        uint256 s = _deposit(lp2, b);
        vm.prank(lp2);
        hook.withdraw(s, 0, 0, lp2, vm.getBlockTimestamp());
        assertLe(_bal0(lp2) + _bal1(lp2), v0 + 10, "instant round trip never profits");
        _assertSolvent();
    }

    function testFuzz_randomFlowsKeepHookSolvent(uint256 seed) public {
        _bootstrapLive();
        _deposit(lp, 120e18);
        for (uint256 e; e < 3; ++e) {
            for (uint256 i; i < 6; ++i) {
                seed = uint256(keccak256(abi.encode(seed, e, i)));
                bool dir = seed & 1 == 1;
                uint256 amt = bound(seed >> 8, 1e17, 25e18);
                vm.warp(vm.getBlockTimestamp() + 40);
                swap(poolKey, dir, -int256(amt), ZERO_BYTES);
            }
            if (seed & 2 == 2) {
                uint256 third = hook.balanceOf(lp) / 3;
                vm.prank(lp);
                hook.withdraw(third, 0, 0, lp, vm.getBlockTimestamp());
            }
            _settle();
            _assertSolvent();
        }
        // Everyone can still leave.
        uint256 sh = hook.balanceOf(lp);
        vm.prank(lp);
        hook.withdraw(sh, 0, 0, lp, vm.getBlockTimestamp());
        _assertSolvent();
    }

    // ------------------------------------------------------------------
    // Utils
    // ------------------------------------------------------------------

    function _ppsNow() internal view returns (uint256) {
        (uint256 h0, uint256 h1) = hook.vaultHoldings();
        return (h0 + h1) * 1e18 / hook.totalSupply(); // price ~1 in these tests
    }

    // silence unused import warning
    function _unused() internal pure returns (bytes4) {
        return CustomRevert.WrappedError.selector;
    }
}

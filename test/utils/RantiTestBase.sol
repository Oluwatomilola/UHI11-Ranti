// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {RantiHook} from "../../src/RantiHook.sol";
import {StrategyRegistry} from "../../src/StrategyRegistry.sol";
import {CuratorEscrow} from "../../src/CuratorEscrow.sol";
import {CenteredRangeStrategy} from "../../src/strategies/CenteredRangeStrategy.sol";
import {IRantiStrategy} from "../../src/interfaces/IRantiStrategy.sol";

abstract contract RantiTestBase is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint32 internal constant EPOCH = 1 hours;
    uint256 internal constant BOND = 100e18;

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG
    );

    RantiHook internal hook;
    StrategyRegistry internal registry;
    CuratorEscrow internal escrow;
    PoolKey internal poolKey;

    CenteredRangeStrategy internal narrow; // ±120 ticks (~±1.2%)
    CenteredRangeStrategy internal medium; // ±600 ticks (~±6%)
    CenteredRangeStrategy internal wide; // ±2400 ticks (~±27%)

    address internal curatorA = makeAddr("curatorA");
    address internal curatorB = makeAddr("curatorB");
    address internal curatorC = makeAddr("curatorC");
    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    address internal attacker = makeAddr("attacker");

    function hookConfig() internal pure virtual returns (RantiHook.Config memory c) {
        c.epochLength = EPOCH;
        c.twapWindow = 30 minutes;
        c.oracleInterval = 60;
        c.vestingPeriod = EPOCH;
        c.maxTickDeviation = 200;
        c.perfFeeBps = 2_000; // 20%
        c.bondSlashBps = 5_000; // 50% of what escrow can't cover
        c.minBondValue = 1e18;
    }

    function registryParams() internal pure virtual returns (StrategyRegistry.Params memory p) {
        p.minShadowEpochs = 3;
        p.challengeWindow = 3;
        p.tenureEpochs = 4;
        p.capGrowthBps = 2_500; // up to +25% per epoch
        p.capHaircutBps = 3_000; // -30% on breach
        p.capMultiple = 2; // cap0 = 2x bond value
        p.maxDrawdownWad = 0.05e18;
        p.targetExcessWad = 0.0005e18; // 5 bps/epoch over HODL earns full growth
        p.zScoreWad = 1e18;
        p.capFloor = 1e18;
        p.probationCapCeiling = 1_000e18;
        p.tenuredCapCeiling = 100_000e18;
    }

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddr = address(FLAGS ^ (uint160(0x4444) << 144));
        deployCodeTo(
            "RantiHook.sol:RantiHook",
            abi.encode(manager, hookConfig(), registryParams(), "Ranti Vault Share", "rVLT"),
            hookAddr
        );
        hook = RantiHook(hookAddr);
        registry = hook.registry();
        escrow = hook.escrow();

        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        address[6] memory actors = [curatorA, curatorB, curatorC, lp, lp2, attacker];
        for (uint256 i; i < actors.length; ++i) {
            MockERC20(Currency.unwrap(currency0)).mint(actors[i], 1e24);
            MockERC20(Currency.unwrap(currency1)).mint(actors[i], 1e24);
            vm.startPrank(actors[i]);
            MockERC20(Currency.unwrap(currency0)).approve(hookAddr, type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(hookAddr, type(uint256).max);
            vm.stopPrank();
        }

        narrow = new CenteredRangeStrategy("Narrow +-1.2%", 120);
        medium = new CenteredRangeStrategy("Medium +-6%", 600);
        wide = new CenteredRangeStrategy("Wide +-27%", 2400);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _register(address curator, IRantiStrategy s, uint256 bond) internal returns (uint256 id) {
        vm.prank(curator);
        id = hook.registerStrategy(s, bond, bond);
    }

    function _settle() internal {
        vm.warp(vm.getBlockTimestamp() + EPOCH);
        hook.settleEpoch();
    }

    /// @dev Mean-reverting uninformed flow: round trips that pay fees but leave the price where it was.
    function _churn(uint256 rounds, uint256 amount) internal {
        for (uint256 i; i < rounds; ++i) {
            bool zeroForOne = i % 2 == 0;
            vm.warp(vm.getBlockTimestamp() + 30);
            BalanceDelta d = swap(poolKey, zeroForOne, -int256(amount), ZERO_BYTES);
            uint256 out = zeroForOne ? uint256(int256(d.amount1())) : uint256(int256(d.amount0()));
            vm.warp(vm.getBlockTimestamp() + 30);
            swap(poolKey, !zeroForOne, -int256(out), ZERO_BYTES);
        }
    }

    /// @dev One-directional informed flow: moves the price and leaves it there.
    function _trend(uint256 swaps, uint256 amount, bool zeroForOne) internal {
        for (uint256 i; i < swaps; ++i) {
            vm.warp(vm.getBlockTimestamp() + 30);
            swap(poolKey, zeroForOne, -int256(amount), ZERO_BYTES);
        }
    }

    /// @dev Mean-reverting epoch. Volume varies by epoch so track records are not flat lines.
    function _churnEpoch() internal {
        uint256 e = hook.epoch();
        uint256 amount = 3e18 + ((e * 7) % 5) * 1e18; // 3..7 tokens per leg
        uint256 rounds = 8 + ((e * 3) % 5); // 8..12 round trips
        _churn(rounds, amount);
        _settle();
    }

    /// @dev Narrow (curatorA) and wide (curatorB) run in shadow, narrow graduates and goes live.
    /// Returns with the vault live on `narrow` at the start of a fresh epoch.
    function _bootstrapLive() internal returns (uint256 narrowId, uint256 wideId) {
        narrowId = _register(curatorA, narrow, BOND);
        wideId = _register(curatorB, wide, BOND);
        _settle(); // deploy shadows
        for (uint256 i; i < 3; ++i) {
            _churnEpoch(); // three measured epochs
        }
        assertTrue(registry.isGraduated(narrowId), "narrow should graduate");
        hook.proposeUpgrade(narrowId);
        _settle(); // promotion executes, vault range set
        assertEq(hook.liveId(), narrowId);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) = hook.deposit(amt, amt, 0, who, vm.getBlockTimestamp());
    }

    function _bal0(address a) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency0)).balanceOf(a);
    }

    function _bal1(address a) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(currency1)).balanceOf(a);
    }

    /// @dev Every idle token the hook books must be physically held by the hook.
    function _assertSolvent() internal view {
        uint256[] memory ids = hook.activeStrategies();
        RantiHook.Bucket memory v = hook.getBucket(0);
        uint256 idle0 = v.idle0;
        uint256 idle1 = v.idle1;
        for (uint256 i; i < ids.length; ++i) {
            RantiHook.Bucket memory b = hook.getBucket(ids[i]);
            idle0 += b.idle0;
            idle1 += b.idle1;
        }
        assertGe(_bal0(address(hook)), idle0, "hook token0 < booked idle");
        assertGe(_bal1(address(hook)), idle1, "hook token1 < booked idle");
    }

    function _spotTick() internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(manager, poolKey.toId());
    }
}

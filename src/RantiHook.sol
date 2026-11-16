// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IRantiStrategy} from "./interfaces/IRantiStrategy.sol";
import {TwapOracle} from "./libraries/TwapOracle.sol";
import {RantiMath} from "./libraries/RantiMath.sol";
import {CuratorEscrow} from "./CuratorEscrow.sol";
import {StrategyRegistry} from "./StrategyRegistry.sol";

/// @title RantiHook
/// @notice A Uniswap v4 hook that owns all liquidity in its pool and runs it as a curated vault.
/// Curators earn capital and pay only by proving performance:
///   1. Shadow mode  - a new strategy runs on the curator's own bonded capital in the same pool,
///                     scored every epoch against a HODL benchmark (its track record).
///   2. Graduation   - enough epochs with a statistically positive record and limited drawdown.
///   3. Capacity     - the live strategy's deposit cap grows only as the vault's verified excess
///                     return over HODL accumulates, and is cut on drawdowns.
///   4. HWM fees     - the curator earns only on gains above both the previous peak share price
///                     and HODL, settled in-hook each epoch as escrowed shares.
///   5. Streaming    - escrowed fee shares vest per second; vesting pauses below the high-water
///                     mark, and escrow (then the bond) is clawed back when the vault trails HODL.
///   6. Migration    - a graduated challenger that beats the incumbent's record replaces it in
///                     place after a one-epoch timelock: no LP exits, shares and HWM carry over.
contract RantiHook is BaseHook, ERC20, ReentrancyGuardTransient, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using TwapOracle for TwapOracle.State;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Action {
        Settle,
        Deposit,
        Withdraw,
        Retire
    }

    struct Config {
        uint32 epochLength; // seconds between settlements
        uint32 twapWindow; // seconds of TWAP used for valuation and ranges
        uint32 oracleInterval; // minimum seconds between oracle checkpoints
        uint32 vestingPeriod; // seconds over which each fee tranche streams to the curator
        int24 maxTickDeviation; // settlement reverts if |spot - TWAP| exceeds this
        uint16 perfFeeBps; // performance fee on gains above HWM and HODL
        uint16 bondSlashBps; // share of an uncovered shortfall taken from the live curator's bond
        uint256 minBondValue; // minimum shadow bond, token1 units at TWAP
    }

    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    /// @dev Bucket 0 is the LP vault. Bucket `id` is strategy `id`'s bonded shadow.
    /// For the vault, start0/start1 are per-share token amounts (WAD) at the epoch start.
    /// For shadows they are absolute token amounts at the epoch start.
    struct Bucket {
        Range base;
        Range limit;
        uint256 idle0;
        uint256 idle1;
        uint256 start0;
        uint256 start1;
    }

    struct DepositParams {
        address payer;
        address to;
        uint256 amount0Max;
        uint256 amount1Max;
        uint160 twapSqrtPrice;
    }

    struct WithdrawParams {
        address owner;
        address to;
        uint256 shares;
    }

    struct Prices {
        int24 twapTick;
        uint160 twapSqrtPrice;
        int24 spotTick;
        uint160 spotSqrtPrice;
    }

    struct VaultReport {
        uint256 nav;
        uint256 pps;
        uint256 hodlPps;
        int256 excess;
        uint256 feeShares;
        uint256 clawedShares;
        uint256 slashedValue;
    }

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    uint256 internal constant VAULT = 0;
    uint256 internal constant MAX_ACTIVE = 4;
    uint256 public constant MIN_SHARES = 1_000;
    uint256 internal constant DUST = 1_000;
    uint256 internal constant STRATEGY_GAS = 100_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    CuratorEscrow public immutable escrow;
    StrategyRegistry public immutable registry;

    Config internal _config;
    PoolKey public poolKey;
    PoolId public poolId;
    bool public poolBound;

    TwapOracle.State internal _oracle;

    uint32 public epoch;
    uint64 public epochStart;
    uint256 public highWaterMark;

    uint256 public liveId;
    uint256 public pendingUpgradeId;
    uint32 public upgradeReadyEpoch;

    uint256[] internal _activeIds;
    mapping(uint256 => Bucket) internal _buckets;
    /// @notice epoch => vault excess return over HODL (WAD)
    mapping(uint256 => int256) public vaultReturn;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event StrategyRegistered(uint256 indexed id, address indexed curator, address impl, uint256 bond0, uint256 bond1);
    event StrategyRetired(uint256 indexed id, uint256 refund0, uint256 refund1);
    event StrategyFault(uint256 indexed id, uint32 indexed epoch);
    event UpgradeProposed(uint256 indexed challengerId, uint256 indexed incumbentId, uint32 readyEpoch);
    event UpgradeExecuted(uint256 indexed oldId, uint256 indexed newId, uint32 indexed epoch, uint256 cap0);
    event UpgradeCancelled(uint256 indexed challengerId, uint32 indexed epoch);
    event EpochSettled(uint32 indexed epoch, int24 twapTick, uint256 highWaterMark, uint256 liveId);
    event VaultSettled(
        uint32 indexed epoch,
        uint256 nav,
        uint256 pps,
        uint256 hodlPps,
        int256 excessReturn,
        uint256 feeShares,
        uint256 clawedShares,
        uint256 slashedValue
    );
    event Deposit(address indexed payer, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed to, uint256 shares, uint256 amount0, uint256 amount1);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error OnlyHookLiquidity();
    error PoolAlreadyBound();
    error WrongHook();
    error NativeCurrencyUnsupported();
    error PoolNotBound();
    error EpochNotOver();
    error PriceDeviation(int24 spotTick, int24 twapTick);
    error NoLiveStrategy();
    error NoRange();
    error CapExceeded(uint256 navAfter, uint256 cap);
    error Slippage();
    error Expired();
    error ZeroShares();
    error TooManyStrategies();
    error InvalidStrategy();
    error BondTooSmall();
    error NotCurator();
    error NotShadow();
    error CannotPromote();
    error UpgradePending();
    error InvalidConfig();

    // ------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------

    constructor(
        IPoolManager _poolManager,
        Config memory config_,
        StrategyRegistry.Params memory registryParams,
        string memory name_,
        string memory symbol_
    ) BaseHook(_poolManager) ERC20(name_, symbol_) {
        if (
            config_.epochLength == 0 || config_.perfFeeBps > 5_000 || config_.bondSlashBps > BPS
                || config_.maxTickDeviation <= 0
        ) revert InvalidConfig();
        _config = config_;
        escrow = new CuratorEscrow(address(this), config_.vestingPeriod);
        registry = new StrategyRegistry(address(this), registryParams);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (poolBound) revert PoolAlreadyBound();
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();
        poolKey = key;
        poolId = key.toId();
        poolBound = true;
        return this.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        _oracle.initialize(_config.oracleInterval);
        epochStart = uint64(block.timestamp);
        return this.afterInitialize.selector;
    }

    /// @dev The hook is the only liquidity owner. v4 never calls a hook for its own
    /// modifyLiquidity, so anything reaching here is an outside LP (including JIT): reject.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert OnlyHookLiquidity();
    }

    /// @dev The only work on the swap path: one oracle accrual per block.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        _oracle.update(tick);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------
    // Curators
    // ------------------------------------------------------------------

    /// @notice Register a strategy in shadow mode, bonded with the curator's own tokens.
    /// The bond is deployed at the strategy's ranges from the next settlement and scored against
    /// HODL every epoch. That score is the strategy's track record.
    function registerStrategy(IRantiStrategy impl, uint256 bond0, uint256 bond1)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (!poolBound) revert PoolNotBound();
        if (_activeIds.length >= MAX_ACTIVE) revert TooManyStrategies();
        Prices memory px = _prices();
        (bool ok,,) = _queryRange(impl, px.twapTick);
        if (!ok) revert InvalidStrategy();
        if (RantiMath.value(bond0, bond1, px.twapSqrtPrice) < _config.minBondValue) revert BondTooSmall();

        if (bond0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), bond0);
        if (bond1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), bond1);

        id = registry.register(msg.sender, impl, epoch);
        Bucket storage b = _buckets[id];
        b.idle0 = bond0;
        b.idle1 = bond1;
        _activeIds.push(id);

        emit StrategyRegistered(id, msg.sender, address(impl), bond0, bond1);
    }

    /// @notice Withdraw a shadow strategy and its bond. A live strategy must be replaced first.
    function retireStrategy(uint256 id) external nonReentrant {
        (address curator,, StrategyRegistry.Status status,) = registry.info(id);
        if (msg.sender != curator) revert NotCurator();
        if (status != StrategyRegistry.Status.Shadow) revert NotShadow();
        if (pendingUpgradeId == id) pendingUpgradeId = 0;
        registry.retire(id);
        _removeActive(id);
        poolManager.unlock(abi.encode(Action.Retire, abi.encode(id)));
    }

    /// @notice Propose a graduated shadow strategy as the vault's live strategy. Permissionless:
    /// the rule is objective. With no incumbent it goes live at the next settlement. Otherwise the
    /// challenger must have beaten the incumbent over the last challengeWindow epochs (both on
    /// equal-footing shadow buckets), and it waits one full epoch so LPs can react.
    function proposeUpgrade(uint256 challengerId) external {
        if (pendingUpgradeId != 0) revert UpgradePending();
        uint256 incumbent = liveId;
        if (!registry.canPromote(challengerId, incumbent, epoch)) revert CannotPromote();
        uint32 ready = incumbent == 0 ? epoch : epoch + 1;
        pendingUpgradeId = challengerId;
        upgradeReadyEpoch = ready;
        emit UpgradeProposed(challengerId, incumbent, ready);
    }

    // ------------------------------------------------------------------
    // LPs
    // ------------------------------------------------------------------

    /// @notice Deposit pro-rata into the vault's current holdings. Gated by the live strategy's cap.
    /// @dev Pro-rata deposits need no price: someone who moves the price before depositing pays
    /// more than they receive, because AMM holdings at the true price minimise value at that price.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        if (liveId == 0) revert NoLiveStrategy();
        Prices memory px = _prices();
        bytes memory result = poolManager.unlock(
            abi.encode(
                Action.Deposit, abi.encode(DepositParams(msg.sender, to, amount0Max, amount1Max, px.twapSqrtPrice))
            )
        );
        (shares, amount0, amount1) = abi.decode(result, (uint256, uint256, uint256));
        if (shares < minShares) revert Slippage();
        emit Deposit(msg.sender, to, shares, amount0, amount1);
    }

    /// @notice Withdraw pro-rata. Always open: no exit friction, including during an upgrade timelock.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > deadline) revert Expired();
        if (shares == 0) revert ZeroShares();
        bytes memory result =
            poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(WithdrawParams(msg.sender, to, shares))));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    // ------------------------------------------------------------------
    // Epoch settlement
    // ------------------------------------------------------------------

    /// @notice Close the epoch. Permissionless, callable once epochLength has passed.
    /// Values every bucket at TWAP, scores it against HODL, crystallises the HWM fee, applies
    /// clawbacks, updates capacity, executes a due upgrade and re-ranges all liquidity.
    function settleEpoch() external nonReentrant {
        if (!poolBound) revert PoolNotBound();
        if (block.timestamp < uint256(epochStart) + _config.epochLength) revert EpochNotOver();
        Prices memory px = _prices();
        int24 diff = px.spotTick - px.twapTick;
        if (diff < 0) diff = -diff;
        if (diff > _config.maxTickDeviation) revert PriceDeviation(px.spotTick, px.twapTick);
        poolManager.unlock(abi.encode(Action.Settle, abi.encode(px)));
    }

    // ------------------------------------------------------------------
    // Unlock callback
    // ------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));
        if (action == Action.Settle) {
            _settle(abi.decode(payload, (Prices)));
            return "";
        }
        if (action == Action.Deposit) return _deposit(abi.decode(payload, (DepositParams)));
        if (action == Action.Withdraw) return _withdraw(abi.decode(payload, (WithdrawParams)));
        _retire(abi.decode(payload, (uint256)));
        return "";
    }

    function _settle(Prices memory px) internal {
        uint32 e = epoch;
        uint256 n = _activeIds.length;

        // 1. Pull every position back into idle balances (collects all fees exactly).
        _removeAll(VAULT);
        for (uint256 i; i < n; ++i) {
            _removeAll(_activeIds[i]);
        }

        // 2. Score every bonded shadow bucket against HODL.
        for (uint256 i; i < n; ++i) {
            _measureShadow(_activeIds[i], e, px.twapSqrtPrice);
        }

        // 3. Vault: HWM fee, clawback, capacity, vesting pause.
        _accountVault(e, px.twapSqrtPrice);

        // 4. Strategy migration, if one is due.
        _maybeUpgrade(e, px.twapSqrtPrice);

        // 5. Re-range everything for the next epoch.
        for (uint256 i; i < n; ++i) {
            uint256 id = _activeIds[i];
            _redeploy(id, _implOf(id), px, false);
        }
        if (liveId != 0) _redeploy(VAULT, _implOf(liveId), px, true);

        _settleDeltas();

        epoch = e + 1;
        epochStart = uint64(block.timestamp);
        emit EpochSettled(e, px.twapTick, highWaterMark, liveId);
    }

    function _measureShadow(uint256 id, uint32 e, uint160 twapSqrtPrice) internal {
        Bucket storage b = _buckets[id];
        if (b.start0 == 0 && b.start1 == 0) return; // not deployed yet
        uint256 nav = RantiMath.value(b.idle0, b.idle1, twapSqrtPrice);
        uint256 hodl = RantiMath.value(b.start0, b.start1, twapSqrtPrice);
        int256 x = RantiMath.excessReturn(nav, hodl);
        registry.recordShadow(id, e, x);
    }

    function _accountVault(uint32 e, uint160 twapSqrtPrice) internal {
        uint256 supply = totalSupply();
        Bucket storage v = _buckets[VAULT];
        uint256 id = liveId;
        if (supply == 0 || id == 0 || (v.start0 == 0 && v.start1 == 0)) return;

        VaultReport memory r;
        r.nav = RantiMath.value(v.idle0, v.idle1, twapSqrtPrice);
        if (r.nav == 0) return; // emptied vault (dead shares only): nothing to score, never brick settlement
        r.pps = FullMath.mulDiv(r.nav, WAD, supply);
        r.hodlPps = RantiMath.value(v.start0, v.start1, twapSqrtPrice);
        r.excess = RantiMath.excessReturn(r.pps, r.hodlPps);
        vaultReturn[e] = r.excess;

        // High-water-mark performance fee, minted to the curator's escrow stream.
        uint256 hwm;
        (r.feeShares, hwm) = RantiMath.performanceFee(r.nav, supply, highWaterMark, r.hodlPps, _config.perfFeeBps);
        if (r.feeShares > 0) {
            _mint(address(escrow), r.feeShares);
            (address curator,,,) = registry.info(id);
            escrow.addTranche(id, curator, r.feeShares);
        }

        // Clawback: the vault trailed HODL, so the curator's escrow (then bond) covers it.
        if (r.excess < 0) {
            uint256 shortfall = FullMath.mulDiv(r.hodlPps - r.pps, supply, WAD);
            uint256 remaining;
            (r.clawedShares, remaining) = _clawback(id, shortfall, r.nav, supply);
            if (remaining > 0) r.slashedValue = _slashBond(id, remaining, twapSqrtPrice);
        }

        // Price per share after fee, clawback and slash. The high-water mark never decreases.
        uint256 ppsNow = FullMath.mulDiv(RantiMath.value(v.idle0, v.idle1, twapSqrtPrice), WAD, totalSupply());
        if (ppsNow > hwm) hwm = ppsNow;
        highWaterMark = hwm;

        uint256 dd = ppsNow < hwm ? FullMath.mulDiv(hwm - ppsNow, WAD, hwm) : 0;
        registry.recordLive(id, r.excess, dd);
        escrow.setPaused(id, ppsNow < hwm);

        emit VaultSettled(e, r.nav, r.pps, r.hodlPps, r.excess, r.feeShares, r.clawedShares, r.slashedValue);
    }

    function _maybeUpgrade(uint32 e, uint160 twapSqrtPrice) internal {
        uint256 cid = pendingUpgradeId;
        if (cid == 0 || e < upgradeReadyEpoch) return;
        pendingUpgradeId = 0;

        uint256 old = liveId;
        if (!registry.canPromote(cid, old, e)) {
            emit UpgradeCancelled(cid, e);
            return;
        }
        // The outgoing curator's escrow keeps vesting and is no longer at risk of clawback.
        if (old != 0) escrow.setPaused(old, false);

        Bucket storage bond = _buckets[cid];
        uint256 cap0 = registry.promote(cid, old, RantiMath.value(bond.idle0, bond.idle1, twapSqrtPrice));
        liveId = cid;
        emit UpgradeExecuted(old, cid, e, cap0);
    }

    function _redeploy(uint256 id, IRantiStrategy impl, Prices memory px, bool isVault) internal {
        Bucket storage b = _buckets[id];
        if (isVault) {
            uint256 supply = totalSupply();
            b.start0 = supply == 0 ? 0 : FullMath.mulDiv(b.idle0, WAD, supply);
            b.start1 = supply == 0 ? 0 : FullMath.mulDiv(b.idle1, WAD, supply);
        } else {
            b.start0 = b.idle0;
            b.start1 = b.idle1;
        }

        (bool ok, int24 lower, int24 upper) = _queryRange(impl, px.twapTick);
        if (!ok) {
            emit StrategyFault(id, epoch);
            return; // stays idle this epoch, and is scored that way
        }
        b.base.lower = lower;
        b.base.upper = upper;

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            px.spotSqrtPrice,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            _less1(b.idle0),
            _less1(b.idle1)
        );
        if (liq > 0) _add(id, 0, b.base, b, liq);

        // Leftover goes into a single-sided "limit" range next to the price, same width as the base.
        _placeLimit(id, b, upper - lower, px.spotTick, px.spotSqrtPrice);
    }

    function _placeLimit(uint256 id, Bucket storage b, int24 width, int24 spotTick, uint160 spotSqrtPrice) internal {
        int24 spacing = poolKey.tickSpacing;
        int24 floorT = RantiMath.floorTick(spotTick, spacing);
        if (b.idle0 > DUST && RantiMath.value(b.idle0, 0, spotSqrtPrice) >= b.idle1) {
            int24 lower = floorT + spacing;
            int24 upper = lower + width;
            if (upper > TickMath.maxUsableTick(spacing)) return;
            b.limit.lower = lower;
            b.limit.upper = upper;
            uint128 liq = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), _less1(b.idle0)
            );
            if (liq > 0) _add(id, 1, b.limit, b, liq);
        } else if (b.idle1 > DUST) {
            int24 upper = floorT;
            int24 lower = upper - width;
            if (lower < TickMath.minUsableTick(spacing)) return;
            b.limit.lower = lower;
            b.limit.upper = upper;
            uint128 liq = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), _less1(b.idle1)
            );
            if (liq > 0) _add(id, 1, b.limit, b, liq);
        }
    }

    // ------------------------------------------------------------------
    // Deposit / withdraw / retire internals
    // ------------------------------------------------------------------

    function _deposit(DepositParams memory p) internal returns (bytes memory) {
        Bucket storage v = _buckets[VAULT];
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        uint256 supply = totalSupply();
        uint256 pay0;
        uint256 pay1;
        uint256 shares;

        if (supply == 0) {
            if (v.base.lower == v.base.upper) revert NoRange();
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPrice,
                TickMath.getSqrtPriceAtTick(v.base.lower),
                TickMath.getSqrtPriceAtTick(v.base.upper),
                _less1(p.amount0Max),
                _less1(p.amount1Max)
            );
            if (liq == 0) revert ZeroShares();
            (pay0, pay1) = _addFromOutside(VAULT, 0, v.base, liq);
            shares = RantiMath.value(pay0, pay1, p.twapSqrtPrice);
            if (shares <= MIN_SHARES) revert ZeroShares();
            _mint(DEAD, MIN_SHARES);
            _mint(p.to, shares - MIN_SHARES);
            v.start0 = FullMath.mulDiv(pay0, WAD, shares);
            v.start1 = FullMath.mulDiv(pay1, WAD, shares);
            highWaterMark = WAD;
            shares -= MIN_SHARES;
        } else {
            _poke(v);
            (uint256 t0, uint256 t1) = _holdings(v, sqrtPrice);
            shares = type(uint256).max;
            if (t0 > 0) shares = RantiMath.min(shares, FullMath.mulDiv(_less(p.amount0Max, 3), supply, t0));
            if (t1 > 0) shares = RantiMath.min(shares, FullMath.mulDiv(_less(p.amount1Max, 3), supply, t1));
            if (shares == 0 || shares == type(uint256).max) revert ZeroShares();

            (pay0, pay1) = _addProRata(v, shares, supply);
            _mint(p.to, shares);
        }

        if (pay0 > p.amount0Max || pay1 > p.amount1Max) revert Slippage();

        // Capacity gate, valued at TWAP.
        (uint256 h0, uint256 h1) = _holdings(v, sqrtPrice);
        uint256 navAfter = RantiMath.value(h0, h1, p.twapSqrtPrice);
        (,,, uint256 cap) = registry.info(liveId);
        if (navAfter > cap) revert CapExceeded(navAfter, cap);

        if (pay0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(p.payer, address(this), pay0);
        if (pay1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(p.payer, address(this), pay1);
        _settleDeltas();
        return abi.encode(shares, pay0, pay1);
    }

    function _addProRata(Bucket storage v, uint256 shares, uint256 supply)
        internal
        returns (uint256 pay0, uint256 pay1)
    {
        uint128 dBase = uint128(FullMath.mulDiv(v.base.liquidity, shares, supply));
        uint128 dLimit = uint128(FullMath.mulDiv(v.limit.liquidity, shares, supply));
        if (dBase > 0) {
            (uint256 a0, uint256 a1) = _addFromOutside(VAULT, 0, v.base, dBase);
            pay0 += a0;
            pay1 += a1;
        }
        if (dLimit > 0) {
            (uint256 a0, uint256 a1) = _addFromOutside(VAULT, 1, v.limit, dLimit);
            pay0 += a0;
            pay1 += a1;
        }
        uint256 i0 = FullMath.mulDivRoundingUp(v.idle0, shares, supply);
        uint256 i1 = FullMath.mulDivRoundingUp(v.idle1, shares, supply);
        v.idle0 += i0;
        v.idle1 += i1;
        pay0 += i0;
        pay1 += i1;
    }

    function _withdraw(WithdrawParams memory p) internal returns (bytes memory) {
        Bucket storage v = _buckets[VAULT];
        uint256 supply = totalSupply();
        _burn(p.owner, p.shares);

        (uint256 out0, uint256 out1) = _removeProRata(0, v.base, p.shares, supply);
        (uint256 a0, uint256 a1) = _removeProRata(1, v.limit, p.shares, supply);
        out0 += a0;
        out1 += a1;

        uint256 i0 = FullMath.mulDiv(v.idle0, p.shares, supply);
        uint256 i1 = FullMath.mulDiv(v.idle1, p.shares, supply);
        v.idle0 -= i0;
        v.idle1 -= i1;
        out0 += i0;
        out1 += i1;

        _settleDeltas();
        if (out0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(p.to, out0);
        if (out1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(p.to, out1);
        return abi.encode(out0, out1);
    }

    function _retire(uint256 id) internal {
        _removeAll(id);
        _settleDeltas();
        Bucket storage b = _buckets[id];
        uint256 r0 = b.idle0;
        uint256 r1 = b.idle1;
        delete _buckets[id];
        (address curator,,,) = registry.info(id);
        if (r0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(curator, r0);
        if (r1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(curator, r1);
        emit StrategyRetired(id, r0, r1);
    }

    // ------------------------------------------------------------------
    // Clawback
    // ------------------------------------------------------------------

    /// @dev Burn escrowed fee shares worth up to `shortfall` (unvested first, then unclaimed).
    /// Burning shares hands their value to the remaining holders.
    function _clawback(uint256 id, uint256 shortfall, uint256 nav, uint256 supply)
        internal
        returns (uint256 burned, uint256 remaining)
    {
        uint256 need = FullMath.mulDivRoundingUp(shortfall, supply, nav);
        burned = escrow.clawback(id, need);
        if (burned > 0) _burn(address(escrow), burned);
        uint256 covered = FullMath.mulDiv(burned, nav, supply);
        remaining = covered >= shortfall ? 0 : shortfall - covered;
    }

    /// @dev Move part of the live curator's bond into the vault to cover what escrow could not.
    function _slashBond(uint256 id, uint256 uncovered, uint160 twapSqrtPrice) internal returns (uint256 slashed) {
        Bucket storage b = _buckets[id];
        Bucket storage v = _buckets[VAULT];
        uint256 bondNav = RantiMath.value(b.idle0, b.idle1, twapSqrtPrice);
        if (bondNav == 0) return 0;
        uint256 target = uncovered * _config.bondSlashBps / BPS;
        uint256 frac = target >= bondNav ? WAD : FullMath.mulDiv(target, WAD, bondNav);
        uint256 s0 = FullMath.mulDiv(b.idle0, frac, WAD);
        uint256 s1 = FullMath.mulDiv(b.idle1, frac, WAD);
        b.idle0 -= s0;
        b.idle1 -= s1;
        v.idle0 += s0;
        v.idle1 += s1;
        slashed = RantiMath.value(s0, s1, twapSqrtPrice);
    }

    // ------------------------------------------------------------------
    // Liquidity plumbing
    // ------------------------------------------------------------------

    function _modify(uint256 bucketId, uint256 slot, int24 lower, int24 upper, int256 liquidityDelta)
        internal
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        (delta, fees) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: liquidityDelta,
                salt: bytes32((bucketId << 1) | slot)
            }),
            ""
        );
    }

    /// @dev Add liquidity funded from the bucket's own idle balances.
    function _add(uint256 bucketId, uint256 slot, Range storage r, Bucket storage b, uint128 liq) internal {
        (uint256 paid0, uint256 paid1) = _addFromOutside(bucketId, slot, r, liq);
        b.idle0 -= paid0;
        b.idle1 -= paid1;
    }

    /// @dev Add liquidity funded by the caller (a depositor). Returns the principal owed.
    /// Fees collected as a side effect are credited to the bucket that owns the position.
    function _addFromOutside(uint256 bucketId, uint256 slot, Range storage r, uint128 liq)
        internal
        returns (uint256 owed0, uint256 owed1)
    {
        (BalanceDelta d, BalanceDelta fees) = _modify(bucketId, slot, r.lower, r.upper, int256(uint256(liq)));
        BalanceDelta principal = d - fees;
        owed0 = uint256(int256(-principal.amount0()));
        owed1 = uint256(int256(-principal.amount1()));
        r.liquidity += liq;
        _creditFees(bucketId, fees);
    }

    function _creditFees(uint256 bucketId, BalanceDelta fees) internal {
        int128 f0 = fees.amount0();
        int128 f1 = fees.amount1();
        if (f0 > 0) _buckets[bucketId].idle0 += uint256(int256(f0));
        if (f1 > 0) _buckets[bucketId].idle1 += uint256(int256(f1));
    }

    function _removeAll(uint256 bucketId) internal {
        Bucket storage b = _buckets[bucketId];
        _removeRange(bucketId, 0, b.base, b);
        _removeRange(bucketId, 1, b.limit, b);
    }

    function _removeRange(uint256 bucketId, uint256 slot, Range storage r, Bucket storage b) internal {
        uint128 liq = r.liquidity;
        if (liq == 0) return;
        (BalanceDelta d,) = _modify(bucketId, slot, r.lower, r.upper, -int256(uint256(liq)));
        b.idle0 += uint256(int256(d.amount0()));
        b.idle1 += uint256(int256(d.amount1()));
        r.liquidity = 0;
    }

    /// @dev Remove a pro-rata slice for a withdrawing LP. All of the position's fees are collected
    /// into idle first, so the LP's idle slice includes their share of fees.
    function _removeProRata(uint256 slot, Range storage r, uint256 shares, uint256 supply)
        internal
        returns (uint256 out0, uint256 out1)
    {
        uint128 dl = uint128(FullMath.mulDiv(r.liquidity, shares, supply));
        if (dl == 0) return (0, 0);
        (BalanceDelta d, BalanceDelta fees) = _modify(VAULT, slot, r.lower, r.upper, -int256(uint256(dl)));
        BalanceDelta principal = d - fees;
        _creditFees(VAULT, fees);
        out0 = uint256(int256(principal.amount0()));
        out1 = uint256(int256(principal.amount1()));
        r.liquidity -= dl;
    }

    /// @dev Collect accrued fees on the vault's positions into idle.
    function _poke(Bucket storage v) internal {
        if (v.base.liquidity > 0) {
            (, BalanceDelta fees) = _modify(VAULT, 0, v.base.lower, v.base.upper, 0);
            _creditFees(VAULT, fees);
        }
        if (v.limit.liquidity > 0) {
            (, BalanceDelta fees) = _modify(VAULT, 1, v.limit.lower, v.limit.upper, 0);
            _creditFees(VAULT, fees);
        }
    }

    function _holdings(Bucket storage b, uint160 sqrtPrice) internal view returns (uint256 t0, uint256 t1) {
        (uint256 a0, uint256 a1) =
            RantiMath.amountsForLiquidity(sqrtPrice, b.base.lower, b.base.upper, b.base.liquidity);
        (uint256 c0, uint256 c1) =
            RantiMath.amountsForLiquidity(sqrtPrice, b.limit.lower, b.limit.upper, b.limit.liquidity);
        t0 = a0 + c0 + b.idle0;
        t1 = a1 + c1 + b.idle1;
    }

    function _settleDeltas() internal {
        _settleDelta(poolKey.currency0);
        _settleDelta(poolKey.currency1);
    }

    function _settleDelta(Currency currency) internal {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d < 0) currency.settle(poolManager, address(this), uint256(-d), false);
        else if (d > 0) currency.take(poolManager, address(this), uint256(d), false);
    }

    // ------------------------------------------------------------------
    // Strategy helpers
    // ------------------------------------------------------------------

    function _implOf(uint256 id) internal view returns (IRantiStrategy impl) {
        (, impl,,) = registry.info(id);
    }

    function _queryRange(IRantiStrategy impl, int24 twapTick)
        internal
        view
        returns (bool ok, int24 lower, int24 upper)
    {
        int24 spacing = poolKey.tickSpacing;
        try impl.getRange{gas: STRATEGY_GAS}(twapTick, spacing) returns (int24 l, int24 u) {
            if (
                l >= u || l % spacing != 0 || u % spacing != 0 || l < TickMath.minUsableTick(spacing)
                    || u > TickMath.maxUsableTick(spacing)
            ) return (false, 0, 0);
            return (true, l, u);
        } catch {
            return (false, 0, 0);
        }
    }

    function _removeActive(uint256 id) internal {
        uint256 n = _activeIds.length;
        for (uint256 i; i < n; ++i) {
            if (_activeIds[i] == id) {
                _activeIds[i] = _activeIds[n - 1];
                _activeIds.pop();
                return;
            }
        }
    }

    function _prices() internal returns (Prices memory px) {
        (px.spotSqrtPrice, px.spotTick,,) = poolManager.getSlot0(poolId);
        _oracle.update(px.spotTick);
        (px.twapTick,) = _oracle.consult(px.spotTick, _config.twapWindow);
        px.twapSqrtPrice = TickMath.getSqrtPriceAtTick(px.twapTick);
    }

    function _less1(uint256 x) internal pure returns (uint256) {
        return x > 1 ? x - 1 : 0;
    }

    function _less(uint256 x, uint256 d) internal pure returns (uint256) {
        return x > d ? x - d : 0;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function config() external view returns (Config memory) {
        return _config;
    }

    function getBucket(uint256 id) external view returns (Bucket memory) {
        return _buckets[id];
    }

    function activeStrategies() external view returns (uint256[] memory) {
        return _activeIds;
    }

    /// @notice Vault token holdings at the current spot price (positions + idle, excluding unpoked fees).
    function vaultHoldings() external view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(poolId);
        return _holdings(_buckets[VAULT], sqrtPrice);
    }

    /// @notice Current TWAP tick and the window it covers.
    function twap() external view returns (int24 twapTick, uint32 window) {
        (, int24 spot,,) = poolManager.getSlot0(poolId);
        return _oracle.consult(spot, _config.twapWindow);
    }
}

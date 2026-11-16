// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IRantiStrategy} from "./interfaces/IRantiStrategy.sol";
import {RantiMath} from "./libraries/RantiMath.sol";

/// @title StrategyRegistry
/// @notice Track records, graduation and capacity for Ranti curators.
/// Every number here is written by the hook from its own measurements; nothing is self-reported.
/// @dev Deployed by the hook in its constructor. All writes are hook-only.
contract StrategyRegistry {
    enum Status {
        None,
        Shadow,
        Live,
        Retired
    }

    enum Stage {
        None,
        Shadow,
        Graduated,
        Probation,
        Tenured,
        Retired
    }

    struct Params {
        uint16 minShadowEpochs; // measured epochs required before graduation
        uint16 challengeWindow; // epochs compared when a challenger replaces the incumbent
        uint16 tenureEpochs; // live epochs before probation becomes tenure
        uint16 capGrowthBps; // max cap growth per epoch, earned at targetExcessWad
        uint16 capHaircutBps; // cap cut when drawdown exceeds maxDrawdownWad
        uint16 capMultiple; // starting cap = bond value * capMultiple
        uint256 maxDrawdownWad; // graduation limit and cap-haircut trigger
        uint256 targetExcessWad; // per-epoch excess return that earns full cap growth
        uint256 zScoreWad; // graduation significance threshold (1e18 = 1 standard error)
        uint256 capFloor;
        uint256 probationCapCeiling;
        uint256 tenuredCapCeiling;
    }

    struct Strategy {
        address curator;
        IRantiStrategy impl;
        Status status;
        uint32 registeredEpoch;
        uint32 firstMeasuredEpoch;
        uint32 shadowEpochs;
        uint32 liveEpochs; // live epochs in the current term
        int256 sumX; // sum of shadow excess returns over HODL (WAD)
        uint256 sumX2; // sum of squared shadow excess returns (WAD)
        uint256 indexWad; // compounded shadow excess-return index, starts at 1e18
        uint256 peakIndexWad;
        uint256 maxDrawdownWad;
        int256 liveSumX; // sum of live (vault) excess returns this term
        uint256 cap0;
        uint256 cap;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    address public immutable hook;
    Params internal _params;
    uint256 public nextId = 1;
    mapping(uint256 => Strategy) internal _strategies;
    /// @notice strategy id => epoch => shadow excess return over HODL (WAD)
    mapping(uint256 => mapping(uint256 => int256)) public shadowReturn;

    event ShadowRecorded(uint256 indexed id, uint32 indexed epoch, int256 excessReturn, uint256 indexWad);
    event LiveRecorded(uint256 indexed id, int256 excessReturn, uint256 drawdownWad, uint256 cap);
    event Promoted(uint256 indexed newId, uint256 indexed oldId, uint256 cap0);

    error OnlyHook();
    error InvalidParams();

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address hook_, Params memory params_) {
        if (
            params_.minShadowEpochs < 2 || params_.challengeWindow == 0
                || params_.challengeWindow > params_.minShadowEpochs || params_.capHaircutBps > BPS
                || params_.targetExcessWad == 0 || params_.probationCapCeiling > params_.tenuredCapCeiling
        ) revert InvalidParams();
        hook = hook_;
        _params = params_;
    }

    // ---------------------------------------------------------------
    // Hook-only writes
    // ---------------------------------------------------------------

    function register(address curator, IRantiStrategy impl, uint32 epoch) external onlyHook returns (uint256 id) {
        id = nextId++;
        Strategy storage s = _strategies[id];
        s.curator = curator;
        s.impl = impl;
        s.status = Status.Shadow;
        s.registeredEpoch = epoch;
        s.indexWad = WAD;
        s.peakIndexWad = WAD;
    }

    function retire(uint256 id) external onlyHook {
        _strategies[id].status = Status.Retired;
    }

    /// @notice Record one epoch of shadow performance: excess return of the bonded bucket over HODL.
    function recordShadow(uint256 id, uint32 epoch, int256 x) external onlyHook {
        Strategy storage s = _strategies[id];
        shadowReturn[id][epoch] = x;
        if (s.shadowEpochs == 0) s.firstMeasuredEpoch = epoch;
        s.shadowEpochs++;
        s.sumX += x;
        s.sumX2 += uint256(x * x) / WAD;

        uint256 index = FullMath.mulDiv(s.indexWad, uint256(int256(WAD) + x), WAD);
        s.indexWad = index;
        if (index > s.peakIndexWad) s.peakIndexWad = index;
        uint256 dd = FullMath.mulDiv(s.peakIndexWad - index, WAD, s.peakIndexWad);
        if (dd > s.maxDrawdownWad) s.maxDrawdownWad = dd;

        emit ShadowRecorded(id, epoch, x, index);
    }

    /// @notice Record one live epoch on real capital and return the new deposit cap.
    /// Cap grows with verified excess return (up to capGrowthBps at targetExcessWad), is cut on
    /// drawdowns, and can never outrun cap0 * (1 + g)^liveEpochs: capacity is earned over time.
    function recordLive(uint256 id, int256 x, uint256 drawdownWad) external onlyHook returns (uint256 cap) {
        Strategy storage s = _strategies[id];
        Params memory p = _params;
        s.liveEpochs++;
        s.liveSumX += x;

        cap = s.cap;
        if (x > 0) {
            uint256 ratio =
                uint256(x) >= p.targetExcessWad ? WAD : FullMath.mulDiv(uint256(x), WAD, p.targetExcessWad);
            cap += FullMath.mulDiv(cap, uint256(p.capGrowthBps) * ratio, BPS * WAD);
        } else if (drawdownWad > p.maxDrawdownWad) {
            cap = cap * (BPS - p.capHaircutBps) / BPS;
        }

        uint256 ceiling = s.liveEpochs >= p.tenureEpochs ? p.tenuredCapCeiling : p.probationCapCeiling;
        uint256 timeCeil = s.cap0;
        for (uint256 i; i < s.liveEpochs && timeCeil < ceiling; ++i) {
            timeCeil += timeCeil * p.capGrowthBps / BPS;
        }
        if (timeCeil < ceiling) ceiling = timeCeil;
        if (cap > ceiling) cap = ceiling;
        if (cap < p.capFloor) cap = p.capFloor;
        s.cap = cap;

        emit LiveRecorded(id, x, drawdownWad, cap);
    }

    /// @notice Make `newId` live (on probation) and send `oldId` back to shadow.
    function promote(uint256 newId, uint256 oldId, uint256 bondValue) external onlyHook returns (uint256 cap0) {
        Params memory p = _params;
        if (oldId != 0) _strategies[oldId].status = Status.Shadow;

        cap0 = bondValue * p.capMultiple;
        if (cap0 < p.capFloor) cap0 = p.capFloor;
        if (cap0 > p.probationCapCeiling) cap0 = p.probationCapCeiling;

        Strategy storage s = _strategies[newId];
        s.status = Status.Live;
        s.liveEpochs = 0;
        s.liveSumX = 0;
        s.cap0 = cap0;
        s.cap = cap0;
        emit Promoted(newId, oldId, cap0);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    /// @notice Graduated = enough measured epochs, drawdown within limit, and mean excess return
    /// more than z standard errors above zero.
    function isGraduated(uint256 id) public view returns (bool) {
        Strategy storage s = _strategies[id];
        Params storage p = _params;
        if (s.shadowEpochs < p.minShadowEpochs) return false;
        if (s.maxDrawdownWad > p.maxDrawdownWad) return false;
        return RantiMath.passesSignificance(s.shadowEpochs, s.sumX, s.sumX2, p.zScoreWad);
    }

    /// @notice Did `challenger` beat `incumbent` over the last challengeWindow completed epochs?
    /// Both are measured on equal-footing bonded shadow buckets in the same pool.
    function outperforms(uint256 challenger, uint256 incumbent, uint32 currentEpoch) public view returns (bool) {
        uint256 k = _params.challengeWindow;
        uint256 e = currentEpoch;
        if (e < k) return false;
        Strategy storage c = _strategies[challenger];
        Strategy storage i = _strategies[incumbent];
        if (c.shadowEpochs == 0 || i.shadowEpochs == 0) return false;
        if (c.firstMeasuredEpoch > e - k || i.firstMeasuredEpoch > e - k) return false;
        int256 sc;
        int256 si;
        for (uint256 j = 1; j <= k; ++j) {
            sc += shadowReturn[challenger][e - j];
            si += shadowReturn[incumbent][e - j];
        }
        return sc > si;
    }

    /// @notice Can `challenger` replace `incumbent` (0 = none) right now?
    function canPromote(uint256 challenger, uint256 incumbent, uint32 currentEpoch) external view returns (bool) {
        if (_strategies[challenger].status != Status.Shadow) return false;
        if (!isGraduated(challenger)) return false;
        return incumbent == 0 || outperforms(challenger, incumbent, currentEpoch);
    }

    function stageOf(uint256 id) external view returns (Stage) {
        Strategy storage s = _strategies[id];
        if (s.status == Status.Live) {
            return s.liveEpochs >= _params.tenureEpochs ? Stage.Tenured : Stage.Probation;
        }
        if (s.status == Status.Shadow) return isGraduated(id) ? Stage.Graduated : Stage.Shadow;
        if (s.status == Status.Retired) return Stage.Retired;
        return Stage.None;
    }

    function info(uint256 id)
        external
        view
        returns (address curator, IRantiStrategy impl, Status status, uint256 cap)
    {
        Strategy storage s = _strategies[id];
        return (s.curator, s.impl, s.status, s.cap);
    }

    function getStrategy(uint256 id) external view returns (Strategy memory) {
        return _strategies[id];
    }

    function params() external view returns (Params memory) {
        return _params;
    }
}

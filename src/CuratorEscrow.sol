// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CuratorEscrow
/// @notice Holds the performance-fee shares Ranti mints at each epoch and streams them to the
/// curator linearly per second. The hook can pause a stream (vault below its high-water mark)
/// and claw back unvested, then vested-but-unclaimed, shares when the vault underperforms HODL.
/// @dev Deployed by the hook in its constructor. Fee shares are the hook's own ERC-20 vault shares.
contract CuratorEscrow {
    using SafeERC20 for IERC20;

    struct Stream {
        address curator;
        uint128 unvested;
        uint128 claimable;
        uint64 lastUpdate;
        uint64 endTime;
        bool paused;
    }

    address public immutable hook;
    uint64 public immutable vestingPeriod;

    uint256 public totalEscrowed;
    mapping(uint256 => Stream) internal _streams;

    event TrancheAdded(uint256 indexed strategyId, uint256 shares, uint64 endTime);
    event StreamPaused(uint256 indexed strategyId, bool paused);
    event ClawedBack(uint256 indexed strategyId, uint256 shares);
    event Claimed(uint256 indexed strategyId, address indexed curator, uint256 shares);

    error OnlyHook();
    error NotCurator();

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address hook_, uint64 vestingPeriod_) {
        hook = hook_;
        vestingPeriod = vestingPeriod_;
    }

    // ---------------------------------------------------------------
    // Hook-only
    // ---------------------------------------------------------------

    /// @notice Record `amount` fee shares (already minted to this contract) for a strategy.
    /// Unvested balance and the new tranche stream together until now + vestingPeriod.
    function addTranche(uint256 id, address curator, uint256 amount) external onlyHook {
        Stream storage st = _streams[id];
        _accrue(st);
        if (st.curator == address(0)) st.curator = curator;
        st.unvested += uint128(amount);
        st.endTime = uint64(block.timestamp) + vestingPeriod;
        if (st.lastUpdate == 0) st.lastUpdate = uint64(block.timestamp);
        totalEscrowed += amount;
        emit TrancheAdded(id, amount, st.endTime);
    }

    function setPaused(uint256 id, bool paused) external onlyHook {
        Stream storage st = _streams[id];
        _accrue(st);
        if (st.paused != paused) {
            st.paused = paused;
            emit StreamPaused(id, paused);
        }
    }

    /// @notice Release up to `maxShares` from the stream for burning. Unvested shares go first.
    /// @return taken Shares removed from the stream; the hook burns them from this contract.
    function clawback(uint256 id, uint256 maxShares) external onlyHook returns (uint256 taken) {
        Stream storage st = _streams[id];
        _accrue(st);
        uint256 fromUnvested = maxShares < st.unvested ? maxShares : st.unvested;
        uint256 rest = maxShares - fromUnvested;
        uint256 fromClaimable = rest < st.claimable ? rest : st.claimable;
        taken = fromUnvested + fromClaimable;
        if (taken == 0) return 0;
        st.unvested -= uint128(fromUnvested);
        st.claimable -= uint128(fromClaimable);
        totalEscrowed -= taken;
        emit ClawedBack(id, taken);
    }

    // ---------------------------------------------------------------
    // Curator
    // ---------------------------------------------------------------

    /// @notice Claim vested fee shares. Once claimed they are ordinary vault shares.
    function claim(uint256 id) external returns (uint256 amount) {
        Stream storage st = _streams[id];
        if (msg.sender != st.curator) revert NotCurator();
        _accrue(st);
        amount = st.claimable;
        if (amount == 0) return 0;
        st.claimable = 0;
        totalEscrowed -= amount;
        IERC20(hook).safeTransfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    // ---------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------

    function getStream(uint256 id) external view returns (Stream memory) {
        return _streams[id];
    }

    function claimable(uint256 id) external view returns (uint256) {
        Stream memory st = _streams[id];
        uint64 t = uint64(block.timestamp);
        if (st.paused || t <= st.lastUpdate || st.unvested == 0) return st.claimable;
        if (t >= st.endTime) return uint256(st.claimable) + st.unvested;
        return uint256(st.claimable) + uint256(st.unvested) * (t - st.lastUpdate) / (st.endTime - st.lastUpdate);
    }

    /// @notice Unvested plus unclaimed shares: everything still at risk of clawback.
    function atRisk(uint256 id) external view returns (uint256) {
        Stream memory st = _streams[id];
        return uint256(st.unvested) + st.claimable;
    }

    // ---------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------

    function _accrue(Stream storage st) internal {
        uint64 t = uint64(block.timestamp);
        uint64 last = st.lastUpdate;
        if (t <= last) return;
        if (st.paused) {
            // Vesting stops while paused: push the end out by the paused time.
            st.endTime += t - last;
        } else if (st.unvested > 0) {
            if (t >= st.endTime) {
                st.claimable += st.unvested;
                st.unvested = 0;
            } else {
                uint256 vested = uint256(st.unvested) * (t - last) / (st.endTime - last);
                st.unvested -= uint128(vested);
                st.claimable += uint128(vested);
            }
        }
        st.lastUpdate = t;
    }
}

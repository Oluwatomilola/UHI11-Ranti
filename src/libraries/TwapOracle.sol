// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title TwapOracle
/// @notice Minimal tick-cumulative oracle for a single Uniswap v4 pool, written from the hook.
/// @dev v4 has no built-in oracle. The accumulator is updated at most once per block, before the
/// first swap of the block changes the price. Checkpoints are stored in a ring buffer at most
/// once every `interval` seconds, so the buffer covers `CARDINALITY * interval` seconds of history
/// while the swap path pays for a single slot write per block.
library TwapOracle {
    uint256 internal constant CARDINALITY = 64;

    struct Checkpoint {
        uint32 timestamp;
        int56 tickCumulative;
    }

    struct State {
        uint32 lastTimestamp;
        int56 tickCumulative;
        uint8 index; // newest checkpoint
        uint8 count; // populated checkpoints
        uint32 interval;
        Checkpoint[64] checkpoints;
    }

    error OracleNotInitialized();

    function initialize(State storage self, uint32 interval) internal {
        uint32 nowTs = uint32(block.timestamp);
        self.lastTimestamp = nowTs;
        self.tickCumulative = 0;
        self.interval = interval == 0 ? 1 : interval;
        self.checkpoints[0] = Checkpoint(nowTs, 0);
        self.index = 0;
        self.count = 1;
    }

    /// @notice Accrue the tick that has prevailed since the last update.
    /// @param currentTick The pool tick right now, before any price change in this call.
    function update(State storage self, int24 currentTick) internal {
        uint32 nowTs = uint32(block.timestamp);
        uint32 last = self.lastTimestamp;
        if (nowTs == last) return;

        int56 cumulative = self.tickCumulative + int56(currentTick) * int56(uint56(nowTs - last));
        self.tickCumulative = cumulative;
        self.lastTimestamp = nowTs;

        uint8 idx = self.index;
        if (nowTs - self.checkpoints[idx].timestamp >= self.interval) {
            uint8 next = uint8((uint256(idx) + 1) % CARDINALITY);
            self.checkpoints[next] = Checkpoint(nowTs, cumulative);
            self.index = next;
            if (self.count < CARDINALITY) self.count++;
        }
    }

    function cumulativeNow(State storage self, int24 currentTick) internal view returns (int56) {
        return self.tickCumulative
            + int56(currentTick) * int56(uint56(uint32(block.timestamp) - self.lastTimestamp));
    }

    /// @notice TWAP tick over at least `window` seconds (or all available history if shorter).
    /// @return twapTick Arithmetic mean tick, rounded towards negative infinity.
    /// @return effectiveWindow Seconds actually covered.
    function consult(State storage self, int24 currentTick, uint32 window)
        internal
        view
        returns (int24 twapTick, uint32 effectiveWindow)
    {
        if (self.count == 0) revert OracleNotInitialized();
        uint32 nowTs = uint32(block.timestamp);
        uint32 target = window >= nowTs ? 0 : nowTs - window;
        Checkpoint memory start = _search(self, target);

        effectiveWindow = nowTs - start.timestamp;
        if (effectiveWindow == 0) return (currentTick, 0);

        int56 delta = cumulativeNow(self, currentTick) - start.tickCumulative;
        int56 w = int56(uint56(effectiveWindow));
        twapTick = int24(delta / w);
        if (delta < 0 && delta % w != 0) twapTick--;
    }

    /// @dev Newest checkpoint with timestamp <= target, or the oldest one if history is too short.
    function _search(State storage self, uint32 target) private view returns (Checkpoint memory) {
        uint256 count = self.count;
        uint256 oldest = count < CARDINALITY ? 0 : (uint256(self.index) + 1) % CARDINALITY;
        Checkpoint memory first = self.checkpoints[oldest];
        if (first.timestamp >= target) return first;

        uint256 lo = 0;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (self.checkpoints[(oldest + mid) % CARDINALITY].timestamp <= target) lo = mid;
            else hi = mid - 1;
        }
        return self.checkpoints[(oldest + lo) % CARDINALITY];
    }
}

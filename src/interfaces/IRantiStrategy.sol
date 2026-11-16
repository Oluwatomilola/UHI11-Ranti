// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IRantiStrategy
/// @notice A Ranti strategy is a pure "brain": it only says where liquidity should sit.
/// It never holds or moves funds. The Ranti hook asks it for a range at every epoch
/// boundary, using the hook's own TWAP tick, and places liquidity there itself.
interface IRantiStrategy {
    /// @notice Human-readable name shown in the dashboard.
    function name() external view returns (string memory);

    /// @notice The range this strategy wants for the coming epoch.
    /// @param twapTick Time-weighted average tick from the Ranti oracle (manipulation-resistant).
    /// @param tickSpacing Pool tick spacing. Returned ticks must be multiples of it.
    /// @return tickLower Lower tick of the base range.
    /// @return tickUpper Upper tick of the base range (must be > tickLower).
    function getRange(int24 twapTick, int24 tickSpacing) external view returns (int24 tickLower, int24 tickUpper);
}

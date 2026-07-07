// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceObserver
/// @notice Adapter over a price source that can reconstruct a historical observation series.
///
/// @dev The price source is a parameter of the instrument. A series records which observer
///      and which source it uses, and neither can ever change: swapping the source would
///      silently change the quantity being measured.
///
///      Every implementation is responsible for its own guarantees: staleness, minimum source
///      liquidity, sanity bounds. The market contract knows none of that.
///
///      Two properties decide whether an adapter is usable:
///
///        - `maxLookback` — how far back the source can still be read. This is the constraint
///          that decides whether a series can even be created. For Uniswap V3 it is set by the
///          observation ring buffer, and busier pools have shorter memory.
///
///        - `realObservations` — how many genuine recordings exist inside a window, as opposed
///          to values interpolated between them. Interpolation makes a series artificially
///          smooth and therefore biases realized variance downward. Settlement refuses to
///          produce a number when a window is too sparse, and this is how it knows.
interface IPriceObserver {
    /// @notice Human-readable source kind, e.g. "uniswap-v3-twap".
    function kind() external pure returns (string memory);

    /// @notice Seconds of history currently readable from `source`.
    /// @dev Compared against a series window at creation time. May shrink as the source is
    ///      used, which is exactly why creation also requires headroom above the window.
    function maxLookback(address source) external view returns (uint32);

    /// @notice Number of genuine observations recorded in [endTime - windowSeconds, endTime].
    /// @dev Used for the completeness check at settlement. Implementations that cannot tell
    ///      real recordings from interpolated values MUST return the expected count and say
    ///      so in their documentation, so the check visibly degrades to a no-op.
    function realObservations(address source, uint32 endTime, uint32 windowSeconds)
        external
        view
        returns (uint256);

    /// @notice Reconstructs an evenly spaced series of log-prices as ticks.
    /// @param source Price source address.
    /// @param endTime Right edge of the window, inclusive.
    /// @param windowSeconds Window length.
    /// @param samples Number of points to return; must be >= 2.
    /// @return ticks Series of average ticks, oldest first, length `samples`.
    /// @dev A tick is a base-1.0001 logarithm of price, so consumers can take differences
    ///      directly and never touch a logarithm. Reverts if the source cannot cover the
    ///      window rather than returning a degraded series.
    function sampleTicks(address source, uint32 endTime, uint32 windowSeconds, uint16 samples)
        external
        view
        returns (int256[] memory ticks);

    /// @notice Reverts unless `source` can support a series with this window and grid.
    /// @dev Called at creation. Cheaper to fail here than to discover the gap at settlement,
    ///      when the money is already committed.
    function validateSource(address source, uint32 windowSeconds, uint16 samples) external view;
}

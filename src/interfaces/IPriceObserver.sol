// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPriceObserver
/// @notice Adapter over a price source that can reconstruct a historical observation series.
///
/// @dev The abstraction exists because the price source is a *parameter of the instrument*,
///      not an integration detail. A series records which observer and which source it uses,
///      and neither can ever change — swapping the source would silently change the quantity
///      being measured.
///
///      Every implementation is responsible for its own guarantees: staleness, minimum source
///      liquidity, sanity bounds. The market contract deliberately knows none of that.
///
///      Two properties are what make an adapter usable at all:
///
///        - `maxLookback` — how far back the source can still be read. This is the constraint
///          that decides whether a series can even be created. For Uniswap V3 it is set by the
///          observation ring buffer, and busier pools have *shorter* memory, not longer.
///
///        - `realObservations` — how many genuine recordings exist inside a window, as opposed
///          to values interpolated between them. Interpolation makes a series artificially
///          smooth and therefore biases realized variance downward. Settlement refuses to
///          produce a number when a window is too sparse, and this is how it knows.
interface IPriceObserver {
    /// @notice How to read the numbers `sampleSeries` returns.
    /// @dev Added when a second adapter was written, which is the point of writing one. The
    ///      original interface returned "ticks" because the only implementation had ticks, and a
    ///      tick is a base-1.0001 logarithm — free to difference, no logarithm on chain.
    ///
    ///      A push feed reports prices. Forcing those into ticks means taking a logarithm and
    ///      rounding to an integer tick, which discards up to a full basis point per sample. On
    ///      a four-minute grid, typical moves are a few ticks, so that rounding is a large share
    ///      of the signal — the abstraction would have quietly destroyed the measurement.
    ///
    ///      So the adapter declares its scale and the market picks the matching maths.
    enum SeriesKind {
        /// @dev Base-1.0001 logarithms. Differences are exact; no logarithm is evaluated.
        TICKS,
        /// @dev WAD-scaled prices. Requires `lnWad`, whose error enters squared.
        PRICES_WAD
    }

    /// @notice Which of the two the adapter produces.
    function seriesKind() external pure returns (SeriesKind);

    /// @notice Human-readable source kind, e.g. "uniswap-v3-twap".
    function kind() external pure returns (string memory);

    /// @notice Seconds of history currently readable from `source`.
    /// @dev Compared against a series window at creation time. May shrink as the source is
    ///      used, which is exactly why creation also requires headroom above the window.
    function maxLookback(address source) external view returns (uint32);

    /// @notice Number of genuine observations recorded in [endTime - windowSeconds, endTime].
    /// @dev Used for the completeness check at settlement. Implementations that cannot tell
    ///      real recordings from interpolated values MUST return the expected count, and say
    ///      so in their documentation, so the check degrades to a no-op rather than a lie.
    function realObservations(address source, uint32 endTime, uint32 windowSeconds)
        external
        view
        returns (uint256);

    /// @notice Reconstructs an evenly spaced series of log-prices as ticks.
    /// @param source Price source address.
    /// @param endTime Right edge of the window, inclusive.
    /// @param windowSeconds Window length.
    /// @param samples Number of points to return; must be >= 2.
    /// @return series Observations, oldest first, length `samples`, in the adapter's own scale
    ///         as declared by `seriesKind`.
    /// @dev Reverts if the source cannot cover the window rather than returning a degraded
    ///      series. A short series is worse than no series: it settles on an artefact.
    function sampleSeries(address source, uint32 endTime, uint32 windowSeconds, uint16 samples)
        external
        view
        returns (int256[] memory series);

    /// @notice Quote-token size that moves this source's price by one percent.
    ///
    /// @dev The unit in which manipulation is priced. Measured on the real pool, moving the
    ///      price is cheap — $1M shifts the deepest ETH pool on Base by 6.4% for $986 in fees —
    ///      and what makes the attack unprofitable is not depth but the size of the position it
    ///      could pay off. Since the break-even is a *ratio* between notional and depth, a
    ///      defence has to be expressed as one, and this is the denominator.
    ///
    ///      Returns `type(uint256).max` for sources with no on-chain depth to speak of, which
    ///      says "this bound does not apply here" rather than "this source is infinitely safe" —
    ///      such a source has different risks, addressed elsewhere.
    function depthQuote(address source) external view returns (uint256);

    /// @notice The token `depthQuote` is denominated in.
    ///
    /// @dev Needed because a depth figure and a notional figure are only comparable when they are
    ///      the same asset. Depth is quoted in the source's own quote token; notional is in the
    ///      series' collateral. Comparing $254k of pool depth against 100 units of an unrelated
    ///      18-decimal token is not a conservative approximation, it is a category error — and a
    ///      trivial way around the cap, by denominating a series in whatever token makes the
    ///      number look small.
    ///
    ///      Returns `address(0)` when the source has no on-chain depth, in which case the cap
    ///      does not apply at all.
    function quoteToken(address source) external view returns (address);

    /// @notice Asks the source to remember more history, if it can be asked.
    ///
    /// @dev Uniswap's buffer is extended by anyone willing to pay for the storage, and this
    ///      protocol treats doing so as its own responsibility rather than someone else's — the
    ///      buffer paradox means the pools worth writing series on are exactly the pools whose
    ///      memory is shortest. Measured cost: 22 244 gas per slot, so a thousand slots is about
    ///      $0.33 on Base and buys roughly six more hours on a pool recording every 23 seconds.
    ///
    ///      A no-op for sources that cannot be extended, which is most of them. Callers check
    ///      `maxLookback` afterwards rather than trusting a return value, because extension is
    ///      not instant: Uniswap grows the buffer lazily as new observations are written, so
    ///      capacity bought now becomes history later.
    function extendHistory(address source, uint16 targetObservations) external;

    /// @notice Reverts unless `source` can support a series with this window and grid.
    /// @dev Called at creation. Cheaper to fail here than to discover the gap at settlement,
    ///      when the money is already committed.
    function validateSource(address source, uint32 windowSeconds, uint16 samples) external view;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Variance} from "../types/Variance.sol";

/// @title VarianceMath
/// @notice Realized variance from a series of observations.
///
/// @dev The instrument settles on annualised realized variance:
///
///          RV = (SECONDS_PER_YEAR / windowSeconds) * SUM_i [ ln(P_i / P_{i-1}) ]^2
///
///      Note what the annualisation collapses to. With `N` returns over a window of
///      `windowSeconds`, the textbook `(A / N) * SUM` with `A = SECONDS_PER_YEAR / dt`
///      and `dt = windowSeconds / N` reduces to `SUM * SECONDS_PER_YEAR / windowSeconds`.
///      The grid step cancels. That matters: the result no longer depends on how finely
///      the window was sampled, only on the window itself. Sampling frequency still
///      affects the *estimate* (see the bias measurement), but not the scaling.
///
///      Two paths exist, and the difference is the point of this library:
///
///      1. `fromTicks` — for tick-based sources (Uniswap V3/V4). A tick IS a logarithm:
///         `P = 1.0001^tick`, therefore `ln(P_i/P_{i-1}) = (tick_i - tick_{i-1}) * ln(1.0001)`.
///         No logarithm is computed on chain at all. The sum of squared tick deltas is
///         exact integer arithmetic; the only rounding is the single final multiplication.
///
///      2. `fromPrices` — for price-based sources (push oracles). Needs `lnWad`, whose
///         error enters the result squared and accumulates over all N observations.
///
///      Path 1 is strictly more accurate and strictly cheaper. It is the reason the
///      protocol prefers tick-based sources, and that preference is a design decision,
///      not an implementation detail — see docs/decisions/0003.
library VarianceMath {
    using FixedPointMathLib for int256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev ln(1.0001) squared, scaled by 1e36.
    ///      ln(1.0001) = 0.000099995000333308335333166680951131...
    ///      Keeping the square at 1e36 preserves ~28 significant digits, so the squaring
    ///      itself contributes no meaningful error. Computed with 60-digit decimal
    ///      arithmetic in reference/variance_reference.py::LN_TICK_SQUARED_E36.
    uint256 internal constant LN_TICK_SQUARED_E36 = 9_999_000_091_658_334_094_374_450_925;

    /// @dev Largest tick magnitude Uniswap V3 can represent. Bounds every delta and
    ///      therefore bounds the accumulator; see `_checkOverflowDomain`.
    int256 internal constant MAX_ABS_TICK = 887_272;

    error EmptySeries();
    error ZeroWindow();
    error TickOutOfRange(int256 tick);

    // ---------------------------------------------------------------------
    // Tick path — exact
    // ---------------------------------------------------------------------

    /// @notice Sum of squared tick deltas. Exact integer arithmetic, no rounding.
    /// @param ticks Observation series, oldest first. `ticks.length - 1` returns are used.
    /// @return sumSquares SUM (tick_i - tick_{i-1})^2
    function sumSquaredTickDeltas(int256[] memory ticks) internal pure returns (uint256 sumSquares) {
        uint256 n = ticks.length;
        if (n < 2) revert EmptySeries();

        int256 prev = ticks[0];
        if (prev > MAX_ABS_TICK || prev < -MAX_ABS_TICK) revert TickOutOfRange(prev);

        for (uint256 i = 1; i < n; ++i) {
            int256 cur = ticks[i];
            if (cur > MAX_ABS_TICK || cur < -MAX_ABS_TICK) revert TickOutOfRange(cur);

            int256 d = cur - prev;
            // |d| <= 2 * MAX_ABS_TICK, so d*d <= 3.15e12 and the running sum cannot
            // overflow for any series length that fits in a block.
            unchecked {
                sumSquares += uint256(d * d);
            }
            prev = cur;
        }
    }

    /// @notice Annualised realized variance from a tick series.
    /// @param ticks Observation series, oldest first.
    /// @param windowSeconds Length of the observation window in seconds.
    function fromTicks(int256[] memory ticks, uint256 windowSeconds) internal pure returns (Variance) {
        return annualise(sumSquaredTickDeltas(ticks), windowSeconds);
    }

    /// @notice Turns a sum of squared tick deltas into annualised variance.
    /// @dev Kept separate so an accumulator can add up sums across several calls and
    ///      annualise once at the end — the sum is additive, the annualisation is not.
    function annualise(uint256 sumSquaredTickDeltas_, uint256 windowSeconds)
        internal
        pure
        returns (Variance)
    {
        if (windowSeconds == 0) revert ZeroWindow();
        // sumSq * ln^2(1.0001) gives the raw quadratic variation in WAD when the e36
        // constant is divided back by 1e18; annualisation is the remaining ratio.
        uint256 quadraticVariationWad =
            FixedPointMathLib.fullMulDiv(sumSquaredTickDeltas_, LN_TICK_SQUARED_E36, 1e18);
        return Variance.wrap(
            FixedPointMathLib.fullMulDiv(quadraticVariationWad, SECONDS_PER_YEAR, windowSeconds)
        );
    }

    // ---------------------------------------------------------------------
    // Price path — needs a logarithm
    // ---------------------------------------------------------------------

    /// @notice Annualised realized variance from a WAD-scaled price series.
    /// @dev Only for sources that cannot express prices as ticks. Every `lnWad` call
    ///      carries an approximation error that is then squared and summed, so the
    ///      accumulated error grows with N. Prefer `fromTicks` wherever possible.
    function fromPrices(uint256[] memory pricesWad, uint256 windowSeconds) internal pure returns (Variance) {
        uint256 n = pricesWad.length;
        if (n < 2) revert EmptySeries();
        if (windowSeconds == 0) revert ZeroWindow();

        uint256 sumSquaresWad;
        uint256 prev = pricesWad[0];
        for (uint256 i = 1; i < n; ++i) {
            uint256 cur = pricesWad[i];
            // ln(cur/prev) in WAD. Ratio is formed first to keep the argument near 1e18,
            // which is where lnWad is most accurate.
            int256 r = int256(FixedPointMathLib.divWad(cur, prev)).lnWad();
            sumSquaresWad += uint256(r * r) / WAD;
            prev = cur;
        }

        return Variance.wrap(FixedPointMathLib.fullMulDiv(sumSquaresWad, SECONDS_PER_YEAR, windowSeconds));
    }

    // ---------------------------------------------------------------------
    // Settlement arithmetic
    // ---------------------------------------------------------------------

    /// @notice Long side payout per unit of variance notional, in token units.
    /// @dev The whole collateral design rests on this one line:
    ///
    ///          longPayout  = notional * min(RV, cap * K)
    ///          shortPayout = notional * cap * K  -  longPayout
    ///
    ///      Long deposits `notional * K` (its maximum loss, realised at RV = 0).
    ///      Short deposits `notional * (cap - 1) * K` (its maximum loss, at RV >= cap*K).
    ///      Deposits therefore total exactly `notional * cap * K`, which is exactly what
    ///      the two payouts sum to. Solvency is an identity, not a property to monitor —
    ///      and that is why this instrument needs no liquidations.
    /// @param realized Settled realized variance.
    /// @param strike Strike variance fixed at series creation.
    /// @param capMultiple WAD-scaled cap multiple (2.5e18 = payout capped at 2.5 * strike).
    /// @param notionalPerUnit Tokens per 1.0 of variance.
    function longPayout(Variance realized, Variance strike, uint256 capMultiple, uint256 notionalPerUnit)
        internal
        pure
        returns (uint256)
    {
        Variance ceiling = strike.mulWad(capMultiple);
        Variance effective = realized.min(ceiling);
        return effective.notional(notionalPerUnit);
    }

    /// @notice Total collateral a matched unit requires: `notional * cap * K`.
    function totalCollateral(Variance strike, uint256 capMultiple, uint256 notionalPerUnit)
        internal
        pure
        returns (uint256)
    {
        return strike.mulWad(capMultiple).notionalUp(notionalPerUnit);
    }

    /// @notice Long side deposit: its maximum loss, `notional * K`.
    function longCollateral(Variance strike, uint256 notionalPerUnit) internal pure returns (uint256) {
        return strike.notionalUp(notionalPerUnit);
    }

    /// @notice Short side deposit: its maximum loss, `notional * (cap - 1) * K`.
    /// @dev Defined as the remainder of `totalCollateral` so that the two deposits sum
    ///      to the total exactly, with no rounding gap in either direction.
    function shortCollateral(Variance strike, uint256 capMultiple, uint256 notionalPerUnit)
        internal
        pure
        returns (uint256)
    {
        return totalCollateral(strike, capMultiple, notionalPerUnit) - longCollateral(strike, notionalPerUnit);
    }
}

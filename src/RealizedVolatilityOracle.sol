// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IPriceObserver} from "./interfaces/IPriceObserver.sol";
import {VarianceMath} from "./libraries/VarianceMath.sol";
import {Variance} from "./types/Variance.sol";

/// @title RealizedVolatilityOracle
/// @notice Realized volatility of any readable source, computed on chain, for anyone.
///
/// @dev The market computes realized variance for its own settlement; this contract exposes
///      the same calculation as a public read. Stateless and permissionless: name a source
///      and a window and get an answer.
///
///      A `Reading` carries, alongside the value, the two figures that decide whether to
///      believe it:
///
///        - `genuineObservations` — how much of the window is recorded rather than interpolated.
///          A sparse window produces a number describing mostly interpolation.
///        - `sourceDepth` — what it costs to move the source one percent, which is the
///          denominator of every manipulation calculation. A reading from a shallow pool is
///          cheap to fake.
///
///      This is not the same quantity as an off-chain vol index: a TWAP series runs about a
///      third below spot realized volatility (see docs/measurements/variance_bias.md).
///
///      A caller that gates value on this reading inherits the manipulation cost of the
///      source (docs/measurements/manipulation_cost.md); `sourceDepth` is in the struct so
///      the caller can size against it, the same way this protocol sizes its own series.
contract RealizedVolatilityOracle {
    /// @param variance Annualised realized variance, WAD.
    /// @param volatilityWad Annualised volatility, WAD — the square root of the above.
    /// @param genuineObservations Real recordings the source holds inside the window.
    /// @param expectedObservations Grid points requested, for comparison with the above.
    /// @param sourceDepth Quote-token size that moves the source 1%; `type(uint256).max` when
    ///        the source has no on-chain depth to move.
    /// @param windowSeconds Window the figures describe.
    struct Reading {
        Variance variance;
        uint256 volatilityWad;
        uint256 genuineObservations;
        uint256 expectedObservations;
        uint256 sourceDepth;
        uint32 windowSeconds;
    }

    error WindowTooShort(uint32 windowSeconds);
    error TooFewSamples(uint16 samples);

    uint32 internal constant MIN_WINDOW = 5 minutes;
    uint16 internal constant MIN_SAMPLES = 2;
    uint16 internal constant MAX_SAMPLES = 256;

    /// @notice Realized volatility over the window ending now.
    /// @param observer Adapter that can read `source`.
    /// @param source Price source.
    /// @param windowSeconds How far back to measure.
    /// @param samples Grid points; coarser grids report lower variance, by construction.
    function read(IPriceObserver observer, address source, uint32 windowSeconds, uint16 samples)
        public
        view
        returns (Reading memory reading)
    {
        if (windowSeconds < MIN_WINDOW) revert WindowTooShort(windowSeconds);
        if (samples < MIN_SAMPLES || samples > MAX_SAMPLES) revert TooFewSamples(samples);

        uint32 endTime = uint32(block.timestamp);
        int256[] memory series = observer.sampleSeries(source, endTime, windowSeconds, samples);

        Variance v = observer.seriesKind() == IPriceObserver.SeriesKind.TICKS
            ? VarianceMath.fromTicks(series, windowSeconds)
            : VarianceMath.fromPrices(_toUnsigned(series), windowSeconds);

        reading = Reading({
            variance: v,
            // sqrt of a WAD is a WAD once the argument is scaled up first. Getting this wrong
            // produces a number 100x too large and entirely plausible-looking.
            volatilityWad: FixedPointMathLib.sqrt(Variance.unwrap(v) * 1e18),
            genuineObservations: observer.realObservations(source, endTime, windowSeconds),
            expectedObservations: samples,
            sourceDepth: observer.depthQuote(source),
            windowSeconds: windowSeconds
        });
    }

    /// @notice The volatility figure alone, without the provenance fields.
    /// @dev A separate function so that dropping the provenance is an explicit choice.
    function volatility(IPriceObserver observer, address source, uint32 windowSeconds, uint16 samples)
        external
        view
        returns (uint256 volatilityWad)
    {
        return read(observer, source, windowSeconds, samples).volatilityWad;
    }

    /// @notice The same source over several horizons: the term structure, in one call.
    /// @dev Windows are capped by whatever history the source retains; anything longer reverts
    ///      rather than silently returning a shorter measurement.
    function termStructure(
        IPriceObserver observer,
        address source,
        uint32[] calldata windows,
        uint16 samples
    ) external view returns (Reading[] memory readings) {
        readings = new Reading[](windows.length);
        for (uint256 i = 0; i < windows.length; ++i) {
            readings[i] = read(observer, source, windows[i], samples);
        }
    }

    function _toUnsigned(int256[] memory a) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            out[i] = a[i] < 0 ? 0 : uint256(a[i]);
        }
    }
}

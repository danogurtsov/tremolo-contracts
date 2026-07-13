// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceObserver} from "../interfaces/IPriceObserver.sol";
import {IUniswapV3PoolOracle} from "../interfaces/IUniswapV3PoolOracle.sol";

/// @title UniV3Observer
/// @notice Reads a Uniswap V3 observation ring buffer and rebuilds an evenly spaced tick series.
///
/// @dev The whole point of this adapter: the series is reconstructed *after the fact*, in a
///      single `observe()` call at settlement. Nobody records anything during the life of the
///      swap. No keepers, no scheduled writes, no "who pays for the observation" problem, and
///      no window in which choosing the moment of observation is worth money.
///
///      What it costs instead is a dependency on the pool's ring buffer, and that dependency
///      has a counterintuitive shape worth stating plainly:
///
///        the busier the pool, the SHORTER its memory.
///
///      The buffer holds `observationCardinality` entries and one entry is written per block
///      that touches the pool. A heavily traded pool overwrites its oldest entry within
///      minutes. Depth of liquidity — which is what protects against manipulation — therefore
///      works *against* depth of history. Anyone can pay to extend the buffer via
///      `increaseObservationCardinalityNext`, which is why extending it is treated here as
///      part of operating the protocol rather than someone else's responsibility.
///
///      Second known limitation, stated rather than hidden: between two genuine recordings
///      Uniswap interpolates linearly. A dense grid over a quiet pool therefore yields an
///      artificially smooth series and understates realized variance. This adapter does not
///      correct for that — it *reports* it through `realObservations`, and the market refuses
///      to settle a window that is too sparse.
contract UniV3Observer is IPriceObserver {
    /// @notice Extra history required beyond the series window itself.
    /// @dev A window that fits exactly today may not fit at settlement, because the buffer
    ///      keeps advancing. Creation demands headroom so the series does not become
    ///      unsettleable through nothing but the passage of time.
    uint32 public constant LOOKBACK_HEADROOM = 1 hours;

    error InsufficientLookback(uint32 available, uint32 required);
    error InsufficientCardinality(uint16 cardinality, uint16 required);
    error TooFewSamples(uint16 samples);
    error WindowTooLong(uint32 windowSeconds);
    error FutureWindow();

    /// @dev Upper bound on a single settlement read, set from a measurement rather than a
    ///      guess. Gas for `sampleTicks` against the real WETH/USDC pool on Base:
    ///
    ///           12 points     0.50M      24 points     0.65M
    ///           96 points     2.48M     256 points    ~8.0M
    ///          512 points    17.44M    1024 points    48.68M
    ///
    ///      Cost per point is roughly flat up to ~96 and then climbs, because each reading
    ///      binary-searches a ring buffer that has to be walked further back. 1024 points was
    ///      the original limit and is not usable: 48.68M gas is 12% of a whole Base block for a
    ///      single settlement, and more than an entire Ethereum block.
    ///
    ///      256 sits at ~8M — a couple of percent of a Base block — and is the largest grid
    ///      worth allowing. See docs/measurements/gas_profile.md and ADR-0006.
    uint16 public constant MAX_SAMPLES = 256;
    uint16 public constant MIN_SAMPLES = 2;

    /// @inheritdoc IPriceObserver
    function kind() external pure returns (string memory) {
        return "uniswap-v3-twap";
    }

    /// @inheritdoc IPriceObserver
    function maxLookback(address source) public view returns (uint32) {
        IUniswapV3PoolOracle pool = IUniswapV3PoolOracle(source);
        (,, uint16 index, uint16 cardinality,,,) = pool.slot0();

        // The oldest surviving entry sits just after the newest one in the ring. If that slot
        // was never initialised the buffer has not wrapped yet, so entry zero is the oldest.
        (uint32 oldest,,, bool initialized) = pool.observations((index + 1) % cardinality);
        if (!initialized) (oldest,,,) = pool.observations(0);

        uint32 nowTs = uint32(block.timestamp);
        return nowTs > oldest ? nowTs - oldest : 0;
    }

    /// @inheritdoc IPriceObserver
    /// @dev Walks the ring backwards from the newest entry and counts those inside the window.
    ///      Bounded by `cardinality`, so cost is bounded by the pool's own buffer size.
    function realObservations(address source, uint32 endTime, uint32 windowSeconds)
        external
        view
        returns (uint256 count)
    {
        IUniswapV3PoolOracle pool = IUniswapV3PoolOracle(source);
        (,, uint16 index, uint16 cardinality,,,) = pool.slot0();
        uint32 startTime = endTime - windowSeconds;

        for (uint16 i = 0; i < cardinality; ++i) {
            uint16 slot = uint16((uint256(index) + cardinality - i) % cardinality);
            (uint32 ts,,, bool initialized) = pool.observations(slot);
            if (!initialized) continue;
            if (ts > endTime) continue;
            if (ts < startTime) break; // walking backwards: everything older is out of range
            ++count;
        }
    }

    /// @inheritdoc IPriceObserver
    function validateSource(address source, uint32 windowSeconds, uint16 samples) external view {
        if (samples < MIN_SAMPLES || samples > MAX_SAMPLES) revert TooFewSamples(samples);

        IUniswapV3PoolOracle pool = IUniswapV3PoolOracle(source);
        (,,, uint16 cardinality,,,) = pool.slot0();

        // A pool cannot describe a window it has no room to remember. Requiring one buffer
        // entry per sample is a floor, not a guarantee — entries are only written when the
        // pool is touched. Sparse windows are caught again at settlement by completeness.
        if (cardinality < samples) revert InsufficientCardinality(cardinality, samples);

        uint32 available = maxLookback(source);
        uint32 required = windowSeconds + LOOKBACK_HEADROOM;
        if (available < required) revert InsufficientLookback(available, required);
    }

    /// @inheritdoc IPriceObserver
    /// @dev One `observe()` call returns the whole series. `tickCumulative` is the running
    ///      integral of tick over time, so the average tick across a grid step is the
    ///      difference of two cumulatives divided by the step — an arithmetic mean of ticks,
    ///      i.e. a geometric mean of prices. That is the right series for log returns.
    function sampleTicks(address source, uint32 endTime, uint32 windowSeconds, uint16 samples)
        external
        view
        returns (int256[] memory ticks)
    {
        if (samples < MIN_SAMPLES || samples > MAX_SAMPLES) revert TooFewSamples(samples);
        if (endTime > block.timestamp) revert FutureWindow();
        if (windowSeconds == 0 || windowSeconds > 365 days) revert WindowTooLong(windowSeconds);

        uint32 available = maxLookback(source);
        if (available < windowSeconds) revert InsufficientLookback(available, windowSeconds);

        // `samples` average ticks need `samples + 1` cumulative readings.
        uint256 points = uint256(samples) + 1;
        uint32[] memory secondsAgos = new uint32[](points);

        uint32 nowTs = uint32(block.timestamp);
        uint32 endAgo = nowTs - endTime;
        // Integer step; any remainder is absorbed into the oldest interval so the window is
        // covered exactly rather than drifting short.
        uint32 step = windowSeconds / samples;

        for (uint256 i = 0; i < points; ++i) {
            uint32 back = uint32((points - 1 - i) * step);
            secondsAgos[i] = endAgo + (i == 0 ? windowSeconds : back);
        }

        (int56[] memory tickCumulatives,) = IUniswapV3PoolOracle(source).observe(secondsAgos);

        ticks = new int256[](samples);
        for (uint256 i = 0; i < samples; ++i) {
            uint32 dt = i == 0 ? windowSeconds - (samples - 1) * step : step;
            ticks[i] = (int256(tickCumulatives[i + 1]) - int256(tickCumulatives[i])) / int256(uint256(dt));
        }
    }
}

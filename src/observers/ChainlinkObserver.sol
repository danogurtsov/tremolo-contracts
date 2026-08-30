// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceObserver} from "../interfaces/IPriceObserver.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";

/// @title ChainlinkObserver
/// @notice Rebuilds a price series from a Chainlink aggregator's round history.
///
/// @dev The second adapter, and the one that exposed where `IPriceObserver` was still shaped
///      around Uniswap. Three things had to change or be conceded:
///
///      **1. Scale.** The interface returned "ticks", because ticks are logarithms and cost
///      nothing to difference. A feed reports prices. Forcing them into ticks would mean a
///      logarithm plus rounding to an integer tick — up to a basis point discarded per sample,
///      against typical four-minute moves of a few ticks. The interface now carries a
///      `seriesKind` and the market picks the matching maths.
///
///      **2. History is indexed by round, not by time.** Uniswap answers "what was the price
///      N seconds ago" directly. Chainlink answers "what was round R", and finding the round in
///      force at a given instant means searching. That search is unbounded in principle, so the
///      adapter walks backwards with a hard step limit and gives up rather than burning the
///      block. Which means:
///
///      **3. This adapter is materially worse than the Uniswap one.** A grid of 24 points costs 24
///      searches, each up to `MAX_SEARCH_STEPS` reads. Feeds update on deviation thresholds, so
///      between updates the series is a step function (flat, not interpolated) and
///      realized variance computed from it understates whatever happened in between. On a feed
///      with a 0.5% deviation threshold, everything smaller than 0.5% is invisible.
///
///      It exists for assets with no on-chain venue deep enough to trust. For anything with a
///      real pool, the Uniswap adapter is better on every axis: cheaper, finer, and free of the
///      logarithm.
contract ChainlinkObserver is IPriceObserver {
    /// @dev How far back the search will walk before refusing. Each step is one `getRoundData`,
    ///      so this bounds the cost of a settlement read to something payable.
    uint80 public constant MAX_SEARCH_STEPS = 512;

    uint16 public constant MAX_SAMPLES = 64;
    uint16 public constant MIN_SAMPLES = 2;

    /// @dev A feed that has not updated for this long is treated as dead, whatever it last said.
    uint32 public constant MAX_STALENESS = 6 hours;

    error TooFewSamples(uint16 samples);
    error FutureWindow();
    error InvalidWindow(uint32 windowSeconds);
    error NoRoundCovers(uint32 timestamp);
    error StaleFeed(uint256 updatedAt, uint256 nowTs);
    error NonPositivePrice(int256 answer);
    error InsufficientHistory(uint32 available, uint32 required);
    error FeedDecimalsTooHigh(uint8 decimals);

    /// @inheritdoc IPriceObserver
    function seriesKind() external pure returns (SeriesKind) {
        return SeriesKind.PRICES_WAD;
    }

    /// @inheritdoc IPriceObserver
    function kind() external pure returns (string memory) {
        return "chainlink-aggregator";
    }

    /// @inheritdoc IPriceObserver
    /// @dev How far back the search can reach, which is not the same as how much history the
    ///      feed has: the limit is the step budget, not the archive.
    function maxLookback(address source) public view returns (uint32) {
        IChainlinkAggregator feed = IChainlinkAggregator(source);
        (uint80 roundId,,, uint256 updatedAt,) = feed.latestRoundData();

        uint80 oldest = roundId > MAX_SEARCH_STEPS ? roundId - MAX_SEARCH_STEPS : 1;
        try feed.getRoundData(oldest) returns (uint80, int256, uint256, uint256 oldestUpdatedAt, uint80) {
            if (oldestUpdatedAt == 0 || oldestUpdatedAt >= updatedAt) return 0;
            return uint32(block.timestamp - oldestUpdatedAt);
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IPriceObserver
    /// @dev A feed has no on-chain depth: it cannot be moved by trading against it, because
    ///      there is nothing to trade against. The notional bound therefore does not apply.
    ///      The corresponding risk is different
    ///      in kind — corrupting a feed means corrupting its operators — and is not addressed by
    ///      sizing.
    function depthQuote(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IPriceObserver
    /// @dev A feed's history is whatever its operators have published. There is nothing to buy
    ///      and nothing to ask for, so this is a no-op.
    function extendHistory(address, uint16) external pure {}

    /// @inheritdoc IPriceObserver
    function quoteToken(address) external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IPriceObserver
    /// @dev A feed has no notion of "an observation was recorded in this window" beyond its own
    ///      rounds, so this counts rounds. Note what that means for the completeness check: a
    ///      quiet feed has few rounds, and a series on it will void — which is the
    ///      correct outcome, since a step function is not a measurement of volatility.
    function realObservations(address source, uint32 endTime, uint32 windowSeconds)
        external
        view
        returns (uint256 count)
    {
        IChainlinkAggregator feed = IChainlinkAggregator(source);
        (uint80 roundId,,,,) = feed.latestRoundData();
        uint32 startTime = endTime - windowSeconds;

        for (uint80 i = 0; i < MAX_SEARCH_STEPS && roundId > i; ++i) {
            try feed.getRoundData(roundId - i) returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
                if (updatedAt == 0 || updatedAt > endTime) continue;
                if (updatedAt < startTime) break;
                ++count;
            } catch {
                break; // phase boundary: earlier rounds are unreachable from this aggregator
            }
        }
    }

    /// @inheritdoc IPriceObserver
    function validateSource(address source, uint32 windowSeconds, uint16 samples) external view {
        if (samples < MIN_SAMPLES || samples > MAX_SAMPLES) revert TooFewSamples(samples);

        IChainlinkAggregator feed = IChainlinkAggregator(source);

        // A feed reporting more than 18 decimals underflows `10 ** (18 - decimals)` at
        // settlement and reverts on every read, so the series could only ever void. Reject it
        // at creation rather than let it be funded and stranded.
        uint8 dec = feed.decimals();
        if (dec > 18) revert FeedDecimalsTooHigh(dec);

        (,,, uint256 updatedAt,) = feed.latestRoundData();
        if (block.timestamp > updatedAt + MAX_STALENESS) revert StaleFeed(updatedAt, block.timestamp);

        uint32 available = maxLookback(source);
        if (available < windowSeconds) revert InsufficientHistory(available, windowSeconds);
    }

    /// @inheritdoc IPriceObserver
    /// @dev ONE backward pass over the round history, not one per grid point. The previous
    ///      restart-from-latest-per-point cost O(samples · rounds); for a dense feed that
    ///      exceeded the market's settlement gas floor, so `eth_estimateGas` settled every
    ///      Chainlink series on the cheap void path. Here the rounds spanning the window are
    ///      collected once (O(rounds)), then each grid point is assigned by walking a monotone
    ///      cursor (O(samples)). Grid points also span the window exactly (first at startTime,
    ///      last at endTime), so realized variance is not systematically understated by an
    ///      omitted final interval. Prices are normalised to WAD from the feed's own decimals.
    function sampleSeries(address source, uint32 endTime, uint32 windowSeconds, uint16 samples)
        external
        view
        returns (int256[] memory series)
    {
        if (samples < MIN_SAMPLES || samples > MAX_SAMPLES) revert TooFewSamples(samples);
        if (endTime > block.timestamp) revert FutureWindow();
        if (windowSeconds == 0 || windowSeconds > 365 days) revert InvalidWindow(windowSeconds);

        IChainlinkAggregator feed = IChainlinkAggregator(source);
        uint256 scale = 10 ** (18 - feed.decimals());
        uint32 startTime = endTime - windowSeconds;

        // Collect rounds newest→oldest in one pass, until we cover startTime or exhaust the
        // step budget. `ts`/`ans` are parallel, index 0 = latest.
        (uint80 latest,,,,) = feed.latestRoundData();
        uint32[] memory ts = new uint32[](MAX_SEARCH_STEPS);
        int256[] memory ans = new int256[](MAX_SEARCH_STEPS);
        uint256 n;
        for (uint80 i = 0; i < MAX_SEARCH_STEPS && latest > i; ++i) {
            try feed.getRoundData(latest - i) returns (
                uint80, int256 answer, uint256, uint256 updatedAt, uint80
            ) {
                if (updatedAt == 0) break; // unset round
                if (answer <= 0) revert NonPositivePrice(answer);
                ts[n] = uint32(updatedAt);
                ans[n] = answer;
                ++n;
                if (updatedAt <= startTime) break; // window start covered
            } catch {
                break; // phase boundary: earlier rounds unreachable
            }
        }
        if (n == 0) revert NoRoundCovers(startTime);

        // Grid points span [startTime, endTime] exactly: at_i = startTime + i*window/(samples-1).
        // The cursor into `ts` only moves toward newer rounds as `at` increases, so the whole
        // assignment is a single linear walk.
        series = new int256[](samples);
        uint256 idx = n - 1; // start at the oldest collected round for the earliest point
        uint256 denom = uint256(samples) - 1;
        for (uint256 i = 0; i < samples; ++i) {
            uint32 at = startTime + uint32((i * uint256(windowSeconds)) / denom);
            // advance to the newest round whose timestamp is <= at
            while (idx > 0 && ts[idx - 1] <= at) --idx;
            if (ts[idx] > at) revert NoRoundCovers(at); // no round at or before this point
            series[i] = ans[idx] * int256(scale);
        }
    }

    /// @inheritdoc IPriceObserver
    /// @dev Worst case is one backward pass of MAX_SEARCH_STEPS getRoundData reads here plus
    ///      another in realObservations, then a per-sample assignment. Sized well above that so
    ///      an honest settlement always passes and only a genuinely underfunded call reverts —
    ///      far larger than the tick adapter's per-sample cost, which is exactly why the market
    ///      asks the observer instead of assuming a single constant.
    function settleGasFloor(address, uint16 samples, uint32) external pure returns (uint256) {
        return (uint256(MAX_SEARCH_STEPS) * 2 + uint256(samples)) * 12_000;
    }
}

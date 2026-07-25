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
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        if (block.timestamp > updatedAt + MAX_STALENESS) revert StaleFeed(updatedAt, block.timestamp);

        uint32 available = maxLookback(source);
        if (available < windowSeconds) revert InsufficientHistory(available, windowSeconds);
    }

    /// @inheritdoc IPriceObserver
    /// @dev One backward search per grid point. Prices are normalised to WAD from the feed's own
    ///      decimals, so the market never has to know what a given feed reports in.
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
        uint32 step = windowSeconds / samples;
        uint32 startTime = endTime - windowSeconds;

        series = new int256[](samples);
        (uint80 latest,,,,) = feed.latestRoundData();

        for (uint256 i = 0; i < samples; ++i) {
            uint32 at = startTime + uint32(i * step);
            int256 answer = _priceAt(feed, latest, at);
            series[i] = answer * int256(scale);
        }
    }

    /// @dev The price in force at `at`: the most recent round whose `updatedAt` is at or before
    ///      it. Walks backwards from the latest round, because feeds are read near their head far
    ///      more often than deep in their history, and a binary search over a range that may
    ///      cross a phase boundary is not sound.
    function _priceAt(IChainlinkAggregator feed, uint80 latest, uint32 at) internal view returns (int256) {
        for (uint80 i = 0; i < MAX_SEARCH_STEPS && latest > i; ++i) {
            try feed.getRoundData(latest - i) returns (
                uint80, int256 answer, uint256, uint256 updatedAt, uint80
            ) {
                if (updatedAt == 0 || updatedAt > at) continue;
                if (answer <= 0) revert NonPositivePrice(answer);
                return answer;
            } catch {
                break;
            }
        }
        revert NoRoundCovers(at);
    }
}

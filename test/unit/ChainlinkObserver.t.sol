// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {ChainlinkObserver} from "../../src/observers/ChainlinkObserver.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {IPriceObserver} from "../../src/interfaces/IPriceObserver.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice A second adapter, written to test the abstraction rather than the feed.
/// @dev The interface claimed to be source-agnostic while having exactly one implementation.
///      This is what happens when a second one arrives.
contract ChainlinkObserverTest is Test {
    ChainlinkObserver internal observer;
    MockChainlinkFeed internal feed;
    VarianceMarket internal market;
    MockERC20 internal usdc;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        observer = new ChainlinkObserver();
        feed = new MockChainlinkFeed(8); // ETH/USD convention
        market = new VarianceMarket(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Two days of history at five-minute cadence, drifting and oscillating.
        uint256 ts = block.timestamp - 2 days;
        int256 price = 2500e8;
        while (ts <= block.timestamp) {
            feed.push(price, ts);
            price += (int256(ts) % 7 - 3) * 1e8 / 10;
            ts += 5 minutes;
        }

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
    }

    /// @notice The adapter declares that it returns prices, not ticks.
    /// @dev The interface change this adapter forced. Before it, "the series" implicitly meant
    ///      ticks, because the only implementation had ticks.
    function test_declaresPriceScale() public {
        assertEq(uint8(observer.seriesKind()), uint8(IPriceObserver.SeriesKind.PRICES_WAD));
        assertEq(uint8(new UniV3Observer().seriesKind()), uint8(IPriceObserver.SeriesKind.TICKS));
    }

    /// @notice Prices come back normalised to WAD regardless of the feed's own decimals.
    function test_sampleSeries_normalisesToWad() public view {
        int256[] memory series = observer.sampleSeries(address(feed), uint32(block.timestamp), 6 hours, 12);

        assertEq(series.length, 12);
        for (uint256 i = 0; i < series.length; ++i) {
            // 8-decimal feed at ~2500 becomes ~2500e18.
            assertGt(series[i], 1000e18);
            assertLt(series[i], 10_000e18);
        }
    }

    /// @notice A full series settles through the market on the price path.
    /// @dev The end-to-end check that the dispatch works: the market must notice the adapter
    ///      reports prices and use `fromPrices` instead of differencing them as if they were
    ///      logarithms, which would produce a number too large to be meaningful.
    function test_settlesThroughTheMarketOnAPriceFeed() public {
        uint256 id = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(feed),
                collateral: address(usdc),
                startTime: uint64(block.timestamp + 30 minutes),
                expiry: uint64(block.timestamp + 30 minutes + 6 hours),
                samples: 12,
                minCompletenessBps: 5000,
                capMultiple: 2.5e18,
                strike: Variance.wrap(0.04e18),
                notionalPerUnit: 1000e6
            })
        );

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 2e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 2e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);

        // Keep the feed alive across the window.
        uint256 ts = s.startTime;
        int256 price = 2500e8;
        while (ts <= s.expiry) {
            feed.push(price, ts);
            price += (int256(ts) % 5 - 2) * 1e8 / 5;
            ts += 5 minutes;
        }
        vm.warp(s.expiry);

        IVarianceMarket.State state = market.settle(id);
        assertEq(uint8(state), uint8(IVarianceMarket.State.SETTLED), "price-feed series failed to settle");

        uint256 rv = Variance.unwrap(market.getSeries(id).realizedVariance);
        console2.log("realized variance from a price feed (wad)", rv);
        assertLt(rv, 100e18, "variance implausible - series was probably read as ticks");
    }

    /// @notice A stale feed is refused at creation.
    function test_validateSource_rejectsStaleFeed() public {
        MockChainlinkFeed dead = new MockChainlinkFeed(8);
        dead.push(2500e8, block.timestamp - 12 hours);

        vm.expectRevert();
        observer.validateSource(address(dead), 1 hours, 12);
    }

    /// @notice History that ends at a phase boundary is reported as ending, not as zero prices.
    /// @dev Real aggregators revert on rounds from an earlier phase. An adapter that treated the
    ///      revert as "price zero" would settle a series on fabricated data.
    function test_phaseBoundaryEndsHistoryCleanly() public {
        feed.setPhaseStart(feed.latest() - 10);

        // Only ten rounds are reachable, so a six-hour window cannot be covered.
        vm.expectRevert();
        observer.sampleSeries(address(feed), uint32(block.timestamp), 6 hours, 12);
    }

    /// @notice What the second adapter costs compared with the first.
    /// @dev Chainlink is indexed by round, so each grid point is a
    ///      backward search; Uniswap answers the whole grid in one call.
    function test_costComparisonAgainstUniswap() public {
        MockUniV3Pool pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));
        uint32 ts = uint32(block.timestamp - 6 hours);
        while (ts <= block.timestamp) {
            pool.writeObservation(ts, 200_000 + int24(int256(uint256(ts) % 40)));
            ts += 5 minutes;
        }
        UniV3Observer uni = new UniV3Observer();

        uint256 g0 = gasleft();
        uni.sampleSeries(address(pool), uint32(block.timestamp), 6 hours, 12);
        uint256 uniGas = g0 - gasleft();

        g0 = gasleft();
        observer.sampleSeries(address(feed), uint32(block.timestamp), 6 hours, 12);
        uint256 linkGas = g0 - gasleft();

        console2.log("uniswap  12 points, gas", uniGas);
        console2.log("chainlink 12 points, gas", linkGas);
        console2.log("ratio (x100)           ", linkGas * 100 / uniGas);
    }
}

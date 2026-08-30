// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {ChainlinkObserver} from "../../src/observers/ChainlinkObserver.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";

/// @notice Regression tests for an internal security review: each asserts a hardening that
///         closed a specific defect. Named by behaviour, not by finding.
contract SecurityReviewTest is BaseTest {
    // ---------------------------------------------------------------------
    // openImmediate authorization
    // ---------------------------------------------------------------------

    /// @notice An unauthorized caller cannot open a series that pulls a third party's collateral.
    function test_openImmediate_rejectsUnauthorizedCaller() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        // carol is neither an authorized opener nor one of the funded sides
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.NotAuthorizedOpener.selector, carol));
        market.openImmediate(p, alice, bob, 1e18);
    }

    /// @notice A caller the guardian authorized can open on behalf of two funded parties.
    function test_openImmediate_allowsAuthorizedOpener() public {
        vm.prank(guardian);
        market.setAuthorizedOpener(carol, true);

        IVarianceMarket.SeriesParams memory p = defaultParams();
        vm.prank(carol);
        uint256 id = market.openImmediate(p, alice, bob, 1e18);
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.ACTIVE));
    }

    /// @notice Opening entirely against one's own funds needs no authorization.
    function test_openImmediate_allowsSelfOpen() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        vm.prank(alice);
        uint256 id = market.openImmediate(p, alice, alice, 1e18);
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.ACTIVE));
    }

    /// @notice Only the guardian can grant opener rights.
    function test_setAuthorizedOpener_onlyGuardian() public {
        vm.prank(carol);
        vm.expectRevert(IVarianceMarket.NotGuardian.selector);
        market.setAuthorizedOpener(carol, true);
    }

    // ---------------------------------------------------------------------
    // Window bound is enforced before the uint32 narrowing
    // ---------------------------------------------------------------------

    /// @notice An expiry ~2^32 seconds out cannot masquerade as a short window.
    function test_createSeries_rejectsWindowThatTruncatesToValid() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        // real duration = 2^32 + WINDOW; low 32 bits = WINDOW, which would pass a truncated check
        p.startTime = uint64(block.timestamp + 1);
        p.expiry = uint64(uint256(p.startTime) + (uint256(1) << 32) + WINDOW);
        vm.expectRevert();
        market.createSeries(p);
    }

    // ---------------------------------------------------------------------
    // Completeness floor
    // ---------------------------------------------------------------------

    /// @notice A zero completeness floor (which would disable the sparse-window void) is rejected.
    function test_createSeries_rejectsZeroCompleteness() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.minCompletenessBps = 0;
        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.InvalidCompleteness.selector, uint16(0)));
        market.createSeries(p);
    }

    /// @notice Anything below the floor is rejected; the floor itself is accepted.
    function test_createSeries_completenessFloor() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.minCompletenessBps = 4999;
        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.InvalidCompleteness.selector, uint16(4999)));
        market.createSeries(p);

        p.minCompletenessBps = 5000;
        market.createSeries(p); // at the floor: ok
    }

    // ---------------------------------------------------------------------
    // Depth cap resists a spot-liquidity flash
    // ---------------------------------------------------------------------

    /// @notice depthQuote reads a time-average, so inflating spot liquidity does not move it.
    function test_depthQuote_ignoresSpotLiquidityFlash() public {
        // Dense recent history at a normal liquidity, ending at now so the TWA window has no
        // forward-extrapolated tail.
        pool.setLiquidity(1e18);
        uint32 t = uint32(block.timestamp) - 700;
        while (t < uint32(block.timestamp)) {
            pool.writeObservation(t, START_TICK);
            t += 30;
        }
        pool.writeObservation(uint32(block.timestamp), START_TICK);

        uint256 depthBefore = observer.depthQuote(address(pool));
        assertGt(depthBefore, 0, "sanity: depth is non-zero");

        // Flash-inflate spot in-range liquidity 1000x; the TWA over the last 10 minutes must
        // barely move (a spot read would have jumped 1000x).
        pool.setLiquidity(1e21);
        uint256 depthAfter = observer.depthQuote(address(pool));

        // within 1% — the one-block tail is negligible against the 600s average
        assertApproxEqRel(depthAfter, depthBefore, 0.01e18, "TWA depth moved with spot flash");
    }

    // ---------------------------------------------------------------------
    // Chainlink feed decimals bound
    // ---------------------------------------------------------------------

    /// @notice A feed reporting more than 18 decimals is rejected at creation, not left to void.
    function test_chainlink_rejectsFeedDecimalsAbove18() public {
        ChainlinkObserver link = new ChainlinkObserver();
        MockChainlinkFeed feed = new MockChainlinkFeed(19);
        feed.push(1e19, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkObserver.FeedDecimalsTooHigh.selector, uint8(19)));
        link.validateSource(address(feed), WINDOW, SAMPLES);
    }
}

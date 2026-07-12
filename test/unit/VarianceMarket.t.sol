// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Rules enforced at the edges of the market contract.
/// @dev Series parameters are immutable once created, which makes validation the only defence
///      against a series that is wrong forever. Each of these is a case where creation must
///      fail rather than produce an instrument nobody can use or unwind.
contract VarianceMarketTest is BaseTest {
    // ---------------------------------------------------------------------
    // Creation validation
    // ---------------------------------------------------------------------

    function test_createSeries_storesImmutableParameters() public {
        uint256 id = createDefaultSeries();
        IVarianceMarket.Series memory s = market.getSeries(id);

        assertEq(s.observer, address(observer));
        assertEq(s.source, address(pool));
        assertEq(s.collateral, address(usdc));
        assertEq(Variance.unwrap(s.strike), Variance.unwrap(STRIKE));
        assertEq(s.capMultiple, CAP);
        assertEq(uint8(s.state), uint8(IVarianceMarket.State.SUBSCRIBING));
        assertEq(market.seriesCount(), id);
    }

    function test_createSeries_revertsOnPastStart() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.startTime = uint64(block.timestamp);
        vm.expectRevert(IVarianceMarket.StartInPast.selector);
        market.createSeries(p);
    }

    function test_createSeries_revertsOnExpiryBeforeStart() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.expiry = p.startTime;
        vm.expectRevert(IVarianceMarket.ExpiryBeforeStart.selector);
        market.createSeries(p);
    }

    function test_createSeries_revertsOnZeroStrike() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.strike = Variance.wrap(0);
        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.InvalidStrike.selector, 0));
        market.createSeries(p);
    }

    /// @dev A cap at or below 1.0 gives the short side no room above the strike, so its
    ///      deposit is zero and it takes on exposure it never paid for.
    function test_createSeries_revertsOnCapBelowOne() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.capMultiple = 1e18;
        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.InvalidCap.selector, uint64(1e18)));
        market.createSeries(p);
    }

    /// @dev Grid steps below a minute are finer than blocks are reliable, and produce a series
    ///      that is mostly interpolation regardless of how busy the pool is.
    function test_createSeries_revertsOnTooFineGrid() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.samples = 2000; // 86400 / 2000 = 43 seconds
        vm.expectRevert();
        market.createSeries(p);
    }

    /// @dev Rounding can drive a deposit to zero when the notional is tiny; a side holding
    ///      exposure for free is worse than no series at all.
    function test_createSeries_revertsOnDegenerateCollateral() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.notionalPerUnit = 1;
        p.strike = Variance.wrap(1e12);
        vm.expectRevert(IVarianceMarket.DegenerateCollateral.selector);
        market.createSeries(p);
    }

    /// @notice A pool whose buffer cannot span the window is rejected at creation.
    /// @dev This is the failure the observer exists to catch. Without it, the series is
    ///      created, collateral is committed, and the gap only surfaces at settlement.
    function test_createSeries_revertsWhenPoolHistoryTooShort() public {
        MockUniV3Pool shallow = new MockUniV3Pool(START_TICK, 512, uint32(block.timestamp - 10 minutes));
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.source = address(shallow);

        vm.expectRevert(
            abi.encodeWithSelector(
                UniV3Observer.InsufficientLookback.selector, uint32(10 minutes), WINDOW + 1 hours
            )
        );
        market.createSeries(p);
    }

    /// @notice A pool with fewer buffer slots than grid points is rejected.
    function test_createSeries_revertsOnInsufficientCardinality() public {
        MockUniV3Pool narrow = new MockUniV3Pool(START_TICK, 8, uint32(block.timestamp - 2 days));
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.source = address(narrow);

        vm.expectRevert(
            abi.encodeWithSelector(UniV3Observer.InsufficientCardinality.selector, uint16(8), SAMPLES)
        );
        market.createSeries(p);
    }

    // ---------------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------------

    function test_subscribe_revertsAfterStart() public {
        uint256 id = createDefaultSeries();
        vm.warp(market.getSeries(id).startTime);

        vm.prank(alice);
        vm.expectRevert(IVarianceMarket.SubscriptionClosed.selector);
        market.subscribe(id, IVarianceMarket.Side.LONG, 1e18);
    }

    function test_activate_revertsBeforeStart() public {
        uint256 id = createDefaultSeries();
        vm.expectRevert(IVarianceMarket.TooEarly.selector);
        market.activate(id);
    }

    function test_settle_revertsBeforeExpiry() public {
        uint256 id = openMatchedSeries(3e18);
        vm.expectRevert(IVarianceMarket.TooEarly.selector);
        market.settle(id);
    }

    function test_settle_revertsIfAlreadySettled() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        vm.expectRevert(
            abi.encodeWithSelector(IVarianceMarket.WrongState.selector, IVarianceMarket.State.SETTLED)
        );
        market.settle(id);
    }

    function test_net_revertsWithoutBothLegs() public {
        uint256 id = openMatchedSeries(5e18);
        vm.prank(alice); // holds only the long leg
        vm.expectRevert(IVarianceMarket.InsufficientPosition.selector);
        market.net(id, 1e18);
    }

    function test_redeem_revertsBeforeSettlement() public {
        uint256 id = openMatchedSeries(5e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IVarianceMarket.WrongState.selector, IVarianceMarket.State.ACTIVE)
        );
        market.redeem(id, IVarianceMarket.Side.LONG, 1e18, alice);
    }

    /// @notice Redeeming twice is impossible: the position is burned on the way out.
    function test_redeem_cannotBeReplayed() public {
        uint256 id = openMatchedSeries(4e18);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        vm.startPrank(alice);
        market.redeem(id, IVarianceMarket.Side.LONG, 4e18, alice);
        vm.expectRevert(IVarianceMarket.InsufficientPosition.selector);
        market.redeem(id, IVarianceMarket.Side.LONG, 1e18, alice);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Guardian boundary
    // ---------------------------------------------------------------------

    function test_guardian_canPauseCreation() public {
        vm.prank(guardian);
        market.setCreationPaused(true);

        vm.expectRevert(IVarianceMarket.CreationPaused.selector);
        market.createSeries(defaultParams());
    }

    function test_guardian_cannotBeAnyoneElse() public {
        vm.prank(alice);
        vm.expectRevert(IVarianceMarket.NotGuardian.selector);
        market.setCreationPaused(true);
    }

    /// @notice A paused guardian cannot stop an existing series from settling or paying out.
    /// @dev The whole point of the guardian boundary. Anyone already exposed must be able to
    ///      reach their money without permission from anybody.
    function test_guardian_cannotBlockSettlementOfLiveSeries() public {
        uint256 id = openMatchedSeries(6e18);

        vm.prank(guardian);
        market.setCreationPaused(true);

        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        vm.prank(alice);
        market.redeem(id, IVarianceMarket.Side.LONG, 6e18, alice);
        vm.prank(bob);
        market.redeem(id, IVarianceMarket.Side.SHORT, 6e18, bob);

        assertEq(usdc.balanceOf(address(market)), 0, "guardian could not be routed around");
    }

    // ---------------------------------------------------------------------
    // Accounting
    // ---------------------------------------------------------------------

    /// @notice Long and short deposits add up to the pot for the default parameters.
    function test_collateralSplit_matchesMaximumLosses() public {
        uint256 id = createDefaultSeries();

        uint256 long = market.collateralPerUnit(id, IVarianceMarket.Side.LONG);
        uint256 short = market.collateralPerUnit(id, IVarianceMarket.Side.SHORT);

        // K = 0.04, notional 1000 USDC per 1.0 of variance -> long risks 40 USDC.
        assertEq(long, 40e6, "long deposit != notional * K");
        // (cap - 1) * K = 1.5 * 0.04 = 0.06 -> short risks 60 USDC.
        assertEq(short, 60e6, "short deposit != notional * (cap-1) * K");
        assertEq(long + short, market.totalCollateralPerUnit(id));
    }

    /// @notice A subscription round trip costs at most one wei, and that wei stays in the series.
    /// @dev Deposits round up and withdrawals round down: symmetric
    ///      rounding would let a subscription be withdrawn in parts for more than it cost,
    ///      since ceil(a+b) can be one wei below ceil(a) + ceil(b). The asymmetry moves that
    ///      wei to the pool instead of taking it from another user's collateral.
    function testFuzz_subscribeThenUnsubscribe_costsAtMostOneWei(uint256 units) public {
        units = bound(units, 0.0001e18, 1000e18);
        uint256 id = createDefaultSeries();
        uint256 before = usdc.balanceOf(alice);

        vm.startPrank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        market.unsubscribe(id, IVarianceMarket.Side.LONG, units);
        vm.stopPrank();

        uint256 lost = before - usdc.balanceOf(alice);
        assertLe(lost, 1, "round trip lost more than one wei");
        assertEq(market.collateralHeld(id), lost, "the wei left the series");
    }

    /// @notice Withdrawing in parts never returns more than depositing in one go.
    /// @dev The concrete attack the asymmetry closes: subscribe once, withdraw in slices.
    function testFuzz_partialWithdrawalsCannotExceedDeposit(uint256 units, uint8 slices) public {
        units = bound(units, 0.01e18, 1000e18);
        slices = uint8(bound(slices, 2, 8));

        uint256 id = createDefaultSeries();
        uint256 before = usdc.balanceOf(alice);

        vm.startPrank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        uint256 each = units / slices;
        for (uint256 i = 0; i < slices - 1; ++i) {
            market.unsubscribe(id, IVarianceMarket.Side.LONG, each);
        }
        market.unsubscribe(id, IVarianceMarket.Side.LONG, units - each * (slices - 1));
        vm.stopPrank();

        assertLe(usdc.balanceOf(alice), before, "sliced withdrawal returned more than was paid");
    }
}

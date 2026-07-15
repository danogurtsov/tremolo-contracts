// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Every event the market emits, checked field by field.
///
/// @dev Events are the public API for everything that is not a transaction: the indexer, the
///      terminal, the portfolio view, any analytics anyone builds on top. Nothing else in this
///      repository asserted a single one of them, which meant a swapped argument or a wrong
///      `indexed` flag would compile, pass, deploy, and only surface as an indexer quietly
///      reporting the wrong series.
///
///      `expectEmit(true, true, true, true)` checks all three topics and the data, so these
///      fail on any reordering rather than only on a missing event.
contract EventsTest is BaseTest {
    function test_createSeries_emitsWithSourceAndCollateral() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesCreated(
            1, p.observer, p.source, p.collateral, p.strike, p.startTime, p.expiry
        );
        market.createSeries(p);
    }

    function test_subscribe_emitsUnitsAndAmount() public {
        uint256 id = createDefaultSeries();
        uint256 units = 3e18;
        uint256 amount = _depositFor(units, market.collateralPerUnit(id, IVarianceMarket.Side.LONG));

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.Subscribed(id, IVarianceMarket.Side.LONG, alice, units, amount);
        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
    }

    function test_unsubscribe_emitsRefundedAmount() public {
        uint256 id = createDefaultSeries();
        uint256 units = 3e18;
        uint256 perUnit = market.collateralPerUnit(id, IVarianceMarket.Side.LONG);

        vm.startPrank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);

        // Withdrawals round down while deposits round up, so the amount in this event is not
        // simply the amount from the subscription. Asserting the exact figure pins that.
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.Unsubscribed(id, IVarianceMarket.Side.LONG, alice, units, _valueOf(units, perUnit));
        market.unsubscribe(id, IVarianceMarket.Side.LONG, units);
        vm.stopPrank();
    }

    function test_activate_emitsMatchedAndSnapshots() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 100e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 60e18);

        vm.warp(market.getSeries(id).startTime);

        // The snapshots are what distribution divides by; publishing them lets an indexer
        // recompute every fill without replaying the contract.
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesActivated(id, 60e18, 100e18, 60e18);
        market.activate(id);
    }

    function test_activate_emitsCancelledWhenOneSideEmpty() public {
        uint256 id = createDefaultSeries();
        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 5e18);

        vm.warp(market.getSeries(id).startTime);
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesCancelled(id);
        market.activate(id);
    }

    function test_mintPositions_emitsMintedAndRefunded() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 100e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 60e18);

        vm.warp(market.getSeries(id).startTime);
        market.activate(id);

        uint256 perUnit = market.collateralPerUnit(id, IVarianceMarket.Side.LONG);
        uint256 paid = _depositFor(100e18, perUnit);
        uint256 refund = paid * 40 / 100;

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.PositionsMinted(id, IVarianceMarket.Side.LONG, alice, 60e18, refund);
        market.mintPositions(id, IVarianceMarket.Side.LONG, alice);
    }

    function test_net_emitsReleasedCollateral() public {
        uint256 id = openMatchedSeries(4e18);
        uint256 longId = market.tokenId(id, IVarianceMarket.Side.LONG);
        uint256 shortId = market.tokenId(id, IVarianceMarket.Side.SHORT);

        vm.prank(alice);
        market.transfer(carol, longId, 4e18);
        vm.prank(bob);
        market.transfer(carol, shortId, 4e18);

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.Netted(id, carol, 4e18, totalDeposited(id, 4e18));
        vm.prank(carol);
        market.net(id, 4e18);
    }

    function test_settle_emitsRealizedVarianceAndCaller() public {
        uint256 id = openMatchedSeries(2e18);
        fillPoolSawtooth(id, 1 hours, 40);

        // The variance is not known before the call, so it is read from a static call first —
        // asserting the event carries the same number the state ends up with.
        uint256 snapshot = vm.snapshotState();
        market.settle(id);
        Variance rv = market.getSeries(id).realizedVariance;
        vm.revertToState(snapshot);

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesSettled(id, rv, address(this));
        market.settle(id);
    }

    function test_settle_emitsVoidedWithReason() public {
        uint256 id = openMatchedSeries(2e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime + 1 hours);
        pool.writeObservation(uint32(s.startTime + 1 hours), START_TICK + 500);
        vm.warp(s.expiry);

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesVoided(id, IVarianceMarket.VoidReason.SPARSE_SERIES);
        market.settle(id);
    }

    function test_settle_emitsVoidedWhenSourceReverts() public {
        uint256 id = openMatchedSeries(2e18);
        fillPoolSawtooth(id, 1 hours, 40);
        pool.setReverting(true);

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.SeriesVoided(id, IVarianceMarket.VoidReason.SOURCE_REVERTED);
        market.settle(id);
    }

    function test_redeem_emitsRecipientSeparatelyFromHolder() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        uint256 payout = _valueOf(3e18, market.payoutPerUnit(id, IVarianceMarket.Side.LONG));

        // Holder and recipient differ on purpose: they are separate fields and an indexer that
        // confuses them would attribute the payment to the wrong account.
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.Redeemed(id, IVarianceMarket.Side.LONG, alice, carol, 3e18, payout);
        vm.prank(alice);
        market.redeem(id, IVarianceMarket.Side.LONG, 3e18, carol);
    }

    function test_guardian_emitsBothStepsOfTransfer() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.GuardianTransferStarted(guardian, alice);
        vm.prank(guardian);
        market.transferGuardian(alice);

        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.GuardianSet(alice);
        vm.prank(alice);
        market.acceptGuardian();
    }

    function test_guardian_emitsPauseChange() public {
        vm.expectEmit(true, true, true, true, address(market));
        emit IVarianceMarket.CreationPauseSet(true);
        vm.prank(guardian);
        market.setCreationPaused(true);
    }
}

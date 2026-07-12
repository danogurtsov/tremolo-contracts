// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice End-to-end: a series is created, subscribed, activated, measured, settled and paid.
/// @dev These are the tests that would fail if the protocol did not work at all, as opposed to
///      the unit tests, which fail when a specific rule is broken.
contract LifecycleTest is BaseTest {
    using VarianceMath for Variance;

    function test_fullLifecycle_volatileMarket_longWins() public {
        uint256 units = 10e18;
        uint256 id = openMatchedSeries(units);

        uint256 poolBalanceAfterOpen = usdc.balanceOf(address(market));
        assertEq(poolBalanceAfterOpen, totalDeposited(id, units), "pool != deposits");

        // A sawtooth of +-40 ticks every hour: a market that keeps moving without going
        // anywhere. Realized variance is high, the strike is not, so the long side wins.
        fillPoolSawtooth(id, 1 hours, 40);

        IVarianceMarket.State state = market.settle(id);
        assertEq(uint8(state), uint8(IVarianceMarket.State.SETTLED));

        IVarianceMarket.Series memory s = market.getSeries(id);
        assertGt(Variance.unwrap(s.realizedVariance), Variance.unwrap(STRIKE), "expected RV > K");

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.prank(alice);
        uint256 longPaid = market.redeem(id, IVarianceMarket.Side.LONG, units, alice);
        vm.prank(bob);
        uint256 shortPaid = market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);

        assertEq(usdc.balanceOf(alice) - aliceBefore, longPaid);
        assertEq(usdc.balanceOf(bob) - bobBefore, shortPaid);

        // The identity the whole design rests on: payouts equal deposits, to the wei.
        assertEq(longPaid + shortPaid, poolBalanceAfterOpen, "payouts != deposits");
        assertEq(usdc.balanceOf(address(market)), 0, "collateral stranded");

        // Long profited, short lost, and neither can lose more than they put in.
        assertGt(longPaid, _valueOf(units, market.collateralPerUnit(id, IVarianceMarket.Side.LONG)));
    }

    function test_fullLifecycle_flatMarket_longLosesEverything() public {
        uint256 units = 5e18;
        uint256 id = openMatchedSeries(units);
        uint256 pot = usdc.balanceOf(address(market));

        fillPoolFlat(id, 1 hours);
        market.settle(id);

        IVarianceMarket.Series memory s = market.getSeries(id);
        assertEq(Variance.unwrap(s.realizedVariance), 0, "flat market must realise zero");

        vm.prank(alice);
        uint256 longPaid = market.redeem(id, IVarianceMarket.Side.LONG, units, alice);
        vm.prank(bob);
        uint256 shortPaid = market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);

        // RV = 0 is the long side's worst case: it loses its entire deposit and not a wei more.
        assertEq(longPaid, 0, "long should receive nothing at RV = 0");
        assertEq(shortPaid, pot, "short takes the whole pot");
    }

    /// @notice Realized variance far above the cap must not break solvency.
    /// @dev This is the scenario that liquidates people in a margined design. Here it is
    ///      simply the short side's maximum loss, which was posted up front.
    function test_extremeVariance_isCappedAndSolvent() public {
        uint256 units = 3e18;
        uint256 id = openMatchedSeries(units);
        uint256 pot = usdc.balanceOf(address(market));

        // +-4000 ticks per hour is roughly a 40% swing every hour, far beyond any cap.
        fillPoolSawtooth(id, 1 hours, 4000);
        market.settle(id);

        IVarianceMarket.Series memory s = market.getSeries(id);
        Variance ceiling = STRIKE.mulWad(CAP);
        assertGt(Variance.unwrap(s.realizedVariance), Variance.unwrap(ceiling), "setup: RV below cap");

        vm.prank(alice);
        uint256 longPaid = market.redeem(id, IVarianceMarket.Side.LONG, units, alice);
        vm.prank(bob);
        uint256 shortPaid = market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);

        assertEq(longPaid, pot, "capped long payout should be the whole pot");
        assertEq(shortPaid, 0, "short loses exactly its deposit");
        assertEq(longPaid + shortPaid, pot);
    }

    /// @notice A pool that stops trading yields a sparse window; the series must void, not lie.
    function test_sparseWindow_voidsAndRefunds() public {
        uint256 units = 4e18;
        uint256 id = openMatchedSeries(units);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        // Two observations across a 24-sample window: 8% completeness against an 80% floor.
        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime + 1 hours);
        pool.writeObservation(uint32(s.startTime + 1 hours), START_TICK + 500);
        vm.warp(s.expiry);
        pool.writeObservation(uint32(s.expiry), START_TICK);

        IVarianceMarket.State state = market.settle(id);
        assertEq(uint8(state), uint8(IVarianceMarket.State.VOIDED), "must void on sparse window");

        vm.prank(alice);
        market.redeem(id, IVarianceMarket.Side.LONG, units, alice);
        vm.prank(bob);
        market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);

        // Everyone gets exactly their deposit back — no gain, no loss, no judgement call.
        assertEq(
            usdc.balanceOf(alice),
            aliceBefore + _valueOf(units, market.collateralPerUnit(id, IVarianceMarket.Side.LONG))
        );
        assertEq(
            usdc.balanceOf(bob),
            bobBefore + _valueOf(units, market.collateralPerUnit(id, IVarianceMarket.Side.SHORT))
        );
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    /// @notice A source that reverts outright voids the series rather than freezing it.
    function test_revertingSource_voids() public {
        uint256 units = 2e18;
        uint256 id = openMatchedSeries(units);
        fillPoolSawtooth(id, 1 hours, 40);

        pool.setReverting(true);

        IVarianceMarket.State state = market.settle(id);
        assertEq(uint8(state), uint8(IVarianceMarket.State.VOIDED));
    }

    /// @notice Nobody takes the other side: the series cancels and everything is refundable.
    function test_unmatchedSeries_cancels() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 7e18);

        uint256 before = usdc.balanceOf(alice);
        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);

        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.CANCELLED));

        vm.prank(alice);
        market.unsubscribe(id, IVarianceMarket.Side.LONG, 7e18);
        assertEq(
            usdc.balanceOf(alice),
            before + _valueOf(7e18, market.collateralPerUnit(id, IVarianceMarket.Side.LONG))
        );
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    /// @notice Uneven subscription fills pro-rata and refunds the remainder.
    function test_partialFill_matchesMinimumAndRefundsExcess() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 100e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 60e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);

        assertEq(market.getSeries(id).matchedUnits, 60e18, "matched should be the minimum");

        uint256 aliceBefore = usdc.balanceOf(alice);
        (uint256 minted, uint256 refunded) = market.mintPositions(id, IVarianceMarket.Side.LONG, alice);

        assertEq(minted, 60e18, "long fills 60 of 100");
        assertEq(refunded, _valueOf(40e18, market.collateralPerUnit(id, IVarianceMarket.Side.LONG)));
        assertEq(usdc.balanceOf(alice), aliceBefore + refunded);
        assertEq(market.balanceOf(alice, market.tokenId(id, IVarianceMarket.Side.LONG)), 60e18);

        (uint256 shortMinted, uint256 shortRefund) = market.mintPositions(id, IVarianceMarket.Side.SHORT, bob);
        assertEq(shortMinted, 60e18, "short fills entirely");
        assertEq(shortRefund, 0);
    }

    /// @notice Netting both legs releases the full collateral and ends the exposure early.
    function test_netting_releasesCollateralBeforeExpiry() public {
        uint256 units = 8e18;
        uint256 id = openMatchedSeries(units);

        // Resolved before the pranks: an external call inside an argument would consume the
        // prank itself, and the transfer would then run as the test contract.
        uint256 longId = market.tokenId(id, IVarianceMarket.Side.LONG);
        uint256 shortId = market.tokenId(id, IVarianceMarket.Side.SHORT);

        // Carol buys the long leg from alice: this is what "exiting" looks like here.
        vm.prank(alice);
        market.transfer(carol, longId, units);
        vm.prank(bob);
        market.transfer(carol, shortId, units);

        uint256 before = usdc.balanceOf(carol);
        vm.prank(carol);
        uint256 released = market.net(id, units);

        assertEq(released, totalDeposited(id, units), "netting must release the full deposit");
        assertEq(usdc.balanceOf(carol), before + released);
        assertEq(usdc.balanceOf(address(market)), 0, "series fully unwound");
        assertEq(market.getSeries(id).matchedUnits, 0);

        // Nothing is left to settle against, but settlement must still be callable.
        vm.warp(market.getSeries(id).expiry);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.SETTLED));
    }
}

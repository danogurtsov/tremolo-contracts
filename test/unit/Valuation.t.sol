// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Reading a position part-way through a series.
/// @dev Until `accruedVariance` existed, a holder learned whether they were winning at
///      expiry and not before. Everything a portfolio view, a margin module or an exit quote
///      needs starts here.
contract ValuationTest is BaseTest {
    /// @dev Cadence matters and is easy to get wrong. The default series has a one-hour grid, so
    ///      a sawtooth oscillating every fifteen minutes averages to the same tick in every step
    ///      and accrues exactly zero variance — the TWAP cancellation measured in
    ///      docs/measurements/variance_bias.md, reproduced accidentally while writing these
    ///      tests. Movement has to happen between steps, not inside them.
    uint32 internal constant MOVE_CADENCE = 1 hours;

    /// @notice Before the window opens there is nothing to report, and it says so.
    function test_accrued_isZeroBeforeStart() public {
        uint256 id = openMatchedSeries(2e18);
        (Variance accrued, uint32 elapsed, uint16 steps) = market.accruedVariance(id);

        assertEq(Variance.unwrap(accrued), 0);
        assertEq(elapsed, 0);
        assertEq(steps, 0);
    }

    /// @notice Accrual only counts whole grid steps.
    /// @dev A partial step would annualise a fraction of an interval, and the figure would
    ///      wobble as the step filled in rather than moving only on new information.
    function test_accrued_countsWholeStepsOnly() public {
        uint256 id = openMatchedSeries(2e18);
        IVarianceMarket.Series memory s = market.getSeries(id);
        uint32 step = uint32(s.expiry - s.startTime) / s.samples; // 1 hour on the default series

        fillPoolSawtooth(id, MOVE_CADENCE, 40);

        // Half a step in: nothing complete, nothing reported.
        vm.warp(s.startTime + step / 2);
        (,, uint16 steps) = market.accruedVariance(id);
        assertEq(steps, 0, "a partial step should not count");

        // Five steps in: five reported.
        vm.warp(s.startTime + step * 5);
        (Variance accrued, uint32 elapsed, uint16 steps5) = market.accruedVariance(id);
        assertEq(steps5, 5);
        assertEq(elapsed, step * 5);
        assertGt(Variance.unwrap(accrued), 0, "a moving market should accrue variance");
    }

    /// @notice Accrued variance converges on the settled number as the window closes.
    /// @dev The additivity claim, checked rather than asserted: the same calculation over a
    ///      shorter window, extended to the full window, has to arrive at the same place.
    function test_accrued_convergesToSettled() public {
        uint256 id = openMatchedSeries(2e18);
        fillPoolSawtooth(id, MOVE_CADENCE, 40);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.expiry);
        (Variance atExpiry,,) = market.accruedVariance(id);

        market.settle(id);
        Variance settled = market.getSeries(id).realizedVariance;

        assertApproxEqRel(
            Variance.unwrap(atExpiry),
            Variance.unwrap(settled),
            0.02e18,
            "accrual at expiry should match what settlement computed"
        );
    }

    /// @notice Once settled, accrual reports the settled number itself.
    /// @dev Recomputing could disagree with what was actually paid out, and what was paid out
    ///      is the truth.
    function test_accrued_reportsSettledNumberAfterSettlement() public {
        uint256 id = openMatchedSeries(2e18);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        (Variance accrued, uint32 elapsed, uint16 steps) = market.accruedVariance(id);
        IVarianceMarket.Series memory s = market.getSeries(id);

        assertEq(Variance.unwrap(accrued), Variance.unwrap(s.realizedVariance));
        assertEq(elapsed, uint32(s.expiry - s.startTime));
        assertEq(steps, s.samples);
    }

    /// @notice A flat market accrues exactly nothing.
    function test_accrued_isZeroOnAFlatMarket() public {
        uint256 id = openMatchedSeries(2e18);
        IVarianceMarket.Series memory s = market.getSeries(id);
        fillPoolFlat(id, MOVE_CADENCE);

        vm.warp(s.startTime + 6 hours);
        (Variance accrued,,) = market.accruedVariance(id);
        assertEq(Variance.unwrap(accrued), 0);
    }

    // ---------------------------------------------------------------------
    // Mark to market
    // ---------------------------------------------------------------------

    /// @notice At the start, the mark is whatever the caller's implied view says.
    /// @dev Nothing has been realized yet, so expected variance is entirely the caller's
    ///      number.
    function test_mark_atStartIsPurelyImplied() public {
        uint256 id = openMatchedSeries(2e18);
        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);

        // Implied equal to the strike: the long leg is worth exactly what it deposited.
        uint256 atStrike = market.markToMarket(id, STRIKE, IVarianceMarket.Side.LONG);
        assertApproxEqRel(
            atStrike,
            market.collateralPerUnit(id, IVarianceMarket.Side.LONG),
            0.001e18,
            "at implied == strike the long leg should mark at its deposit"
        );
    }

    /// @notice A higher implied view marks the long leg up and the short leg down, together.
    function test_mark_movesWithImpliedAndAlwaysCloses() public {
        uint256 id = openMatchedSeries(2e18);
        vm.warp(market.getSeries(id).startTime);

        uint256 lowLong = market.markToMarket(id, Variance.wrap(0.02e18), IVarianceMarket.Side.LONG);
        uint256 highLong = market.markToMarket(id, Variance.wrap(0.08e18), IVarianceMarket.Side.LONG);
        assertGt(highLong, lowLong, "long should mark higher on a higher implied view");

        uint256 highShort = market.markToMarket(id, Variance.wrap(0.08e18), IVarianceMarket.Side.SHORT);
        assertEq(
            highLong + highShort,
            market.totalCollateralPerUnit(id),
            "the two legs must always mark to the whole pot"
        );
    }

    /// @notice Realized variance already in the books pulls the mark, and implied matters less
    ///         as the window closes.
    /// @dev The time weighting, observed: the same implied view produces a different mark late
    ///      in the series than early, because most of the answer is already known.
    function test_mark_weightsRealizedAgainstRemaining() public {
        uint256 id = openMatchedSeries(2e18);
        IVarianceMarket.Series memory s = market.getSeries(id);
        fillPoolSawtooth(id, MOVE_CADENCE, 80); // realizing well above the 20% strike

        vm.warp(s.startTime + 2 hours);
        uint256 early = market.markToMarket(id, Variance.wrap(0.01e18), IVarianceMarket.Side.LONG);

        vm.warp(s.startTime + 20 hours);
        uint256 late = market.markToMarket(id, Variance.wrap(0.01e18), IVarianceMarket.Side.LONG);

        // Same pessimistic implied view both times; late in the series the realized part
        // dominates it, so the long leg marks higher.
        assertGt(late, early, "realized variance should crowd out the implied view over time");
    }

    /// @notice After settlement the mark is the payout, not a projection.
    function test_mark_afterSettlementIsThePayout() public {
        uint256 id = openMatchedSeries(2e18);
        fillPoolSawtooth(id, 1 hours, 40);
        market.settle(id);

        assertEq(
            market.markToMarket(id, Variance.wrap(999e18), IVarianceMarket.Side.LONG),
            market.payoutPerUnit(id, IVarianceMarket.Side.LONG),
            "a settled series ignores any implied view"
        );
    }

    // ---------------------------------------------------------------------
    // Settlement without a keeper
    // ---------------------------------------------------------------------

    /// @notice Redeeming an expired-but-unsettled series settles it on the way through.
    /// @dev Nothing pays anyone to call `settle`, and nothing needs to: whoever is owed money
    ///      has every reason to spend the gas. A reward would have to come out of the pot,
    ///      breaking the identity the design rests on, or out of a fund somebody has to fill.
    function test_redeem_settlesLazilyWhenNobodyDid() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, MOVE_CADENCE, 40);

        // Expired, and nobody called settle.
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.ACTIVE));

        vm.prank(alice);
        uint256 paid = market.redeem(id, IVarianceMarket.Side.LONG, 3e18, alice);

        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.SETTLED));
        assertGt(paid, 0, "long realized above strike and should have been paid");
    }

    /// @notice The lazy path produces the same number as calling settle first.
    function test_redeem_lazySettlementMatchesExplicit() public {
        uint256 idA = openMatchedSeries(3e18);
        fillPoolSawtooth(idA, MOVE_CADENCE, 40);

        uint256 snapshot = vm.snapshotState();
        market.settle(idA);
        uint256 explicitPayout = market.payoutPerUnit(idA, IVarianceMarket.Side.LONG);
        vm.revertToState(snapshot);

        vm.prank(alice);
        market.redeem(idA, IVarianceMarket.Side.LONG, 1e18, alice);

        assertEq(
            market.payoutPerUnit(idA, IVarianceMarket.Side.LONG),
            explicitPayout,
            "settling lazily gave a different number than settling explicitly"
        );
    }

    /// @notice Redeeming before expiry still reverts; laziness is not permissiveness.
    function test_redeem_stillRejectsBeforeExpiry() public {
        uint256 id = openMatchedSeries(3e18);
        vm.warp(market.getSeries(id).startTime + 1 hours);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IVarianceMarket.WrongState.selector, IVarianceMarket.State.ACTIVE)
        );
        market.redeem(id, IVarianceMarket.Side.LONG, 1e18, alice);
    }

    /// @notice A series whose source died settles lazily to VOIDED and refunds.
    function test_redeem_lazyPathVoidsABrokenSource() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, MOVE_CADENCE, 40);
        pool.setReverting(true);

        vm.prank(alice);
        uint256 paid = market.redeem(id, IVarianceMarket.Side.LONG, 3e18, alice);

        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.VOIDED));
        assertEq(paid, _valueOf(3e18, market.collateralPerUnit(id, IVarianceMarket.Side.LONG)));
    }
}

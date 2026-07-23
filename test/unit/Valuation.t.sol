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
        (, , uint16 steps) = market.accruedVariance(id);
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
            Variance.unwrap(atExpiry), Variance.unwrap(settled), 0.02e18,
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
    /// @dev Nothing has been realized yet, so expected variance is entirely the caller's number
    ///      — which is the honest answer, and is why the number is an argument.
    function test_mark_atStartIsPurelyImplied() public {
        uint256 id = openMatchedSeries(2e18);
        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);

        // Implied equal to the strike: the long leg is worth exactly what it deposited.
        uint256 atStrike = market.markToMarket(id, STRIKE, IVarianceMarket.Side.LONG);
        assertApproxEqRel(
            atStrike, market.collateralPerUnit(id, IVarianceMarket.Side.LONG), 0.001e18,
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
            highLong + highShort, market.totalCollateralPerUnit(id),
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
}

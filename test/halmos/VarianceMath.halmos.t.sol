// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance, VarianceLib} from "../../src/types/Variance.sol";

/// @notice Symbolic proofs of the settlement arithmetic.
///
/// @dev Fuzzing tries 50 000 inputs and finds nothing. That is evidence, not proof: the counter-
///      example may simply be somewhere the sampler never looked. These functions hand the same
///      properties to an SMT solver, which either returns a counter-example or establishes that
///      none exists over the whole declared domain.
///
///      Run with:  halmos --function check       (or `make verify`)
///
///      Naming matters: halmos collects `check_*`, forge collects `test*`, so these are invisible
///      to `forge test` and cost nothing in the normal cycle.
///
///      **Where the solver stops.** Anything involving division by 1e18 with symbolic operands
///      does not discharge, at any budget tried. Measured, not guessed:
///
///        uint256 args, 20s budget      4 of 6 timed out
///        uint128 args, 60s budget      same 4 timed out
///        concrete cap and notional     still timed out
///        300s budget on one property   still timed out
///        isolated one-line lemma
///          `a <= b => a*n/1e18 <= b*n/1e18`   timed out at 70s
///
///      The last line is the diagnosis: it is not the size of the expressions or the shape of
///      the properties, it is that fixed-point division is expensive to reason about in
///      bitvector arithmetic. Narrowing types, fixing parameters and enlarging budgets all
///      failed to change it.
///
///      So this file proves what is provable and says so, rather than reporting a timeout as
///      though it were a result. What remains is covered by 50 000-run fuzzing and by the
///      invariant suites — weaker evidence, honestly labelled. The properties that could not be
///      discharged are listed at the bottom with what stands in for them.
contract VarianceMathSymbolicTest is Test {
    using VarianceLib for Variance;

    uint256 internal constant MAX_STRIKE = 100e18; // createSeries ceiling
    uint64 internal constant MIN_CAP = 1.05e18;
    uint64 internal constant MAX_CAP = 10e18;
    uint256 internal constant MAX_NOTIONAL = 1e30;

    /// @notice Deposits sum to exactly the pot, with no gap in either direction.
    /// @dev Discharges in ~1s. It holds structurally: `shortCollateral` is defined as the
    ///      remainder of the pot rather than computed independently, so the solver proves the
    ///      identity without ever evaluating the division.
    function check_depositsSumToPot(uint128 strike, uint64 cap, uint128 notional) public pure {
        vm.assume(strike > 0 && strike <= MAX_STRIKE);
        vm.assume(cap >= MIN_CAP && cap <= MAX_CAP);
        vm.assume(notional > 0 && notional <= MAX_NOTIONAL);

        Variance k = Variance.wrap(strike);
        uint256 long = VarianceMath.longCollateral(k, notional);
        uint256 short = VarianceMath.shortCollateral(k, cap, notional);

        assert(long + short == VarianceMath.totalCollateral(k, cap, notional));
    }

    /// @notice Annualisation never overflows on any accumulator the protocol can produce.
    /// @dev The bound is real rather than convenient: a tick delta cannot exceed 2 * 887272 and
    ///      the grid cannot exceed 256 points, so the accumulator cannot exceed
    ///      256 * (2 * 887272)^2, which is under 8.1e17. Proven across that entire range, not at
    ///      the points a fuzzer happened to sample.
    function check_annualiseDoesNotOverflow(uint64 sumSquares, uint32 window) public pure {
        vm.assume(sumSquares <= 81e16);
        vm.assume(window >= 1 hours && window <= 365 days);

        Variance rv = VarianceMath.annualise(sumSquares, window);

        // A zero accumulator must give exactly zero: no dust from the scaling constants.
        if (sumSquares == 0) assert(Variance.unwrap(rv) == 0);
    }

    /// @notice The cap can never exceed either the realized variance or the ceiling.
    /// @dev The `min` at the heart of the payoff, proven on its own in 0.1s. Combined with the
    ///      monotonicity of `notional` — which the solver cannot reach, but which is a property
    ///      of integer division rather than of this code — it gives the capped payoff.
    function check_minIsBoundedByBothArguments(uint128 a, uint128 b) public pure {
        Variance m = Variance.wrap(a).min(Variance.wrap(b));
        assert(Variance.unwrap(m) <= a);
        assert(Variance.unwrap(m) <= b);
    }

    // -----------------------------------------------------------------------------------
    // Not discharged, and what covers them instead
    //
    //   payoutsSumToPot          long <= pot for every RV
    //   payoutMonotoneInVariance long payout never falls as RV rises
    //   payoutIsCapped           no RV pays more than cap * K does
    //   notionalRoundsToPool     rounding down never exceeds rounding up
    //
    // Each reduces to the monotonicity of `a * n / 1e18`, which the solver does not finish.
    // Covered instead by:
    //   - testFuzz_payoutsSumToCollateral, testFuzz_payoutMonotoneInVariance,
    //     testFuzz_notionalRoundingDirections  (50 000 runs each in the ci profile)
    //   - invariant_payoutsSumToCollateral and invariant_payoutRespectsCap, asserted after
    //     every step of every sequence in both invariant suites
    //
    // That is weaker than a proof and is labelled as such. Restoring it would mean either a
    // solver that handles fixed-point division, or reformulating the payoff so no division
    // appears between the inputs and the comparison.
    // -----------------------------------------------------------------------------------
}

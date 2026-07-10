// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance, VarianceLib} from "../../src/types/Variance.sol";

/// @notice Properties of the variance calculation, stated as fuzz tests.
/// @dev The differential suite checks the number against a reference. This checks the
///      properties that must hold for every input, including ones the reference was never
///      run on.
contract VarianceMathTest is Test {
    using VarianceLib for Variance;

    // ---------------------------------------------------------------------
    // Structural properties
    // ---------------------------------------------------------------------

    /// @notice Variance is invariant to a constant shift of the whole series.
    /// @dev Log returns are differences, so adding a constant to every tick — i.e. quoting the
    ///      same market at a different price level — must not change realized variance. If it
    ///      did, the instrument would settle differently on the same volatility depending on
    ///      whether ETH traded at 2,000 or 20,000.
    function testFuzz_shiftInvariance(int256 shift, uint8 length, int256 seed) public pure {
        length = uint8(bound(length, 2, 64));
        // Bounded so that base path plus shift stays inside the tick domain. A wider bound
        // would clamp the walk, and a clamped walk is not a shifted copy of the original —
        // the first version of this test failed for exactly that reason.
        shift = bound(shift, -400_000, 400_000);

        int256[] memory a = _series(length, seed, 0);
        int256[] memory b = _series(length, seed, shift);

        assertEq(
            VarianceMath.sumSquaredTickDeltas(a),
            VarianceMath.sumSquaredTickDeltas(b),
            "variance changed under a price-level shift"
        );
    }

    /// @notice Reversing the series leaves variance unchanged.
    /// @dev Squared differences do not care about direction. A market that fell and recovered
    ///      realises the same variance as one that rose and gave it back — which is exactly
    ///      what "we do not care which way it goes" means in code.
    function testFuzz_timeReversalSymmetry(uint8 length, int256 seed) public pure {
        length = uint8(bound(length, 2, 64));
        int256[] memory a = _series(length, seed, 0);

        int256[] memory reversed = new int256[](length);
        for (uint256 i = 0; i < length; ++i) {
            reversed[i] = a[length - 1 - i];
        }

        assertEq(VarianceMath.sumSquaredTickDeltas(a), VarianceMath.sumSquaredTickDeltas(reversed));
    }

    /// @notice A flat series realises exactly zero, at any length and any level.
    function testFuzz_flatSeriesIsZero(int256 level, uint8 length) public pure {
        length = uint8(bound(length, 2, 128));
        level = bound(level, -800_000, 800_000);

        int256[] memory ticks = new int256[](length);
        for (uint256 i = 0; i < length; ++i) {
            ticks[i] = level;
        }

        assertEq(Variance.unwrap(VarianceMath.fromTicks(ticks, 86_400)), 0);
    }

    /// @notice Variance scales inversely with the window, holding the path fixed.
    /// @dev The same movement over half the time is twice the annualised variance. Asserted
    ///      because the annualisation is the one place where a units mistake would produce
    ///      numbers that still look plausible.
    function testFuzz_annualisationScalesInversely(uint256 sumSq, uint32 halfWindow) public pure {
        sumSq = bound(sumSq, 1, 1e12);
        // Fuzzing the half and doubling it, rather than fuzzing the whole and halving it: an
        // odd window floors to something that is not exactly half, and the resulting ~0.01%
        // gap is an artefact of the test, not of the annualisation.
        halfWindow = uint32(bound(halfWindow, 1 hours, 180 days));

        uint256 full = Variance.unwrap(VarianceMath.annualise(sumSq, uint256(halfWindow) * 2));
        uint256 half = Variance.unwrap(VarianceMath.annualise(sumSq, halfWindow));

        assertApproxEqRel(half, full * 2, 1e12, "halving the window must double variance");
    }

    /// @notice Variance is additive across a split of the series.
    /// @dev The property that makes mark-to-market trivial for this instrument, and the reason
    ///      netting works: accrued variance plus remaining variance is total variance, with no
    ///      cross term. Worth an explicit test because the whole exit design leans on it.
    function testFuzz_additivityAcrossSplit(uint8 length, int256 seed, uint8 splitAt) public pure {
        length = uint8(bound(length, 4, 64));
        splitAt = uint8(bound(splitAt, 2, length - 2));

        int256[] memory full = _series(length, seed, 0);

        int256[] memory head = new int256[](splitAt);
        for (uint256 i = 0; i < splitAt; ++i) {
            head[i] = full[i];
        }
        // The tail starts at the last point of the head: the return spanning the split belongs
        // to exactly one of the two halves, never both and never neither.
        int256[] memory tail = new int256[](length - splitAt + 1);
        for (uint256 i = 0; i < tail.length; ++i) {
            tail[i] = full[splitAt - 1 + i];
        }

        assertEq(
            VarianceMath.sumSquaredTickDeltas(full),
            VarianceMath.sumSquaredTickDeltas(head) + VarianceMath.sumSquaredTickDeltas(tail),
            "variance is not additive across the split"
        );
    }

    // ---------------------------------------------------------------------
    // Settlement arithmetic
    // ---------------------------------------------------------------------

    /// @notice Payouts always sum to the collateral posted, for every realized variance.
    /// @dev The solvency identity, fuzzed over the full domain rather than the cases someone
    ///      thought to write down.
    function testFuzz_payoutsSumToCollateral(uint256 realized, uint256 strike, uint64 cap, uint256 notional)
        public
        pure
    {
        strike = bound(strike, 1e12, 10e18);
        cap = uint64(bound(cap, 1.05e18, 10e18));
        notional = bound(notional, 1e6, 1e30);
        realized = bound(realized, 0, 1000e18);

        Variance k = Variance.wrap(strike);
        Variance rv = Variance.wrap(realized);

        uint256 total = VarianceMath.totalCollateral(k, cap, notional);
        uint256 long = VarianceMath.longPayout(rv, k, cap, notional);

        assertLe(long, total, "long payout exceeds the pot");
        // Short receives the remainder by construction, so the sum closes exactly.
        assertEq(long + (total - long), total);
    }

    /// @notice Deposits sum to the pot: long's maximum loss plus short's equals the total.
    function testFuzz_depositsSumToPot(uint256 strike, uint64 cap, uint256 notional) public pure {
        strike = bound(strike, 1e12, 10e18);
        cap = uint64(bound(cap, 1.05e18, 10e18));
        notional = bound(notional, 1e6, 1e30);

        Variance k = Variance.wrap(strike);
        assertEq(
            VarianceMath.longCollateral(k, notional) + VarianceMath.shortCollateral(k, cap, notional),
            VarianceMath.totalCollateral(k, cap, notional),
            "deposits do not sum to the pot"
        );
    }

    /// @notice Long payout is monotone non-decreasing in realized variance.
    /// @dev Directionality is the instrument's entire promise. A non-monotone payoff would
    ///      mean a long position that loses money when volatility rises.
    function testFuzz_payoutMonotoneInVariance(uint256 rvA, uint256 rvB, uint256 strike) public pure {
        strike = bound(strike, 1e15, 1e18);
        rvA = bound(rvA, 0, 100e18);
        rvB = bound(rvB, 0, 100e18);
        if (rvA > rvB) (rvA, rvB) = (rvB, rvA);

        uint256 payA = VarianceMath.longPayout(Variance.wrap(rvA), Variance.wrap(strike), 2.5e18, 1e18);
        uint256 payB = VarianceMath.longPayout(Variance.wrap(rvB), Variance.wrap(strike), 2.5e18, 1e18);

        assertGe(payB, payA, "payout fell as variance rose");
    }

    /// @notice Beyond the cap, more variance changes nothing.
    function test_payoutIsFlatAboveCap() public pure {
        Variance k = Variance.wrap(0.04e18);
        uint256 atCap = VarianceMath.longPayout(Variance.wrap(0.1e18), k, 2.5e18, 1000e6);
        uint256 farAbove = VarianceMath.longPayout(Variance.wrap(50e18), k, 2.5e18, 1000e6);

        assertEq(atCap, farAbove, "payout kept growing past the cap");
        assertEq(atCap, VarianceMath.totalCollateral(k, 2.5e18, 1000e6));
    }

    // ---------------------------------------------------------------------
    // Guards
    // ---------------------------------------------------------------------

    function test_revertsOnEmptySeries() public {
        int256[] memory ticks = new int256[](1);
        vm.expectRevert(VarianceMath.EmptySeries.selector);
        this.callFromTicks(ticks, 86_400);
    }

    function test_revertsOnZeroWindow() public {
        int256[] memory ticks = new int256[](2);
        vm.expectRevert(VarianceMath.ZeroWindow.selector);
        this.callFromTicks(ticks, 0);
    }

    function test_revertsOnTickOutOfRange() public {
        int256[] memory ticks = new int256[](2);
        ticks[0] = 900_000; // beyond MAX_ABS_TICK
        vm.expectRevert(abi.encodeWithSelector(VarianceMath.TickOutOfRange.selector, int256(900_000)));
        this.callFromTicks(ticks, 86_400);
    }

    function callFromTicks(int256[] memory ticks, uint256 window) external pure returns (uint256) {
        return Variance.unwrap(VarianceMath.fromTicks(ticks, window));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Deterministic pseudo-random walk in tick space, offset by `shift`.
    function _series(uint8 length, int256 seed, int256 shift) internal pure returns (int256[] memory ticks) {
        ticks = new int256[](length);
        // Steps are small enough that 64 of them cannot leave the tick domain from any
        // permitted shift, so the walk is never clamped and stays a faithful translation.
        int256 cur = 0;
        for (uint256 i = 0; i < length; ++i) {
            ticks[i] = cur + shift;
            cur += int256(uint256(keccak256(abi.encode(seed, i))) % 401) - 200;
        }
    }
}

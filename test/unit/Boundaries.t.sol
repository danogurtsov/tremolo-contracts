// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {Variance, VarianceLib} from "../../src/types/Variance.sol";

/// @notice The exact edges of every accepted range.
///
/// @dev Written in response to mutation testing, which is better at finding these than reading
///      is. Two mutants survived the existing suite:
///
///        `n < 2`                   ->  `n <= 2`   in fromPrices
///        `prev > MAX_ABS_TICK`     ->  `prev >= MAX_ABS_TICK`
///
///      Both are the classic off-by-one at a boundary, and both survived because every test
///      used comfortable inputs — two-point series went through the tick path, and no test ever
///      passed a tick sitting exactly on the limit. A boundary that is never tested at the
///      boundary is a boundary nobody has checked.
contract BoundariesTest is Test {
    using VarianceLib for Variance;

    /// @dev Foundry starts the clock at 1, so any fixture that needs a pool with history behind
    ///      it must move it first, or `block.timestamp - 2 days` underflows.
    function setUp() public {
        vm.warp(1_800_000_000);
    }

    // ---------------------------------------------------------------------
    // Series length
    // ---------------------------------------------------------------------

    /// @notice Exactly two prices is the shortest legal series, and it must work.
    /// @dev Killed mutant: `n < 2` -> `n <= 2` in fromPrices.
    function test_fromPrices_acceptsExactlyTwoPoints() public pure {
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1e18;
        prices[1] = 1.01e18;

        Variance rv = VarianceMath.fromPrices(prices, 1 hours);
        assertGt(Variance.unwrap(rv), 0, "a 1% move must produce non-zero variance");
    }

    function test_fromPrices_rejectsOnePoint() public {
        uint256[] memory prices = new uint256[](1);
        prices[0] = 1e18;
        vm.expectRevert(VarianceMath.EmptySeries.selector);
        this.callFromPrices(prices, 1 hours);
    }

    function test_fromPrices_rejectsZeroWindow() public {
        uint256[] memory prices = new uint256[](2);
        prices[0] = 1e18;
        prices[1] = 1.01e18;
        vm.expectRevert(VarianceMath.ZeroWindow.selector);
        this.callFromPrices(prices, 0);
    }

    /// @notice A flat price series is exactly zero, not dust from the logarithm.
    function test_fromPrices_flatSeriesIsExactlyZero() public pure {
        uint256[] memory prices = new uint256[](8);
        for (uint256 i = 0; i < 8; ++i) {
            prices[i] = 2_500e18;
        }
        assertEq(Variance.unwrap(VarianceMath.fromPrices(prices, 1 days)), 0);
    }

    /// @notice Exactly two ticks is the shortest legal tick series.
    function test_fromTicks_acceptsExactlyTwoPoints() public pure {
        int256[] memory ticks = new int256[](2);
        ticks[0] = 200_000;
        ticks[1] = 200_100;
        assertGt(Variance.unwrap(VarianceMath.fromTicks(ticks, 1 hours)), 0);
    }

    // ---------------------------------------------------------------------
    // Tick domain
    // ---------------------------------------------------------------------

    /// @notice A tick sitting exactly on Uniswap's limit is legal.
    /// @dev Killed mutant: `prev > MAX_ABS_TICK` -> `prev >= MAX_ABS_TICK`. Uniswap can and does
    ///      represent +-887272, so rejecting it would refuse a price the source can quote.
    function test_fromTicks_acceptsTicksExactlyAtTheLimit() public pure {
        int256[] memory ticks = new int256[](3);
        ticks[0] = 887_272;
        ticks[1] = -887_272;
        ticks[2] = 887_272;

        assertGt(VarianceMath.sumSquaredTickDeltas(ticks), 0);
    }

    function test_fromTicks_rejectsFirstTickAboveLimit() public {
        int256[] memory ticks = new int256[](2);
        ticks[0] = 887_273;
        ticks[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(VarianceMath.TickOutOfRange.selector, int256(887_273)));
        this.callSum(ticks);
    }

    function test_fromTicks_rejectsFirstTickBelowLimit() public {
        int256[] memory ticks = new int256[](2);
        ticks[0] = -887_273;
        ticks[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(VarianceMath.TickOutOfRange.selector, int256(-887_273)));
        this.callSum(ticks);
    }

    /// @notice A later tick out of range is caught too, not just the first.
    function test_fromTicks_rejectsLaterTickOutOfRange() public {
        int256[] memory ticks = new int256[](3);
        ticks[0] = 0;
        ticks[1] = 100;
        ticks[2] = 887_273;
        vm.expectRevert(abi.encodeWithSelector(VarianceMath.TickOutOfRange.selector, int256(887_273)));
        this.callSum(ticks);
    }

    // ---------------------------------------------------------------------
    // Variance type
    // ---------------------------------------------------------------------

    /// @notice The operators on the Variance type behave like the arithmetic they replace.
    /// @dev The type exists to stop variance and volatility being interchanged. Its operators
    ///      were written and never exercised, which is how a user-defined type quietly becomes
    ///      a place for a mistake to hide.
    function testFuzz_varianceOperators(uint128 a, uint128 b) public pure {
        Variance x = Variance.wrap(a);
        Variance y = Variance.wrap(b);

        assertEq(Variance.unwrap(x + y), uint256(a) + uint256(b));
        assertEq(x < y, a < b);
        assertEq(x > y, a > b);
        assertEq(x <= y, a <= b);
        assertEq(x >= y, a >= b);
        assertEq(x == y, a == b);
        assertEq(x != y, a != b);
        assertEq(Variance.unwrap(x.min(y)), a < b ? a : b);
        assertEq(x.isZero(), a == 0);
        assertEq(x.raw(), a);

        if (a >= b) assertEq(Variance.unwrap(x - y), uint256(a) - uint256(b));
    }

    /// @notice `notionalUp` rounds up and `notional` rounds down, and they differ by at most one.
    function testFuzz_notionalRoundingDirections(uint128 varianceRaw, uint128 notional) public pure {
        Variance v = Variance.wrap(varianceRaw);
        uint256 down = v.notional(notional);
        uint256 up = v.notionalUp(notional);

        assertLe(down, up, "rounding up produced less than rounding down");
        assertLe(up - down, 1, "rounding directions differ by more than one wei");
        if (uint256(varianceRaw) * uint256(notional) % 1e18 == 0) {
            assertEq(down, up, "exact products must not be rounded at all");
        }
    }

    function testFuzz_mulWadScalesLinearly(uint96 varianceRaw, uint64 multiplier) public pure {
        Variance v = Variance.wrap(varianceRaw);
        assertEq(Variance.unwrap(v.mulWad(multiplier)), uint256(varianceRaw) * multiplier / 1e18);
    }

    // ---------------------------------------------------------------------
    // Observer guards
    // ---------------------------------------------------------------------

    function test_observer_rejectsFutureWindow() public {
        UniV3Observer obs = new UniV3Observer();
        MockUniV3Pool pool = new MockUniV3Pool(200_000, 64, uint32(block.timestamp - 2 days));

        vm.expectRevert(UniV3Observer.FutureWindow.selector);
        obs.sampleTicks(address(pool), uint32(block.timestamp + 1), 1 hours, 12);
    }

    function test_observer_rejectsZeroWindow() public {
        UniV3Observer obs = new UniV3Observer();
        MockUniV3Pool pool = new MockUniV3Pool(200_000, 64, uint32(block.timestamp - 2 days));

        vm.expectRevert(abi.encodeWithSelector(UniV3Observer.WindowTooLong.selector, uint32(0)));
        obs.sampleTicks(address(pool), uint32(block.timestamp), 0, 12);
    }

    function test_observer_rejectsWindowOverAYear() public {
        UniV3Observer obs = new UniV3Observer();
        MockUniV3Pool pool = new MockUniV3Pool(200_000, 64, uint32(block.timestamp - 2 days));

        uint32 tooLong = uint32(366 days);
        vm.expectRevert(abi.encodeWithSelector(UniV3Observer.WindowTooLong.selector, tooLong));
        obs.sampleTicks(address(pool), uint32(block.timestamp), tooLong, 12);
    }

    /// @notice Exactly MAX_SAMPLES is accepted; one more is not.
    function test_observer_sampleCeilingIsInclusive() public {
        UniV3Observer obs = new UniV3Observer();
        uint16 max = obs.MAX_SAMPLES();

        MockUniV3Pool pool = new MockUniV3Pool(200_000, max, uint32(block.timestamp - 2 days));
        pool.writeObservation(uint32(block.timestamp - 1 hours), 200_050);

        obs.validateSource(address(pool), 1 hours, max);

        vm.expectRevert(abi.encodeWithSelector(UniV3Observer.TooFewSamples.selector, max + 1));
        obs.validateSource(address(pool), 1 hours, max + 1);
    }

    /// @notice A buffer that has not wrapped yet reports its age from entry zero.
    /// @dev The `!initialized` branch in `maxLookback`, reachable only on a fresh pool — which
    ///      is exactly the pool someone would create a first series against.
    function test_observer_handlesUnwrappedBuffer() public {
        uint32 birth = uint32(block.timestamp - 3 hours);
        MockUniV3Pool pool = new MockUniV3Pool(200_000, 128, birth);
        UniV3Observer obs = new UniV3Observer();

        assertEq(obs.maxLookback(address(pool)), uint32(block.timestamp) - birth);
    }

    // ---------------------------------------------------------------------

    function callFromPrices(uint256[] memory p, uint256 w) external pure returns (uint256) {
        return Variance.unwrap(VarianceMath.fromPrices(p, w));
    }

    function callSum(int256[] memory t) external pure returns (uint256) {
        return VarianceMath.sumSquaredTickDeltas(t);
    }
}

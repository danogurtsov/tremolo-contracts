// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Differential test: Solidity against the 60-digit Python reference.
///
/// @dev This is the test that decides whether the protocol computes the right number at all.
///      Unit tests check that the code does what it was written to do; this checks that what
///      it was written to do is arithmetic.
///
///      Fixtures come from `reference/variance_reference.py`, which regenerates
///      `test/fixtures/variance_cases.json`. If the two ever disagree, the reference is right.
contract VarianceMathDiffTest is Test {
    using stdJson for string;

    struct Case {
        string name;
        int256[] ticks;
        uint256 windowSeconds;
        uint256 sumSquaredDeltas;
        uint256 expectedVarianceWad;
    }

    Case[] internal cases;

    function setUp() public {
        string memory raw = vm.readFile("test/fixtures/variance_cases.json");
        uint256 count = raw.readUint(".count");

        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat(".cases[", vm.toString(i), "]");
            cases.push(
                Case({
                    name: raw.readString(string.concat(base, ".name")),
                    ticks: raw.readIntArray(string.concat(base, ".ticks")),
                    windowSeconds: raw.readUint(string.concat(base, ".windowSeconds")),
                    sumSquaredDeltas: raw.readUint(string.concat(base, ".sumSquaredDeltas")),
                    expectedVarianceWad: raw.readUint(string.concat(base, ".expectedVarianceWad"))
                })
            );
        }
        assertGt(cases.length, 0, "no fixtures loaded");
    }

    /// @notice The sum of squared tick deltas must match the reference exactly.
    /// @dev No tolerance here on purpose: this step is integer arithmetic on both sides, so
    ///      any discrepancy is a bug, not rounding.
    function test_sumSquaredTickDeltas_matchesReferenceExactly() public view {
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            assertEq(
                VarianceMath.sumSquaredTickDeltas(c.ticks),
                c.sumSquaredDeltas,
                string.concat("sum mismatch: ", c.name)
            );
        }
    }

    /// @notice Annualised variance must match to within one wei of WAD.
    /// @dev One unit of slack is the floor of a single division; anything larger would mean
    ///      the on-chain path is losing precision somewhere it should not be.
    function test_fromTicks_matchesReferenceWithinOneWei() public view {
        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            uint256 got = Variance.unwrap(VarianceMath.fromTicks(c.ticks, c.windowSeconds));

            assertApproxEqAbs(got, c.expectedVarianceWad, 1, string.concat("variance mismatch: ", c.name));
        }
    }

    /// @notice A flat series must produce exactly zero, not dust.
    /// @dev Worth its own assertion: a protocol that reports 0.0000001% volatility for a
    ///      market that did not move is one that pays the long side for nothing happening.
    function test_flatSeries_isExactlyZero() public view {
        for (uint256 i = 0; i < cases.length; ++i) {
            if (keccak256(bytes(cases[i].name)) != keccak256("flat")) continue;
            assertEq(Variance.unwrap(VarianceMath.fromTicks(cases[i].ticks, cases[i].windowSeconds)), 0);
            return;
        }
        revert("flat case missing from fixtures");
    }

    /// @notice The price path and the tick path must agree for the same series.
    /// @dev They cannot agree exactly — `fromPrices` calls `lnWad`, `fromTicks` does not —
    ///      so this measures how much accuracy is lost by using a price source instead of a
    ///      tick source. The bound is the empirical answer to "how much worse is a push
    ///      oracle", and it is why tick sources are preferred rather than merely convenient.
    function test_pricePath_agreesWithTickPath_withinBound() public pure {
        // 1.0001^tick around tick 0, so prices stay near 1e18 where lnWad is most accurate.
        int256[] memory ticks = new int256[](5);
        ticks[0] = 0;
        ticks[1] = 100;
        ticks[2] = -50;
        ticks[3] = 250;
        ticks[4] = 0;

        uint256[] memory prices = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            prices[i] = _tickToPriceWad(ticks[i]);
        }

        uint256 fromTicks = Variance.unwrap(VarianceMath.fromTicks(ticks, 86_400));
        uint256 fromPrices = Variance.unwrap(VarianceMath.fromPrices(prices, 86_400));

        // 0.5% of the tick-path result. Dominated by the WAD truncation of each squared
        // return, not by lnWad itself.
        uint256 tolerance = fromTicks / 200;
        assertApproxEqAbs(fromPrices, fromTicks, tolerance, "price path diverged from tick path");
    }

    /// @dev 1.0001^tick in WAD, computed here rather than imported so the test does not
    ///      depend on the same code it is checking.
    function _tickToPriceWad(int256 tick) internal pure returns (uint256) {
        uint256 price = 1e18;
        uint256 n = uint256(tick < 0 ? -tick : tick);
        for (uint256 i = 0; i < n; ++i) {
            price = tick < 0 ? price * 1e18 / 1.0001e18 : price * 1.0001e18 / 1e18;
        }
        return price;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Settlement refuses to run on too little gas, rather than voiding.
///
/// @dev Found on a local fork, not here — and the reason it was not found here is the point.
///      Every other test calls `settle` with effectively unlimited gas, so the failure never
///      appeared. On a real chain a wallet calls `eth_estimateGas` first, and the estimator
///      looks for the cheapest gas at which the transaction *succeeds*. Falling into the
///      try/catch and voiding the series counts as success, and costs about half of what
///      reading the series costs.
///
///      So every wallet would have handed `settle` exactly enough gas to guarantee a void: the
///      series refunds, and whoever was winning silently loses their payout. Nothing reverts,
///      nothing looks wrong, and the number that should have settled never does.
contract GasGuardTest is BaseTest {
    /// @notice Too little gas reverts, and does not quietly void.
    function test_settle_revertsRatherThanVoidingOnLowGas() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, 1 hours, 40);

        // Roughly what the estimator would have returned: enough for the catch, not the read.
        (bool ok,) = address(market).call{gas: 400_000}(abi.encodeCall(market.settle, (id)));

        assertFalse(ok, "settle accepted gas that could only have voided the series");
        assertEq(
            uint8(market.getSeries(id).state),
            uint8(IVarianceMarket.State.ACTIVE),
            "series must be untouched after a rejected settle"
        );
    }

    /// @notice With enough gas it settles normally.
    function test_settle_succeedsWithAdequateGas() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, 1 hours, 40);

        (bool ok,) = address(market).call{gas: 5_000_000}(abi.encodeCall(market.settle, (id)));

        assertTrue(ok, "settle failed with ample gas");
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.SETTLED));
    }

    /// @notice The requirement scales with the grid, since the grid is what costs.
    function testFuzz_gasRequirementTracksGridSize(uint16 samples) public {
        samples = uint16(bound(samples, 2, 200));

        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.samples = samples;
        // Grid step must stay above the floor and the window above its minimum, so the window
        // is the larger of the two constraints rather than a fixed multiple.
        uint256 window = uint256(samples) * 300;
        if (window < 1 hours) window = 1 hours;
        p.expiry = p.startTime + uint64(window);
        uint256 id = market.createSeries(p);

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 2e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 2e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);
        vm.warp(s.expiry);

        // A budget below what this grid needs must be refused, whatever the grid.
        uint256 tooLittle = uint256(samples) * 45_000 / 2 + 100_000;
        (bool ok,) = address(market).call{gas: tooLittle}(abi.encodeCall(market.settle, (id)));
        assertFalse(ok, "accepted a budget below the grid's requirement");
    }

    /// @notice The lazy path in `redeem` is guarded too.
    /// @dev Otherwise the hole simply moves: a redeemer with an estimated budget would void the
    ///      series on the way to collecting from it.
    function test_redeem_lazySettlementIsGuardedToo() public {
        uint256 id = openMatchedSeries(3e18);
        fillPoolSawtooth(id, 1 hours, 40);

        vm.prank(alice);
        (bool ok,) = address(market).call{gas: 400_000}(
            abi.encodeCall(market.redeem, (id, IVarianceMarket.Side.LONG, 3e18, alice))
        );

        assertFalse(ok, "redeem voided the series to save gas");
        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.ACTIVE));
    }
}

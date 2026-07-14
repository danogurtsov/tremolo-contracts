// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../helpers/BaseTest.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";

/// @notice Guards that exist because of how the thing fails, not because of how it works.
/// @dev Each of these closes a way to lose control or lose money that no functional test would
///      ever exercise, because none of them happen on any path a user intends to take.
contract HardeningTest is BaseTest {
    // ---------------------------------------------------------------------
    // Guardian transfer
    // ---------------------------------------------------------------------

    /// @notice Nominating does not hand over control; accepting does.
    function test_guardianTransfer_requiresAcceptance() public {
        vm.prank(guardian);
        market.transferGuardian(alice);

        assertEq(market.guardian(), guardian, "guardian changed before acceptance");
        assertEq(market.pendingGuardian(), alice);

        // The old guardian still governs until the handover completes.
        vm.prank(guardian);
        market.setCreationPaused(true);
        assertTrue(market.creationPaused());

        vm.prank(alice);
        market.acceptGuardian();
        assertEq(market.guardian(), alice);
        assertEq(market.pendingGuardian(), address(0), "pending not cleared");
    }

    /// @notice A mistyped address cannot take the role, because it cannot accept.
    /// @dev The whole reason for two steps. With a one-step transfer this test would be
    ///      impossible to write: control would already be gone.
    function test_guardianTransfer_toWrongAddressIsRecoverable() public {
        address typo = address(0xdead);

        vm.prank(guardian);
        market.transferGuardian(typo);

        // Nothing happened yet, so the mistake is simply overwritten.
        vm.prank(guardian);
        market.transferGuardian(bob);
        vm.prank(bob);
        market.acceptGuardian();

        assertEq(market.guardian(), bob);
    }

    function test_guardianTransfer_onlyNomineeCanAccept() public {
        vm.prank(guardian);
        market.transferGuardian(alice);

        vm.prank(bob);
        vm.expectRevert(IVarianceMarket.NotPendingGuardian.selector);
        market.acceptGuardian();
    }

    function test_guardianTransfer_onlyGuardianCanNominate() public {
        vm.prank(alice);
        vm.expectRevert(IVarianceMarket.NotGuardian.selector);
        market.transferGuardian(alice);
    }

    // ---------------------------------------------------------------------
    // Observer must be a contract
    // ---------------------------------------------------------------------

    /// @notice A codeless observer is rejected at creation.
    /// @dev An address with no code returns empty data from every staticcall, which decodes as
    ///      zero and passes validation silently. The series would be created and funded, and
    ///      would only fail at settlement — refunding everyone after wasting a whole window.
    function test_createSeries_rejectsObserverWithoutCode() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.observer = address(0xBEEF);

        vm.expectRevert(
            abi.encodeWithSelector(IVarianceMarket.ObserverHasNoCode.selector, address(0xBEEF))
        );
        market.createSeries(p);
    }

    // ---------------------------------------------------------------------
    // Activation deadline
    // ---------------------------------------------------------------------

    /// @notice A series activated long after its start cancels instead.
    /// @dev Measurement has already been running unattended, and the pool's memory of the early
    ///      part may be gone. Entering ACTIVE would produce an instrument that is live in name
    ///      only and destined to void.
    function test_activate_afterGraceCancels() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 5e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 5e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime + 2 hours); // grace is 1 hour
        market.activate(id);

        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.CANCELLED));

        // And everyone gets their money back in full.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.unsubscribe(id, IVarianceMarket.Side.LONG, 5e18);
        assertEq(
            usdc.balanceOf(alice),
            before + _valueOf(5e18, market.collateralPerUnit(id, IVarianceMarket.Side.LONG))
        );
    }

    /// @notice Inside the grace period activation still works normally.
    function test_activate_withinGraceSucceeds() public {
        uint256 id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 5e18);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, 5e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime + 59 minutes);
        market.activate(id);

        assertEq(uint8(market.getSeries(id).state), uint8(IVarianceMarket.State.ACTIVE));
    }

    // ---------------------------------------------------------------------
    // Sample ceiling in the core
    // ---------------------------------------------------------------------

    /// @notice The core enforces its own grid ceiling, not the adapter's.
    /// @dev Measured on a real pool, a 1024-point settlement costs 48.7M gas — more than an
    ///      Ethereum block. A third-party observer with a laxer limit would otherwise be able
    ///      to create a series that is fully collateralised and impossible to settle.
    function test_createSeries_rejectsGridAboveCoreCeiling() public {
        IVarianceMarket.SeriesParams memory p = defaultParams();
        p.samples = 257;
        p.expiry = p.startTime + 30 days; // keep the grid step legal, so only the ceiling bites

        vm.expectRevert(abi.encodeWithSelector(IVarianceMarket.InvalidSamples.selector, uint16(257)));
        market.createSeries(p);
    }
}

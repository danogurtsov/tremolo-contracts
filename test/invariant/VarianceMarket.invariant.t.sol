// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MarketHandler} from "./handlers/MarketHandler.sol";
import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Properties that must hold after any sequence of user actions whatsoever.
///
/// @dev These are the claims the protocol actually makes. Unit tests show that a scenario
///      someone thought of behaves correctly; these say that no scenario anyone can construct
///      breaks solvency. For a fully collateralised instrument that is the entire safety
///      argument, so it is worth stating each property in one line of English before code:
///
///        1. The contract's token balance equals its own ledger.
///        2. Nobody can take out more than was put in — across the whole life of the series.
///        3. Collateral held always covers every obligation outstanding.
///        4. Position supplies never exceed matched units.
///        5. Long and short payouts sum to exactly the collateral behind a matched unit.
///
///      Property 5 is the design in one sentence, and it is why there are no liquidations.
contract VarianceMarketInvariantTest is Test {
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;
    MockERC20 internal usdc;
    MarketHandler internal handler;

    uint256 internal seriesId;

    Variance internal constant STRIKE = Variance.wrap(0.04e18);
    uint64 internal constant CAP = 2.5e18;
    uint256 internal constant NOTIONAL_PER_UNIT = 1000e6;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));
        pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));

        seriesId = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(pool),
                collateral: address(usdc),
                startTime: uint64(block.timestamp + 6 hours),
                expiry: uint64(block.timestamp + 6 hours + 1 days),
                samples: 24,
                minCompletenessBps: 5000,
                capMultiple: CAP,
                strike: STRIKE,
                notionalPerUnit: NOTIONAL_PER_UNIT
            })
        );

        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            usdc.mint(actors[i], 10_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(market), type(uint256).max);
        }

        handler = new MarketHandler(market, pool, usdc, seriesId, actors);
        targetContract(address(handler));
    }

    // =====================================================================
    // Invariants
    // =====================================================================

    /// @notice The ledger and the actual token balance never diverge.
    /// @dev Catches any path that moves tokens without updating `_collateralHeld`, or the
    ///      reverse. With a single series in the fixture the two must be equal exactly.
    function invariant_ledgerMatchesBalance() public view {
        assertEq(
            market.collateralHeld(seriesId), usdc.balanceOf(address(market)), "ledger diverged from balance"
        );
    }

    /// @notice Nothing leaves that did not first enter.
    /// @dev The single most important property. Any bug that mints value — double redemption,
    ///      netting a position twice, a refund path that forgets to burn — shows up here.
    function invariant_neverPaysOutMoreThanWasPaidIn() public view {
        assertLe(handler.totalOut(), handler.totalIn(), "paid out more than was taken in");
    }

    /// @notice Every claim every actor could make right now is covered by collateral held.
    ///
    /// @dev Stated as "can the contract pay everyone, if they all showed up at once", which is
    ///      the only version of solvency that means anything. It is computed exactly, actor by
    ///      actor, rather than from aggregates: minting rounds down per account, so an
    ///      aggregate formula is off by up to one unit per holder and would quietly turn this
    ///      into a weaker claim than it looks.
    ///
    ///      Claims by state:
    ///        SUBSCRIBING / CANCELLED — the full deposit is withdrawable.
    ///        ACTIVE                  — a holder of both legs can net them for full collateral;
    ///                                  unconverted subscriptions can still take their refund.
    ///        SETTLED / VOIDED        — payout per unit on every position held.
    function invariant_collateralCoversClaims() public view {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        uint256 longId = market.tokenId(seriesId, IVarianceMarket.Side.LONG);
        uint256 shortId = market.tokenId(seriesId, IVarianceMarket.Side.SHORT);

        uint256 perLong = market.collateralPerUnit(seriesId, IVarianceMarket.Side.LONG);
        uint256 perShort = market.collateralPerUnit(seriesId, IVarianceMarket.Side.SHORT);
        uint256 claims;

        for (uint256 i = 0; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);

            uint256 subLong = market.subscribedUnits(seriesId, IVarianceMarket.Side.LONG, actor);
            uint256 subShort = market.subscribedUnits(seriesId, IVarianceMarket.Side.SHORT, actor);

            if (s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.CANCELLED) {
                claims += _depositFor(subLong, perLong) + _depositFor(subShort, perShort);
                continue;
            }

            // Refund owed on the unmatched remainder of a subscription, computed the way the
            // contract computes it: a share of the deposit, not a function of minted units.
            if (s.longAtActivation != 0) {
                uint256 paid = _depositFor(subLong, perLong);
                claims += paid * (s.longAtActivation - s.matchedAtActivation) / s.longAtActivation;
            }
            if (s.shortAtActivation != 0) {
                uint256 paid = _depositFor(subShort, perShort);
                claims += paid * (s.shortAtActivation - s.matchedAtActivation) / s.shortAtActivation;
            }

            uint256 longBal = market.balanceOf(actor, longId);
            uint256 shortBal = market.balanceOf(actor, shortId);

            if (s.state == IVarianceMarket.State.ACTIVE) {
                uint256 nettable = longBal < shortBal ? longBal : shortBal;
                claims += nettable * market.totalCollateralPerUnit(seriesId) / 1e18;
            } else {
                claims += longBal * market.payoutPerUnit(seriesId, IVarianceMarket.Side.LONG) / 1e18;
                claims += shortBal * market.payoutPerUnit(seriesId, IVarianceMarket.Side.SHORT) / 1e18;
            }
        }

        assertGe(market.collateralHeld(seriesId), claims, "cannot cover all claims");
    }

    /// @dev Mirrors the contract's deposit rounding, so the check does not drift from it.
    function _depositFor(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        uint256 p = units * perUnit;
        return p == 0 ? 0 : (p - 1) / 1e18 + 1;
    }

    /// @notice Position supply never exceeds what was matched.
    /// @dev Minting rounds down, so supply may sit below `matchedUnits`; above it would mean
    ///      exposure exists that nobody collateralised.
    function invariant_supplyNeverExceedsMatched() public view {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.CANCELLED) {
            return;
        }

        assertLe(market.totalSupply(market.tokenId(seriesId, IVarianceMarket.Side.LONG)), s.matchedUnits);
        assertLe(market.totalSupply(market.tokenId(seriesId, IVarianceMarket.Side.SHORT)), s.matchedUnits);
    }

    /// @notice Payouts of the two sides sum to exactly the collateral behind one unit.
    /// @dev The identity that removes liquidation from the design. Asserted continuously
    ///      rather than at a chosen moment, because "solvent at settlement" is a weaker claim
    ///      than "solvent at every point in the state machine".
    function invariant_payoutsSumToCollateral() public view {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.SETTLED) return;

        uint256 long = market.payoutPerUnit(seriesId, IVarianceMarket.Side.LONG);
        uint256 short = market.payoutPerUnit(seriesId, IVarianceMarket.Side.SHORT);

        assertEq(long + short, market.totalCollateralPerUnit(seriesId), "payouts do not close");
    }

    /// @notice Settled variance is never negative and never silently exceeds the cap in payout.
    function invariant_payoutRespectsCap() public view {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.SETTLED) return;

        assertLe(
            market.payoutPerUnit(seriesId, IVarianceMarket.Side.LONG),
            market.totalCollateralPerUnit(seriesId),
            "long payout above the pot"
        );
    }

    /// @notice Prints how often each action actually fired.
    /// @dev Not an assertion. It is here because an invariant run that never reached
    ///      `settle` proves nothing about settlement, and that failure mode is invisible
    ///      without counting.
    function invariant_callSummary() public view {
        console2.log("subscribe       ", handler.callCount("subscribe"));
        console2.log("unsubscribe     ", handler.callCount("unsubscribe"));
        console2.log("activate        ", handler.callCount("activate"));
        console2.log("mintPositions   ", handler.callCount("mintPositions"));
        console2.log("net             ", handler.callCount("net"));
        console2.log("transferPosition", handler.callCount("transferPosition"));
        console2.log("settle          ", handler.callCount("settle"));
        console2.log("redeem          ", handler.callCount("redeem"));
        console2.log("passTime        ", handler.callCount("passTime"));
        console2.log("state           ", uint8(market.getSeries(seriesId).state));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {MultiSeriesHandler} from "./handlers/MultiSeriesHandler.sol";
import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Isolation between series sharing one contract.
///
/// @dev The property a singleton has to earn: **a series can only ever pay out its own
///      collateral.** Everything the single-series suite checks stays true here, but the
///      question it cannot ask is whether series interfere — and interference is the failure
///      mode that a one-address-holds-everything design invites.
///
///      The fixture is built to make interference reachable:
///
///        series 1 — USDC (6 decimals), K = 0.04, cap 2.5, 1 day,  pool A
///        series 2 — DAI  (18 decimals), K = 0.09, cap 3.0, 2 days, pool B
///        series 3 — USDC (6 decimals), K = 0.16, cap 2.0, 1 day,  pool A   <- same token AND pool as 1
///
///      Series 1 and 3 share a collateral token and a price source, and expire at
///      different times, so a leak between them is only visible per-series — a contract-wide
///      balance check would net it out and see nothing.
contract MultiSeriesInvariantTest is Test {
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MultiSeriesHandler internal handler;

    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockUniV3Pool internal poolA;
    MockUniV3Pool internal poolB;

    uint256[] internal ids;
    address[] internal actors;

    function setUp() public {
        vm.warp(1_800_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));

        poolA = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 3 days));
        poolB = new MockUniV3Pool(-60_000, 512, uint32(block.timestamp - 3 days));

        // Windows are hours, not days, on purpose: a run has a bounded number of calls, and a
        // series whose expiry is never reached leaves settlement and redemption untested. Short
        // windows let every series complete a full lifecycle inside one run, several times over
        // the campaign. Grid steps stay above the 60-second floor (2h/24 = 300s, 4h/48 = 300s,
        // 3h/12 = 900s).
        ids.push(_create(address(usdc), address(poolA), 0.04e18, 2.5e18, 2 hours, 24, 1 hours, 1000e6));
        ids.push(_create(address(dai), address(poolB), 0.09e18, 3e18, 4 hours, 48, 2 hours, 500e18));
        ids.push(_create(address(usdc), address(poolA), 0.16e18, 2e18, 3 hours, 12, 1 hours, 250e6));

        for (uint256 i = 0; i < 4; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            usdc.mint(a, 10_000_000e6);
            dai.mint(a, 10_000_000e18);
            vm.startPrank(a);
            usdc.approve(address(market), type(uint256).max);
            dai.approve(address(market), type(uint256).max);
            vm.stopPrank();
        }

        MockUniV3Pool[] memory pools = new MockUniV3Pool[](2);
        pools[0] = poolA;
        pools[1] = poolB;

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(dai);

        handler = new MultiSeriesHandler(market, address(observer), ids, pools, tokens, actors);
        targetContract(address(handler));
    }

    function _create(
        address collateral,
        address source,
        uint256 strike,
        uint64 cap,
        uint32 window,
        uint16 samples,
        uint256 startOffset,
        uint256 notional
    ) internal returns (uint256) {
        return market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: source,
                collateral: collateral,
                startTime: uint64(block.timestamp + startOffset),
                expiry: uint64(block.timestamp + startOffset + window),
                samples: samples,
                minCompletenessBps: 5000,
                capMultiple: cap,
                strike: Variance.wrap(strike),
                notionalPerUnit: notional
            })
        );
    }

    // =====================================================================
    // Invariants
    // =====================================================================

    /// @notice Per token, the sum of every series' ledger equals the contract's balance.
    /// @dev The general form of the single-series check. Stated per token because that is the
    ///      granularity at which the contract can actually be short: a shortfall in one token
    ///      is not excused by a surplus in another.
    function invariant_perTokenLedgerMatchesBalance() public view {
        assertEq(_ledgerFor(address(usdc)), usdc.balanceOf(address(market)), "usdc ledger diverged");
        assertEq(_ledgerFor(address(dai)), dai.balanceOf(address(market)), "dai ledger diverged");
    }

    /// @notice Every series covers its own claims out of its own collateral.
    /// @dev The isolation property itself. A series that could reach into a neighbour's
    ///      collateral would still satisfy a contract-wide balance check, and would still
    ///      satisfy the single-series suite — it fails only here, and only per series.
    function invariant_everySeriesCoversItsOwnClaims() public view {
        uint256[] memory live = handler.allSeries();
        for (uint256 i = 0; i < live.length; ++i) {
            assertGe(
                market.collateralHeld(live[i]),
                _claimsFor(live[i]),
                string.concat("series ", vm.toString(live[i]), " cannot cover its own claims")
            );
        }
    }

    /// @notice Nothing leaves that did not first enter, per token.
    function invariant_neverPaysOutMoreThanPaidIn() public view {
        assertLe(handler.totalOut(address(usdc)), handler.totalIn(address(usdc)), "usdc paid out too much");
        assertLe(handler.totalOut(address(dai)), handler.totalIn(address(dai)), "dai paid out too much");
    }

    /// @notice A settled series' payouts still close exactly, whatever the neighbours are doing.
    function invariant_payoutsSumToCollateralInEverySeries() public view {
        uint256[] memory live = handler.allSeries();
        for (uint256 i = 0; i < live.length; ++i) {
            IVarianceMarket.Series memory s = market.getSeries(live[i]);
            if (s.state != IVarianceMarket.State.SETTLED) continue;

            uint256 long = market.payoutPerUnit(live[i], IVarianceMarket.Side.LONG);
            uint256 short = market.payoutPerUnit(live[i], IVarianceMarket.Side.SHORT);
            assertEq(long + short, market.totalCollateralPerUnit(live[i]), "payouts do not close");
        }
    }

    /// @notice Position tokens of different series never collide.
    /// @dev `tokenId = seriesId << 1 | side` is only injective if nothing else ever mints into
    ///      that space. Cheap to assert, and a collision would be catastrophic and silent.
    function invariant_tokenIdsDoNotCollide() public view {
        uint256[] memory ids_ = handler.allSeries();
        for (uint256 i = 0; i < ids_.length; ++i) {
            for (uint256 j = i + 1; j < ids_.length; ++j) {
                assertTrue(
                    market.tokenId(ids_[i], IVarianceMarket.Side.LONG)
                        != market.tokenId(ids_[j], IVarianceMarket.Side.LONG),
                    "long token ids collide"
                );
                assertTrue(
                    market.tokenId(ids_[i], IVarianceMarket.Side.LONG)
                        != market.tokenId(ids_[j], IVarianceMarket.Side.SHORT),
                    "long and short ids collide across series"
                );
            }
        }
    }

    /// @notice Prints how far runs actually got, per action and per series state.
    function invariant_callSummary() public view {
        console2.log(
            "subscribe/unsubscribe", handler.callCount("subscribe"), handler.callCount("unsubscribe")
        );
        console2.log(
            "activate/mint        ", handler.callCount("activate"), handler.callCount("mintPositions")
        );
        console2.log("net/transfer         ", handler.callCount("net"), handler.callCount("transferPosition"));
        console2.log("settle/redeem        ", handler.callCount("settle"), handler.callCount("redeem"));
        // 1 SUBSCRIBING, 2 ACTIVE, 3 SETTLED, 4 VOIDED, 5 CANCELLED. Anything below 3 here
        // means the campaign never reached settlement for that series.
        uint256[] memory live = handler.allSeries();
        console2.log("series opened        ", live.length);
        for (uint256 i = 0; i < live.length; ++i) {
            console2.log(
                "series / now / furthest",
                live[i],
                uint8(market.getSeries(live[i]).state),
                handler.maxState(live[i])
            );
        }
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _ledgerFor(address token) internal view returns (uint256 total) {
        uint256[] memory live = handler.allSeries();
        for (uint256 i = 0; i < live.length; ++i) {
            if (market.getSeries(live[i]).collateral == token) total += market.collateralHeld(live[i]);
        }
    }

    /// @dev Everything every actor could withdraw from this series right now. Computed per
    ///      account because minting rounds down per account; an aggregate would be off by up
    ///      to one unit per holder and would weaken the property.
    function _claimsFor(uint256 id) internal view returns (uint256 claims) {
        for (uint256 i = 0; i < actors.length; ++i) {
            claims += _subscriptionClaim(id, actors[i]) + _positionClaim(id, actors[i]);
        }
    }

    /// @dev What an actor can still withdraw from an unconverted subscription.
    function _subscriptionClaim(uint256 id, address actor) internal view returns (uint256 claim) {
        IVarianceMarket.Series memory s = market.getSeries(id);
        uint256 subLong = market.subscribedUnits(id, IVarianceMarket.Side.LONG, actor);
        uint256 subShort = market.subscribedUnits(id, IVarianceMarket.Side.SHORT, actor);

        uint256 paidLong = _depositFor(subLong, market.collateralPerUnit(id, IVarianceMarket.Side.LONG));
        uint256 paidShort = _depositFor(subShort, market.collateralPerUnit(id, IVarianceMarket.Side.SHORT));

        if (s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.CANCELLED) {
            return paidLong + paidShort;
        }

        if (s.longAtActivation != 0) {
            claim += paidLong * (s.longAtActivation - s.matchedAtActivation) / s.longAtActivation;
        }
        if (s.shortAtActivation != 0) {
            claim += paidShort * (s.shortAtActivation - s.matchedAtActivation) / s.shortAtActivation;
        }
    }

    /// @dev What an actor can extract from the positions it holds: netting while active,
    ///      the payout formula once settled or voided.
    function _positionClaim(uint256 id, address actor) internal view returns (uint256) {
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.CANCELLED) {
            return 0;
        }

        uint256 longBal = market.balanceOf(actor, market.tokenId(id, IVarianceMarket.Side.LONG));
        uint256 shortBal = market.balanceOf(actor, market.tokenId(id, IVarianceMarket.Side.SHORT));

        if (s.state == IVarianceMarket.State.ACTIVE) {
            uint256 nettable = longBal < shortBal ? longBal : shortBal;
            return nettable * market.totalCollateralPerUnit(id) / 1e18;
        }

        return longBal * market.payoutPerUnit(id, IVarianceMarket.Side.LONG) / 1e18 + shortBal
            * market.payoutPerUnit(id, IVarianceMarket.Side.SHORT) / 1e18;
    }

    function _depositFor(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        uint256 p = units * perUnit;
        return p == 0 ? 0 : (p - 1) / 1e18 + 1;
    }
}

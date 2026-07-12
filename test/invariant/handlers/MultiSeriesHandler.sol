// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {VarianceMarket} from "../../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../../src/interfaces/IVarianceMarket.sol";
import {MockUniV3Pool} from "../../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {Variance} from "../../../src/types/Variance.sol";

/// @notice Drives several series at once, across two collateral tokens and two pools.
///
/// @dev The single-series handler cannot express the risk that matters most in a singleton:
///      collateral belonging to one series being paid out through another. Every action here
///      therefore picks a series at random, so runs interleave series that are subscribing,
///      active, settled and voided at the same moment, two of them sharing a token and a pool.
///
///      Ghost accounting is kept per token, because that is the granularity at which the
///      "nothing leaves that did not enter" property is actually meaningful.
contract MultiSeriesHandler is CommonBase, StdCheats, StdUtils {
    VarianceMarket public immutable market;

    uint256[] public seriesIds;
    address public immutable observer;

    /// @dev Cap on how many series a run may open. Invariants iterate over all of them, so an
    ///      unbounded registry would turn every assertion into a gas problem.
    uint256 internal constant MAX_SERIES = 4;
    MockUniV3Pool[] public pools;
    address[] public tokens;
    address[] public actors;

    address internal currentActor;

    /// @dev Matches VarianceMarket.MIN_SUBSCRIPTION.
    uint256 internal constant MIN_UNITS = 0.0001e18;

    mapping(address token => uint256) public totalIn;
    mapping(address token => uint256) public totalOut;
    mapping(bytes32 => uint256) public calls;

    /// @dev Furthest lifecycle state each series reached during a run. A suite that never
    ///      leaves SUBSCRIBING is green and proves nothing, and there is no way to tell from
    ///      the outside — so it is recorded rather than assumed.
    mapping(uint256 seriesId => uint8) public maxState;

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier countCall(bytes32 name) {
        calls[name]++;
        _;
    }

    constructor(
        VarianceMarket market_,
        address observer_,
        uint256[] memory seriesIds_,
        MockUniV3Pool[] memory pools_,
        address[] memory tokens_,
        address[] memory actors_
    ) {
        market = market_;
        observer = observer_;
        seriesIds = seriesIds_;
        pools = pools_;
        tokens = tokens_;
        actors = actors_;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    /// @notice Opens a new series with randomised parameters.
    /// @dev Without this, a run has a fixed set of series whose subscription windows close once
    ///      and never reopen — and since `passTime` can step straight past a start time, most
    ///      runs ended with every series stuck in SUBSCRIBING, green and vacuous. Creating
    ///      series as the run proceeds is also what actually happens in production.
    function openSeries(uint256 tokenSeed, uint256 poolSeed, uint256 strikeSeed, uint256 windowSeed)
        external
        countCall("openSeries")
    {
        if (seriesIds.length >= MAX_SERIES) return;

        uint32 window = uint32(bound(windowSeed, 1 hours, 2 hours));
        // Grid points, kept in a range a pool observed every ~5 minutes can actually support.
        uint16 samples = uint16(bound(strikeSeed, 2, 12));

        uint256 id = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: observer,
                source: address(pools[poolSeed % pools.length]),
                collateral: tokens[tokenSeed % tokens.length],
                startTime: uint64(block.timestamp + bound(windowSeed, 20 minutes, 60 minutes)),
                expiry: uint64(block.timestamp + bound(windowSeed, 20 minutes, 60 minutes) + window),
                samples: samples,
                minCompletenessBps: 5000,
                capMultiple: uint64(bound(strikeSeed, 1.2e18, 4e18)),
                strike: Variance.wrap(bound(strikeSeed, 0.01e18, 1e18)),
                notionalPerUnit: MockERC20(tokens[tokenSeed % tokens.length]).decimals() == 6
                    ? 1000e6
                    : 1000e18
            })
        );
        seriesIds.push(id);
    }

    function subscribe(uint256 seriesSeed, uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("subscribe")
    {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.SUBSCRIBING) return;
        if (block.timestamp >= s.startTime) return;

        IVarianceMarket.Side side = _side(sideSeed);
        units = bound(units, MIN_UNITS, 50e18);

        uint256 cost = _depositFor(units, market.collateralPerUnit(id, side));
        if (MockERC20(s.collateral).balanceOf(currentActor) < cost) return;

        market.subscribe(id, side, units);
        totalIn[s.collateral] += cost;
    }

    /// @notice Subscribes both legs of the same series in one call.
    /// @dev Random single-sided subscriptions almost never produce a match: with several open
    ///      series and a bounded number of calls, the chance that both sides of the *same*
    ///      series get filled before its start time is negligible, and every run ended stuck in
    ///      SUBSCRIBING. This is also the realistic path — a market maker posts both legs and
    ///      then sells one of them on.
    function subscribeBothSides(uint256 seriesSeed, uint256 actorSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("subscribeBothSides")
    {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.SUBSCRIBING) return;
        if (block.timestamp >= s.startTime) return;

        units = bound(units, MIN_UNITS, 50e18);
        uint256 costLong = _depositFor(units, market.collateralPerUnit(id, IVarianceMarket.Side.LONG));
        uint256 costShort = _depositFor(units, market.collateralPerUnit(id, IVarianceMarket.Side.SHORT));
        if (MockERC20(s.collateral).balanceOf(currentActor) < costLong + costShort) return;

        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);
        totalIn[s.collateral] += costLong + costShort;
    }

    function unsubscribe(uint256 seriesSeed, uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("unsubscribe")
    {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        bool open = s.state == IVarianceMarket.State.SUBSCRIBING && block.timestamp < s.startTime;
        if (!open && s.state != IVarianceMarket.State.CANCELLED) return;

        IVarianceMarket.Side side = _side(sideSeed);
        uint256 held = market.subscribedUnits(id, side, currentActor);
        if (held < MIN_UNITS) return;

        units = bound(units, MIN_UNITS, held);
        market.unsubscribe(id, side, units);
        totalOut[s.collateral] += units * market.collateralPerUnit(id, side) / 1e18;
    }

    function activate(uint256 seriesSeed) external countCall("activate") {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.SUBSCRIBING) return;
        if (block.timestamp < s.startTime) return;
        // Skipping the empty case keeps runs inside the states where money is at risk;
        // cancellation has its own unit test.
        if (s.subscribedLong == 0 || s.subscribedShort == 0) return;
        market.activate(id);
        _recordStates();
    }

    function mintPositions(uint256 seriesSeed, uint256 actorSeed, uint256 sideSeed)
        external
        countCall("mintPositions")
    {
        uint256 id = _series(seriesSeed);
        address actor = actors[actorSeed % actors.length];
        IVarianceMarket.Side side = _side(sideSeed);

        IVarianceMarket.Series memory s = market.getSeries(id);
        if (
            s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.NONE
                || s.state == IVarianceMarket.State.CANCELLED
        ) return;
        if (market.subscribedUnits(id, side, actor) == 0) return;

        (, uint256 refunded) = market.mintPositions(id, side, actor);
        totalOut[s.collateral] += refunded;
    }

    function net(uint256 seriesSeed, uint256 actorSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("net")
    {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.ACTIVE) return;

        uint256 longBal = market.balanceOf(currentActor, market.tokenId(id, IVarianceMarket.Side.LONG));
        uint256 shortBal = market.balanceOf(currentActor, market.tokenId(id, IVarianceMarket.Side.SHORT));
        uint256 max = longBal < shortBal ? longBal : shortBal;
        if (max == 0) return;

        units = bound(units, 1, max);
        totalOut[s.collateral] += market.net(id, units);
    }

    function transferPosition(
        uint256 seriesSeed,
        uint256 fromSeed,
        uint256 toSeed,
        uint256 sideSeed,
        uint256 units
    ) external useActor(fromSeed) countCall("transferPosition") {
        uint256 id = _series(seriesSeed);
        address to = actors[toSeed % actors.length];
        uint256 tokenId = market.tokenId(id, _side(sideSeed));

        uint256 bal = market.balanceOf(currentActor, tokenId);
        if (bal == 0 || to == currentActor) return;

        units = bound(units, 1, bal);
        market.transfer(to, tokenId, units);
    }

    function settle(uint256 seriesSeed) external countCall("settle") {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.ACTIVE) return;
        if (block.timestamp < s.expiry) return;
        market.settle(id);
        _recordStates();
    }

    function redeem(uint256 seriesSeed, uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("redeem")
    {
        uint256 id = _series(seriesSeed);
        IVarianceMarket.Series memory s = market.getSeries(id);
        if (s.state != IVarianceMarket.State.SETTLED && s.state != IVarianceMarket.State.VOIDED) {
            return;
        }

        IVarianceMarket.Side side = _side(sideSeed);
        uint256 bal = market.balanceOf(currentActor, market.tokenId(id, side));
        if (bal == 0) return;

        units = bound(units, 1, bal);
        totalOut[s.collateral] += market.redeem(id, side, units, currentActor);
    }

    /// @notice Advances time and writes an observation to every pool.
    /// @dev All pools move together so that series on different pools reach their expiries at
    ///      different points while sharing one clock.
    function passTime(uint256 secondsSeed, int256 tickSeed) external countCall("passTime") {
        // Sized against the series lengths in `openSeries`: long enough that a run reaches
        // expiry, short enough that subscription windows are not routinely stepped over.
        uint256 step = bound(secondsSeed, 5 minutes, 75 minutes);
        int256 tick = bound(tickSeed, 199_000, 201_000);

        // Observations are written every few minutes across the step, not once at the end. A
        // pool that records twice an hour cannot support a 60-point grid, so the first version
        // of this handler voided almost every series on completeness and never tested a real
        // settlement. Real pools on the venues this targets trade far more often than this.
        uint256 slices = step / 5 minutes;
        if (slices == 0) slices = 1;

        for (uint256 k = 1; k <= slices; ++k) {
            vm.warp(block.timestamp + step / slices);
            for (uint256 i = 0; i < pools.length; ++i) {
                int256 wobble = int256(k % 7) * 11 - 33;
                pools[i].writeObservation(uint32(block.timestamp), int24(tick + int256(i) * 37 + wobble));
            }
        }

        _activateWhatIsDue();
        _recordStates();
    }

    /// @dev Activation is permissionless and costs almost nothing, so in production it happens
    ///      the moment it becomes possible. Modelling it as a rare random action was not
    ///      conservative, it was simply wrong: runs spent their whole budget in SUBSCRIBING and
    ///      never exercised a single state where money is at risk.
    function _activateWhatIsDue() internal {
        for (uint256 i = 0; i < seriesIds.length; ++i) {
            IVarianceMarket.Series memory s = market.getSeries(seriesIds[i]);
            if (s.state != IVarianceMarket.State.SUBSCRIBING) continue;
            if (block.timestamp < s.startTime) continue;
            if (s.subscribedLong == 0 || s.subscribedShort == 0) continue;
            market.activate(seriesIds[i]);
        }
    }

    /// @dev Called from the action that fires most often, so the record is kept up to date
    ///      without paying for it in every handler.
    function _recordStates() internal {
        for (uint256 i = 0; i < seriesIds.length; ++i) {
            uint8 st = uint8(market.getSeries(seriesIds[i]).state);
            if (st > maxState[seriesIds[i]]) maxState[seriesIds[i]] = st;
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _series(uint256 seed) internal view returns (uint256) {
        return seriesIds[seed % seriesIds.length];
    }

    function _side(uint256 seed) internal pure returns (IVarianceMarket.Side) {
        return seed % 2 == 0 ? IVarianceMarket.Side.LONG : IVarianceMarket.Side.SHORT;
    }

    /// @dev Mirrors the contract's round-up on deposits.
    function _depositFor(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        uint256 p = units * perUnit;
        return p == 0 ? 0 : (p - 1) / 1e18 + 1;
    }

    function seriesCount() external view returns (uint256) {
        return seriesIds.length;
    }

    function allSeries() external view returns (uint256[] memory) {
        return seriesIds;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function callCount(bytes32 name) external view returns (uint256) {
        return calls[name];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {VarianceMarket} from "../../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../../src/interfaces/IVarianceMarket.sol";
import {MockUniV3Pool} from "../../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";

/// @notice Drives one series through arbitrary sequences of user actions.
///
/// @dev Runs under `fail_on_revert = true`, so every handler guards its own preconditions and
///      returns quietly instead of reverting. That setting is not a formality: with reverts
///      tolerated, a suite silently degrades into "every call bounced, nothing was checked",
///      which is the most common way an invariant suite ends up green and worthless.
///
///      Ghost accounting (`totalIn` / `totalOut`) is kept here rather than derived, because
///      the central property — you cannot take out more than was put in — has to be checked
///      against something the contract itself does not compute.
contract MarketHandler is CommonBase, StdCheats, StdUtils {
    VarianceMarket public immutable market;
    MockUniV3Pool public immutable pool;
    MockERC20 public immutable usdc;
    uint256 public immutable seriesId;

    address[] public actors;
    address internal currentActor;

    uint256 public totalIn;
    uint256 public totalOut;

    // Call counters, printed by `invariant_callSummary`. A run where `settle` never fired is
    // a run that tested nothing interesting, and the only way to know is to count.
    mapping(bytes32 => uint256) public calls;

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
        MockUniV3Pool pool_,
        MockERC20 usdc_,
        uint256 seriesId_,
        address[] memory actors_
    ) {
        market = market_;
        pool = pool_;
        usdc = usdc_;
        seriesId = seriesId_;
        actors = actors_;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function subscribe(uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("subscribe")
    {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.SUBSCRIBING) return;
        if (block.timestamp >= s.startTime) return;

        IVarianceMarket.Side side = _side(sideSeed);
        units = bound(units, 1, 50);

        uint256 cost = market.collateralPerUnit(seriesId, side) * units;
        if (usdc.balanceOf(currentActor) < cost) return;

        market.subscribe(seriesId, side, units);
        totalIn += cost;
    }

    function unsubscribe(uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("unsubscribe")
    {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        bool open = s.state == IVarianceMarket.State.SUBSCRIBING && block.timestamp < s.startTime;
        bool cancelled = s.state == IVarianceMarket.State.CANCELLED;
        if (!open && !cancelled) return;

        IVarianceMarket.Side side = _side(sideSeed);
        uint256 held = market.subscribedUnits(seriesId, side, currentActor);
        if (held == 0) return;

        units = bound(units, 1, held);
        market.unsubscribe(seriesId, side, units);
        totalOut += market.collateralPerUnit(seriesId, side) * units;
    }

    function activate() external countCall("activate") {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.SUBSCRIBING) return;
        if (block.timestamp < s.startTime) return;

        // Skip the empty case: activating with one side unfilled cancels the
        // series, and a cancelled series is a dead end: every later action returns early and
        // the run stops exercising settlement. Cancellation has its own unit test; here the
        // point is to keep runs inside the states where money is actually at risk.
        if (s.subscribedLong == 0 || s.subscribedShort == 0) return;

        market.activate(seriesId);
    }

    function mintPositions(uint256 actorSeed, uint256 sideSeed) external countCall("mintPositions") {
        address actor = actors[actorSeed % actors.length];
        IVarianceMarket.Side side = _side(sideSeed);

        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (
            s.state == IVarianceMarket.State.SUBSCRIBING || s.state == IVarianceMarket.State.NONE
                || s.state == IVarianceMarket.State.CANCELLED
        ) return;
        if (market.subscribedUnits(seriesId, side, actor) == 0) return;

        (, uint256 refunded) = market.mintPositions(seriesId, side, actor);
        totalOut += refunded;
    }

    function net(uint256 actorSeed, uint256 units) external useActor(actorSeed) countCall("net") {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.ACTIVE) return;

        uint256 longBal = market.balanceOf(currentActor, market.tokenId(seriesId, IVarianceMarket.Side.LONG));
        uint256 shortBal =
            market.balanceOf(currentActor, market.tokenId(seriesId, IVarianceMarket.Side.SHORT));
        uint256 max = longBal < shortBal ? longBal : shortBal;
        if (max == 0) return;

        units = bound(units, 1, max);
        totalOut += market.net(seriesId, units);
    }

    /// @notice Moves a position between actors so netting has something to work with.
    function transferPosition(uint256 fromSeed, uint256 toSeed, uint256 sideSeed, uint256 units)
        external
        useActor(fromSeed)
        countCall("transferPosition")
    {
        address to = actors[toSeed % actors.length];
        uint256 id = market.tokenId(seriesId, _side(sideSeed));
        uint256 bal = market.balanceOf(currentActor, id);
        if (bal == 0 || to == currentActor) return;

        units = bound(units, 1, bal);
        market.transfer(to, id, units);
    }

    function settle() external countCall("settle") {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.ACTIVE) return;
        if (block.timestamp < s.expiry) return;
        market.settle(seriesId);
    }

    function redeem(uint256 actorSeed, uint256 sideSeed, uint256 units)
        external
        useActor(actorSeed)
        countCall("redeem")
    {
        IVarianceMarket.Series memory s = market.getSeries(seriesId);
        if (s.state != IVarianceMarket.State.SETTLED && s.state != IVarianceMarket.State.VOIDED) {
            return;
        }

        IVarianceMarket.Side side = _side(sideSeed);
        uint256 bal = market.balanceOf(currentActor, market.tokenId(seriesId, side));
        if (bal == 0) return;

        units = bound(units, 1, bal);
        totalOut += market.redeem(seriesId, side, units, currentActor);
    }

    /// @notice Advances time and writes a pool observation, i.e. lets the market trade.
    /// @dev Without this the series never reaches expiry and the interesting half of the
    ///      state machine is unreachable.
    function passTime(uint256 secondsSeed, int256 tickSeed) external countCall("passTime") {
        uint256 step = bound(secondsSeed, 5 minutes, 4 hours);
        vm.warp(block.timestamp + step);

        int256 tick = bound(tickSeed, 199_000, 201_000);
        pool.writeObservation(uint32(block.timestamp), int24(tick));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _side(uint256 seed) internal pure returns (IVarianceMarket.Side) {
        return seed % 2 == 0 ? IVarianceMarket.Side.LONG : IVarianceMarket.Side.SHORT;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function callCount(bytes32 name) external view returns (uint256) {
        return calls[name];
    }
}

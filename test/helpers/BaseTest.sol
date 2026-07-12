// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Shared fixture: a market, an observer, a mock pool with history, funded actors.
abstract contract BaseTest is Test {
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;
    MockERC20 internal usdc;

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice"); // long by default
    address internal bob = makeAddr("bob"); // short by default
    address internal carol = makeAddr("carol");

    /// @dev 20% annualised vol -> variance 0.04.
    Variance internal constant STRIKE = Variance.wrap(0.04e18);
    uint64 internal constant CAP = 2.5e18;
    uint256 internal constant NOTIONAL_PER_UNIT = 1000e6; // 1000 USDC per 1.0 of variance
    uint16 internal constant SAMPLES = 24;
    uint16 internal constant MIN_COMPLETENESS_BPS = 8000;

    uint32 internal constant WINDOW = 1 days;
    int24 internal constant START_TICK = 200_000;

    function setUp() public virtual {
        // Start far enough into epoch time that the pool can hold history behind us.
        vm.warp(1_800_000_000);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        observer = new UniV3Observer();
        market = new VarianceMarket(guardian);

        // Pool remembers two days back, which clears WINDOW + LOOKBACK_HEADROOM.
        pool = new MockUniV3Pool(START_TICK, 512, uint32(block.timestamp - 2 days));

        for (uint256 i = 0; i < 3; ++i) {
            address who = [alice, bob, carol][i];
            usdc.mint(who, 1_000_000e6);
            vm.prank(who);
            usdc.approve(address(market), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------
    // Fixture helpers
    // ---------------------------------------------------------------------

    function defaultParams() internal view returns (IVarianceMarket.SeriesParams memory) {
        return IVarianceMarket.SeriesParams({
            observer: address(observer),
            source: address(pool),
            collateral: address(usdc),
            startTime: uint64(block.timestamp + 1 hours),
            expiry: uint64(block.timestamp + 1 hours + WINDOW),
            samples: SAMPLES,
            minCompletenessBps: MIN_COMPLETENESS_BPS,
            capMultiple: CAP,
            strike: STRIKE,
            notionalPerUnit: NOTIONAL_PER_UNIT
        });
    }

    function createDefaultSeries() internal returns (uint256 id) {
        id = market.createSeries(defaultParams());
    }

    /// @notice Subscribes both sides, warps to start, activates and mints positions.
    function openMatchedSeries(uint256 units) internal returns (uint256 id) {
        id = createDefaultSeries();

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);

        market.mintPositions(id, IVarianceMarket.Side.LONG, alice);
        market.mintPositions(id, IVarianceMarket.Side.SHORT, bob);
    }

    /// @notice Writes pool observations across a series window on a fixed cadence.
    /// @param tickStep Signed tick move applied at each step; alternating sign produces a
    ///        sawtooth whose realized variance is predictable.
    function fillPoolSawtooth(uint256 id, uint32 cadence, int24 tickStep) internal {
        IVarianceMarket.Series memory s = market.getSeries(id);
        int24 tick = START_TICK;
        uint32 ts = uint32(s.startTime);

        while (ts <= s.expiry) {
            vm.warp(ts);
            tick = tick == START_TICK ? START_TICK + tickStep : START_TICK;
            pool.writeObservation(ts, tick);
            ts += cadence;
        }
        vm.warp(s.expiry);
    }

    /// @notice Writes a flat series: prices never move, realized variance is zero.
    function fillPoolFlat(uint256 id, uint32 cadence) internal {
        IVarianceMarket.Series memory s = market.getSeries(id);
        uint32 ts = uint32(s.startTime);
        while (ts <= s.expiry) {
            vm.warp(ts);
            pool.writeObservation(ts, START_TICK);
            ts += cadence;
        }
        vm.warp(s.expiry);
    }

    /// @dev Positions are WAD-denominated, so `units` is scaled by 1e18 throughout the tests.
    function totalDeposited(uint256 id, uint256 units) internal view returns (uint256) {
        return _depositFor(units, market.collateralPerUnit(id, IVarianceMarket.Side.LONG))
            + _depositFor(units, market.collateralPerUnit(id, IVarianceMarket.Side.SHORT));
    }

    /// @dev Mirrors the contract's round-up on deposits.
    function _depositFor(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        uint256 p = units * perUnit;
        return p == 0 ? 0 : (p - 1) / 1e18 + 1;
    }

    function _valueOf(uint256 units, uint256 perUnit) internal pure returns (uint256) {
        return units * perUnit / 1e18;
    }
}

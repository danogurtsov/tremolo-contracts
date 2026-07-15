// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {IUniswapV3PoolOracle} from "../../src/interfaces/IUniswapV3PoolOracle.sol";
import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice The adapter against a real Uniswap V3 pool, not against our own mock.
///
/// @dev Everything else in this repository tests the adapter against `MockUniV3Pool`, which was
///      written by the same person as the adapter. A mock and the code it stands in for can
///      share a misunderstanding, and no amount of green from that pairing would reveal it.
///      These tests exist to break that symmetry: the only thing they trust is the chain.
///
///      Pinned to a fixed block so results are reproducible. Falls back to a public archive
///      endpoint, so `forge test` works without any configuration.
contract UniV3ObserverForkTest is Test {
    /// @dev Uniswap V3 WETH/USDC 0.05% on Base. The deepest ETH pool on the target chain.
    address internal constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    uint256 internal constant FORK_BLOCK = 49_000_000;

    UniV3Observer internal observer;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        try vm.createSelectFork(rpc, FORK_BLOCK) {
            forked = true;
        } catch {
            // No network in this environment; skip the fork suite.
            return;
        }
        observer = new UniV3Observer();
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ---------------------------------------------------------------------
    // What the pool actually looks like
    // ---------------------------------------------------------------------

    /// @notice Records the real shape of the buffer this protocol depends on.
    /// @dev Not an assertion so much as a measurement that runs in CI. The numbers below drove
    ///      several design decisions and would silently rot if nothing printed them.
    function test_poolShape() public onFork {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolOracle(POOL).slot0();
        (uint32 oldest,,,) = IUniswapV3PoolOracle(POOL).observations((index + 1) % cardinality);
        (uint32 newest,,,) = IUniswapV3PoolOracle(POOL).observations(index);

        uint32 depth = uint32(block.timestamp) - oldest;

        console2.log("cardinality        ", cardinality);
        console2.log("history depth (s)  ", depth);
        console2.log("history depth (h)  ", depth / 3600);
        console2.log("avg gap (s)        ", (newest - oldest) / cardinality);

        // The buffer is the binding constraint on series length, so state it as a test rather
        // than as a comment that ages badly.
        assertGt(cardinality, 1, "pool has no oracle buffer at all");
        assertGe(depth, 1 hours, "buffer shallower than the shortest permitted window");
    }

    /// @notice `maxLookback` must agree with the buffer read by hand.
    function test_maxLookback_matchesRawBuffer() public onFork {
        (,, uint16 index, uint16 cardinality,,,) = IUniswapV3PoolOracle(POOL).slot0();
        (uint32 oldest,,, bool initialized) =
            IUniswapV3PoolOracle(POOL).observations((index + 1) % cardinality);
        if (!initialized) (oldest,,,) = IUniswapV3PoolOracle(POOL).observations(0);

        assertEq(
            observer.maxLookback(POOL),
            uint32(block.timestamp) - oldest,
            "adapter disagrees with the raw ring buffer"
        );
    }

    // ---------------------------------------------------------------------
    // The series the adapter produces
    // ---------------------------------------------------------------------

    /// @notice The reconstructed series must equal what a caller computes from raw cumulatives.
    /// @dev This is the test that would have caught a wrong `secondsAgos` layout, an off-by-one
    ///      in the grid, or a mishandled remainder — none of which the mock could expose,
    ///      because the mock implements the same idea of what "correct" means.
    ///
    ///      The comparison is done independently here: build `secondsAgos` from scratch, call
    ///      `observe` directly, and difference the cumulatives without touching library code.
    function test_sampleTicks_matchesIndependentReconstruction() public onFork {
        uint32 endTime = uint32(block.timestamp);
        uint32 window = 6 hours;
        uint16 samples = 24;

        int256[] memory got = observer.sampleTicks(POOL, endTime, window, samples);
        assertEq(got.length, samples, "wrong series length");

        uint32 step = window / samples;
        uint32[] memory secondsAgos = new uint32[](uint256(samples) + 1);
        for (uint256 i = 0; i <= samples; ++i) {
            secondsAgos[i] = i == 0 ? window : uint32((samples - i) * step);
        }

        (int56[] memory cumulatives,) = IUniswapV3PoolOracle(POOL).observe(secondsAgos);

        for (uint256 i = 0; i < samples; ++i) {
            uint32 dt = i == 0 ? window - (samples - 1) * step : step;
            int256 expected = (int256(cumulatives[i + 1]) - int256(cumulatives[i])) / int256(uint256(dt));
            assertEq(got[i], expected, "reconstructed tick differs from raw cumulative difference");
        }
    }

    /// @notice Ticks come back inside Uniswap's own domain, and near the pool's current price.
    /// @dev A cheap sanity net: an adapter that mixed up sign or scale would still produce a
    ///      well-formed array, and only a range check catches that.
    function test_sampleTicks_areNearCurrentPrice() public onFork {
        (, int24 currentTick,,,,,) = IUniswapV3PoolOracle(POOL).slot0();
        int256[] memory ticks = observer.sampleTicks(POOL, uint32(block.timestamp), 6 hours, 24);

        for (uint256 i = 0; i < ticks.length; ++i) {
            assertLt(_abs(ticks[i]), 887_272, "tick outside Uniswap's domain");
            // 2000 ticks is ~22%. Six hours of ETH never moves that far without it being news.
            assertLt(_abs(ticks[i] - currentTick), 2000, "tick implausibly far from spot");
        }
    }

    /// @notice Genuine recordings are counted, and on this pool there are many.
    /// @dev The completeness check is only meaningful if this number is real. On a pool trading
    ///      every few seconds it should be at or near the buffer size for a multi-hour window.
    function test_realObservations_countsGenuineRecordings() public onFork {
        uint256 count = observer.realObservations(POOL, uint32(block.timestamp), 6 hours);
        console2.log("genuine recordings in 6h", count);

        assertGt(count, 0, "no genuine recordings found in six hours of a top-five pool");
    }

    /// @notice Realized variance on real ETH data must land in a believable range.
    /// @dev The end-to-end reality check. If the maths, the adapter and the annualisation all
    ///      agree with the world, six hours of ETH gives an annualised volatility somewhere
    ///      between a very quiet 10% and a very stressed 250%. Anything outside that is a units
    ///      bug, and a units bug is exactly the kind of thing a mock cannot reveal.
    function test_realizedVariance_isPlausibleForEth() public onFork {
        int256[] memory ticks = observer.sampleTicks(POOL, uint32(block.timestamp), 6 hours, 24);
        Variance rv = VarianceMath.fromTicks(ticks, 6 hours);

        uint256 raw = Variance.unwrap(rv);
        // sqrt of a WAD is a WAD once the argument is scaled up first; /1e16 turns that into
        // whole percent. Getting this wrong the first time produced 2115% and is exactly why
        // the plausibility bound below is worth having.
        uint256 volPct = _sqrt(raw * 1e18) / 1e16;

        console2.log("realized variance (wad)", raw);
        console2.log("annualised vol (%)     ", volPct);

        assertGt(volPct, 5, "implausibly low realized volatility for ETH");
        assertLt(volPct, 300, "implausibly high realized volatility for ETH");
    }

    /// @notice Grid density changes the estimate, monotonically, and by a lot.
    ///
    /// @dev The measurement this protocol owed, and it says something sharper than expected.
    ///      Measured on this pool and block, over the same six hours:
    ///
    ///        12 points (30.0 min step)  variance 0.0338   ->  18.4% annualised
    ///        24 points (15.0 min step)  variance 0.0448   ->  21.2%
    ///        48 points ( 7.5 min step)  variance 0.0479   ->  21.9%
    ///        96 points ( 3.8 min step)  variance 0.0546   ->  23.4%
    ///
    ///      A coarser grid reports LESS variance, by 38% between the coarsest and finest here.
    ///      The cause is not interpolation, which is what the design notes assumed: this pool
    ///      records every ~23 seconds, so even the 96-point grid has ~10 genuine observations
    ///      per step and almost nothing is interpolated. The cause is that each sample is a
    ///      TWAP over its step, and averaging inside a step cancels movement within it. The
    ///      longer the step, the more is cancelled.
    ///
    ///      That is a stronger and more general statement than "sparse pools bias downward":
    ///      the grid step is itself a parameter of the quantity being settled, on any pool.
    ///      Two series over the same window with different grids are different instruments.
    function test_varianceAcrossGridDensities() public onFork {
        uint16[4] memory grids = [uint16(12), 24, 48, 96];
        uint256[4] memory results;

        for (uint256 i = 0; i < grids.length; ++i) {
            int256[] memory ticks = observer.sampleTicks(POOL, uint32(block.timestamp), 6 hours, grids[i]);
            results[i] = Variance.unwrap(VarianceMath.fromTicks(ticks, 6 hours));
            console2.log("grid points / variance (wad)", grids[i], results[i]);
        }

        // Every density must produce a number of the same order. An order-of-magnitude gap
        // would mean the estimate is dominated by the grid rather than by the market.
        for (uint256 i = 1; i < results.length; ++i) {
            assertLt(results[i], results[0] * 10, "variance exploded with grid density");
            assertGt(results[i] * 10, results[0], "variance collapsed with grid density");
        }
    }

    // ---------------------------------------------------------------------
    // Guards, against a real pool
    // ---------------------------------------------------------------------

    function test_validateSource_acceptsDeepPoolForShortWindow() public onFork {
        observer.validateSource(POOL, 6 hours, 24);
    }

    /// @notice A window longer than the buffer must be refused at creation, not at settlement.
    function test_validateSource_rejectsWindowBeyondBuffer() public onFork {
        uint32 available = observer.maxLookback(POOL);
        vm.expectRevert();
        observer.validateSource(POOL, available + 2 hours, 24);
    }

    /// @notice What it costs to buy more history.
    ///
    /// @dev The protocol treats extending a pool's buffer as its own responsibility, so the
    ///      price of doing so is an operating cost, not a curiosity. `increaseObservation-
    ///      CardinalityNext` writes one slot per added entry, and slots are only paid for once,
    ///      but the payer is whoever calls it — here, us.
    ///
    ///      This measures the marginal cost of adding 1000 slots to a pool that already has
    ///      5000. The result feeds the operating-cost line in the economics, which was
    ///      previously unknown.
    function test_costOfExtendingTheBuffer() public onFork {
        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(POOL).slot0();

        uint256 before = gasleft();
        IUniswapV3PoolOracle(POOL).increaseObservationCardinalityNext(cardinality + 1000);
        uint256 used = before - gasleft();

        console2.log("cardinality before      ", cardinality);
        console2.log("gas for +1000 slots     ", used);
        console2.log("gas per slot            ", used / 1000);

        // Each new slot is a fresh SSTORE, so ~20k each is the floor. Anything wildly below
        // that would mean the call silently did nothing.
        assertGt(used, 1000 * 15_000, "extension was suspiciously cheap - did it apply?");
    }

    // ---------------------------------------------------------------------

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

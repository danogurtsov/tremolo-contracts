// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {IUniswapV3PoolOracle} from "../../src/interfaces/IUniswapV3PoolOracle.sol";
import {VarianceMath} from "../../src/libraries/VarianceMath.sol";
import {Variance} from "../../src/types/Variance.sol";

interface IUniswapV3Pool is IUniswapV3PoolOracle {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice What it costs to move realized variance, measured by actually moving it.
///
/// @dev The protocol's central security claim is that settling on a time-weighted average makes
///      manipulation expensive. That claim was asserted in three documents and never priced.
///      This prices it: real swaps, against the real pool, at real depth, on a fork.
///
///      The attack modelled is the profitable one. A long position gains when realized variance
///      comes in high, and variance is a sum of squared log returns — so the attacker does not
///      need to move the price anywhere in particular, only to move it *back and forth*. Every
///      round trip adds to the sum. That is strictly cheaper than a directional attack and is
///      what a manipulation budget would actually buy.
///
///      Two things make it expensive anyway, and the numbers below say by how much:
///
///        - each round trip pays the pool fee twice, plus whatever the price impact costs;
///        - the series samples a TWAP, so a spike that is immediately reversed barely moves the
///          average it lands in. Buying variance means holding the price away, not touching it.
contract ManipulationCostForkTest is Test {
    address internal constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    uint256 internal constant FORK_BLOCK = 49_000_000;

    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    Swapper internal swapper;
    UniV3Observer internal observer;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        try vm.createSelectFork(rpc, FORK_BLOCK) {
            forked = true;
        } catch {
            return;
        }
        swapper = new Swapper(POOL);
        observer = new UniV3Observer();
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Price impact per dollar, on the pool this protocol reads.
    /// @dev The input to every other number here. Depth is what makes manipulation expensive, so
    ///      it is worth stating in units anyone can check rather than as "the pool is deep".
    function test_priceImpactOfSize() public onFork {
        uint256[4] memory sizes = [uint256(10_000e6), 100_000e6, 1_000_000e6, 5_000_000e6];

        console2.log("pool liquidity", IUniswapV3Pool(POOL).liquidity());
        console2.log("");
        console2.log("USDC in        ticks moved   round-trip cost (USDC)");

        for (uint256 i = 0; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();

            (, int24 tickBefore,,,,,) = IUniswapV3Pool(POOL).slot0();
            uint256 spent = swapper.roundTrip(USDC, sizes[i]);
            (, int24 tickAfter,,,,,) = IUniswapV3Pool(POOL).slot0();

            // Measured mid-trip: the tick after buying, before selling back.
            int24 peak = swapper.lastPeakTick();
            console2.log(sizes[i] / 1e6, uint256(int256(peak - tickBefore)), spent / 1e6);
            tickAfter; // silence unused warning; the round trip returns near where it started

            vm.revertToState(snap);
        }
    }

    /// @notice A spike that is immediately reversed barely registers in the settled series.
    ///
    /// @dev The core of the design, priced. The attacker buys, the price jumps, the attacker
    ///      sells back — and the TWAP for the interval in which all of that happened moves by
    ///      almost nothing, because the average is over the whole interval and the excursion
    ///      lasted one block.
    ///
    ///      This is the difference between settling on a spot print and settling on an average.
    ///      Against a spot print, the same trade would land the full excursion in the series.
    function test_flashSpikeBarelyMovesTheAverage() public onFork {
        uint32 window = 6 hours;
        uint16 samples = 24;

        int256[] memory clean = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        Variance rvClean = VarianceMath.fromTicks(clean, window);

        (, int24 tickBefore,,,,,) = IUniswapV3Pool(POOL).slot0();
        uint256 spent = swapper.roundTrip(USDC, 1_000_000e6);
        int24 peak = swapper.lastPeakTick();

        // Move one block forward so the pool records an observation covering the excursion.
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        swapper.poke(USDC, 1e6);

        int256[] memory dirty = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        Variance rvDirty = VarianceMath.fromTicks(dirty, window);

        console2.log("spent (USDC)          ", spent / 1e6);
        console2.log("ticks moved at peak   ", uint256(int256(peak - tickBefore)));
        console2.log("variance clean (wad)  ", Variance.unwrap(rvClean));
        console2.log("variance dirty (wad)  ", Variance.unwrap(rvDirty));

        uint256 clean_ = Variance.unwrap(rvClean);
        uint256 dirty_ = Variance.unwrap(rvDirty);
        uint256 deltaBps = clean_ == 0 ? 0 : (dirty_ > clean_ ? (dirty_ - clean_) * 10_000 / clean_ : 0);
        console2.log("variance change (bps) ", deltaBps);

        // A million dollars through the deepest ETH pool on the chain, and the settled number
        // moves by a fraction of a percent. That is the property, in one assertion.
        assertLt(deltaBps, 500, "a reversed spike moved the settled variance by over 5%");
    }

    /// @notice The attack that does work: hold the price away, do not just touch it.
    ///
    /// @dev The flash spike fails because a TWAP over fifteen minutes barely notices two seconds
    ///      of excursion. The way to move a time-weighted average is to weight it — push the
    ///      price and keep it there for a meaningful share of the interval.
    ///
    ///      This holds it for five minutes of a fifteen-minute step, which is a third of the
    ///      interval, and measures what the settled variance does.
    ///
    ///      **The number this produces is a lower bound on the real cost, and by a wide margin.**
    ///      On a fork there are no arbitrageurs: the price stays where it is put, for free, for
    ///      as long as wanted. On a live chain, holding a 6% dislocation on the deepest ETH pool
    ///      for five minutes means absorbing every arbitrage trade aimed at it for five minutes.
    ///      What is measured here is the entry fee, not the bill.
    function test_sustainedHoldMovesTheAverage() public onFork {
        uint32 window = 6 hours;
        uint16 samples = 24; // fifteen-minute steps

        int256[] memory clean = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        uint256 rvClean = Variance.unwrap(VarianceMath.fromTicks(clean, window));

        (, int24 tickBefore,,,,,) = IUniswapV3Pool(POOL).slot0();

        // Push, and leave it pushed.
        uint256 spent = swapper.pushOnly(USDC, 1_000_000e6);
        (, int24 tickHeld,,,,,) = IUniswapV3Pool(POOL).slot0();

        // Five minutes of blocks, poking the pool so observations record the held price.
        for (uint256 i = 0; i < 10; ++i) {
            vm.roll(block.number + 15);
            vm.warp(block.timestamp + 30);
            swapper.poke(USDC, 1e6);
        }

        int256[] memory dirty = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        uint256 rvDirty = Variance.unwrap(VarianceMath.fromTicks(dirty, window));

        console2.log("spent to push (USDC)  ", spent / 1e6);
        console2.log("ticks held away       ", uint256(int256(tickHeld - tickBefore)));
        console2.log("variance clean (wad)  ", rvClean);
        console2.log("variance held  (wad)  ", rvDirty);

        if (rvDirty > rvClean) {
            uint256 gain = rvDirty - rvClean;
            console2.log("variance gained (wad) ", gain);
            console2.log("gain (bps of clean)   ", gain * 10_000 / rvClean);
            console2.log("break-even notional   ", (spent * 1e18 / gain) / 1e6);
        } else {
            console2.log("holding the price still did not raise the settled variance");
        }
    }

    /// @notice What a manipulator would have to spend to matter, against what they could win.
    ///
    /// @dev The verdict, in the only terms that count. A long position of notional N gains
    ///      `N * dRV` from an increase in realized variance. The attack costs fees plus impact,
    ///      per round trip, and has to be repeated in every grid interval it wants to affect.
    ///
    ///      Reported as a ratio so it does not depend on assuming a position size.
    function test_attackBudgetAgainstPayoff() public onFork {
        uint32 window = 6 hours;
        uint16 samples = 24;
        uint256 size = 1_000_000e6;

        int256[] memory clean = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        uint256 rvClean = Variance.unwrap(VarianceMath.fromTicks(clean, window));

        uint256 spentPerTrip = swapper.roundTrip(USDC, size);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        swapper.poke(USDC, 1e6);

        int256[] memory dirty = observer.sampleSeries(POOL, uint32(block.timestamp), window, samples);
        uint256 rvDirty = Variance.unwrap(VarianceMath.fromTicks(dirty, window));
        uint256 gain = rvDirty > rvClean ? rvDirty - rvClean : 0;

        console2.log("cost of one round trip (USDC)", spentPerTrip / 1e6);
        console2.log("variance gained (wad)        ", gain);

        if (gain == 0) {
            console2.log("notional needed to break even: unbounded - the attack gained nothing");
            return;
        }

        // Break-even notional: the position size at which `notional * gain` covers the spend.
        uint256 breakEven = spentPerTrip * 1e18 / gain;
        console2.log("break-even notional (USDC)   ", breakEven / 1e6);
        console2.log("  ... per grid interval attacked, and there are", samples);

        // Against a pool this deep, the position required to justify one round trip is far
        // larger than any series this protocol would write - which is the argument for a cap on
        // series size relative to source depth, not a proof that manipulation is impossible.
        assertGt(breakEven, size, "one round trip paid for itself against a smaller position");
    }
}

/// @notice Executes real swaps against a real pool, funding itself with `deal`.
/// @dev A router would add its own fees and slippage checks and make the measurement about the
///      router. Calling the pool directly measures the pool.
contract Swapper is Test {
    IUniswapV3Pool public immutable pool;
    address public immutable token0;
    address public immutable token1;

    int24 public lastPeakTick;

    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    constructor(address pool_) {
        pool = IUniswapV3Pool(pool_);
        token0 = IUniswapV3Pool(pool_).token0();
        token1 = IUniswapV3Pool(pool_).token1();
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "unexpected caller");
        if (amount0Delta > 0) {
            deal(token0, address(this), uint256(amount0Delta));
            IERC20(token0).transfer(address(pool), uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            deal(token1, address(this), uint256(amount1Delta));
            IERC20(token1).transfer(address(pool), uint256(amount1Delta));
        }
    }

    /// @notice Buy then sell back the same position, returning what the round trip cost.
    /// @dev Cost is the quote-token shortfall: what went in minus what came back. That is fees
    ///      plus price impact, which is exactly the manipulator's bill.
    function roundTrip(address quoteToken, uint256 amountIn) external returns (uint256 cost) {
        bool quoteIsToken0 = quoteToken == token0;

        deal(quoteToken, address(this), amountIn);
        uint256 before = IERC20(quoteToken).balanceOf(address(this));

        // Leg one: spend the quote token.
        (int256 a0, int256 a1) = pool.swap(
            address(this), quoteIsToken0, int256(amountIn), quoteIsToken0 ? MIN_SQRT + 1 : MAX_SQRT - 1, ""
        );
        (, lastPeakTick,,,,,) = pool.slot0();

        // Leg two: sell everything received back.
        int256 received = quoteIsToken0 ? -a1 : -a0;
        pool.swap(address(this), !quoteIsToken0, received, quoteIsToken0 ? MAX_SQRT - 1 : MIN_SQRT + 1, "");

        uint256 remaining = IERC20(quoteToken).balanceOf(address(this));
        cost = before > remaining ? before - remaining : 0;
    }

    /// @notice Swap one way and stay there, returning what was spent.
    /// @dev Unlike `roundTrip`, this leaves the pool dislocated. On a fork nobody arbitrages it
    ///      back, which is precisely why the resulting cost figure is a lower bound.
    function pushOnly(address quoteToken, uint256 amountIn) external returns (uint256 spent) {
        bool quoteIsToken0 = quoteToken == token0;
        deal(quoteToken, address(this), amountIn);

        pool.swap(
            address(this), quoteIsToken0, int256(amountIn), quoteIsToken0 ? MIN_SQRT + 1 : MAX_SQRT - 1, ""
        );
        (, lastPeakTick,,,,,) = pool.slot0();
        return amountIn;
    }

    /// @notice A trivial swap, purely to make the pool write an observation.
    function poke(address quoteToken, uint256 amountIn) external {
        bool quoteIsToken0 = quoteToken == token0;
        deal(quoteToken, address(this), amountIn);
        pool.swap(
            address(this), quoteIsToken0, int256(amountIn), quoteIsToken0 ? MIN_SQRT + 1 : MAX_SQRT - 1, ""
        );
    }
}

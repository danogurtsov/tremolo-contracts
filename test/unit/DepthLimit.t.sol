// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice The cap that keeps a series small enough that manipulating its source cannot pay.
///
/// @dev Derived from measurement, not from caution. On the live WETH/USDC pool, holding the price
///      6% away for a third of a grid step multiplies settled variance by 15.7x and breaks even
///      against a long position above roughly $1.5M — where a 1% move costs about $161k. Since
///      the break-even is a ratio, the cap is a ratio: notional may not exceed the cost of moving
///      the source 1%.
contract DepthLimitTest is Test {
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev depthQuote for the mock's defaults, which mirror the live pool: ~$254k.
    uint256 internal expectedDepth;

    function setUp() public {
        vm.warp(1_800_000_000);
        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));
        pool.setTokens(address(weth), address(usdc)); // price is USDC per WETH

        expectedDepth = observer.depthQuote(address(pool));

        usdc.mint(alice, 100_000_000e6);
        usdc.mint(bob, 100_000_000e6);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
    }

    function _create(address collateral, uint256 notionalPerUnit) internal returns (uint256) {
        return market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(pool),
                collateral: collateral,
                startTime: uint64(block.timestamp + 1 hours),
                expiry: uint64(block.timestamp + 1 hours + 1 days),
                samples: 24,
                minCompletenessBps: 8000,
                capMultiple: 2.5e18,
                strike: Variance.wrap(0.04e18),
                notionalPerUnit: notionalPerUnit
            })
        );
    }

    /// @notice The depth figure is in the right units and of the right size.
    /// @dev Cross-checked against real swaps: the fork test moves the live pool 1% for roughly
    ///      $161k, and this estimate says $254k. Same order, and erring high — the estimate
    ///      assumes liquidity holds constant across the move, which in a concentrated pool it
    ///      does not, so the derived cap is tighter than strictly required.
    function test_depthQuote_isPlausibleAndInQuoteUnits() public view {
        console2.log("depthQuote (USDC)", expectedDepth / 1e6);
        assertGt(expectedDepth, 100_000e6, "depth implausibly small for a pool this size");
        assertLt(expectedDepth, 1_000_000e6, "depth implausibly large");
    }

    /// @notice A series may grow up to the depth limit and not past it.
    function test_subscribe_stopsAtTheLimit() public {
        // 1000 USDC of notional per unit, so `units` maps to notional directly.
        uint256 id = _create(address(usdc), 1000e6);
        uint256 maxUnits = expectedDepth * 1e18 / 1000e6;

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, maxUnits);

        vm.prank(alice);
        vm.expectRevert();
        market.subscribe(id, IVarianceMarket.Side.LONG, 1e18);
    }

    /// @notice The cap binds on aggregate size, not on a single subscription.
    /// @dev Otherwise it would be trivially defeated by subscribing many times.
    function test_subscribe_capIsAggregateNotPerCall() public {
        uint256 id = _create(address(usdc), 1000e6);
        uint256 halfMax = (expectedDepth * 1e18 / 1000e6) / 2;

        vm.startPrank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, halfMax);
        market.subscribe(id, IVarianceMarket.Side.LONG, halfMax);

        // Two halves fit; a third does not.
        vm.expectRevert();
        market.subscribe(id, IVarianceMarket.Side.LONG, halfMax);
        vm.stopPrank();
    }

    /// @notice A thin source supports a proportionally smaller series.
    /// @dev The point of expressing the cap as a ratio: it follows the source rather than being
    ///      a number someone picked once.
    function test_thinPoolGetsASmallerCap() public {
        pool.setLiquidity(uint128(pool.liquidity() / 100));
        uint256 thinDepth = observer.depthQuote(address(pool));

        assertApproxEqRel(thinDepth, expectedDepth / 100, 0.01e18, "cap did not scale with depth");

        uint256 id = _create(address(usdc), 1000e6);
        uint256 tooMuch = (expectedDepth * 1e18 / 1000e6) / 2; // fine on the deep pool

        vm.prank(alice);
        vm.expectRevert();
        market.subscribe(id, IVarianceMarket.Side.LONG, tooMuch);
    }

    /// @notice Collateral must be the token the source quotes in.
    ///
    /// @dev The hole this closes: without it, a series could sidestep the cap by denominating
    ///      itself in an unrelated token, since comparing $254k of pool depth against 100 units
    ///      of some 18-decimal token compares nothing at all. Found while wiring the cap up —
    ///      every existing test passed, because every mock quoted in a token nobody used.
    function test_createSeries_rejectsCollateralThatIsNotTheQuoteToken() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        vm.expectRevert(
            abi.encodeWithSelector(
                IVarianceMarket.CollateralNotQuoteToken.selector, address(dai), address(usdc)
            )
        );
        _create(address(dai), 1000e18);
    }

    /// @notice A source with no on-chain depth is exempt, and says so rather than reporting zero.
    /// @dev A push feed cannot be moved by trading against it, so sizing is not the defence
    ///      there. Reporting zero depth would instead ban every series on such a source.
    function test_sourceWithoutDepthIsExempt() public {
        MockUniV3Pool noTokens = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));
        // token0/token1 left unset, so quoteToken is address(0)

        uint256 id = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(noTokens),
                collateral: address(usdc),
                startTime: uint64(block.timestamp + 1 hours),
                expiry: uint64(block.timestamp + 1 hours + 1 days),
                samples: 24,
                minCompletenessBps: 8000,
                capMultiple: 2.5e18,
                strike: Variance.wrap(0.04e18),
                notionalPerUnit: 1000e6
            })
        );

        // 500k USDC of notional: comfortably past the ~254k the depth limit would allow on a
        // source that reported one, and accepted here because this source does not.
        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, 500_000e18);
    }

    /// @notice The cap applies to immediate opens too, not only to subscriptions.
    /// @dev Otherwise RFQ would be the way around it.
    function test_openImmediate_respectsTheLimit() public {
        uint256 tooMuch = (expectedDepth * 1e18 / 1000e6) * 2;

        vm.expectRevert();
        market.openImmediate(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(pool),
                collateral: address(usdc),
                startTime: 0,
                expiry: uint64(block.timestamp + 1 days),
                samples: 24,
                minCompletenessBps: 8000,
                capMultiple: 2.5e18,
                strike: Variance.wrap(0.04e18),
                notionalPerUnit: 1000e6
            }),
            alice,
            bob,
            tooMuch
        );
    }
}

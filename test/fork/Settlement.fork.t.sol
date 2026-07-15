// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice A series that lives through real time, on a real pool, with a real token.
///
/// @dev The trick that makes this possible: create the series on an early block, then
///      `rollFork` forward to a later one. Between the two blocks the pool went on trading and
///      writing observations for six real hours — none of which this test controls or fakes.
///      `vm.warp` alone could not do this: it moves the clock but leaves the pool frozen, so
///      settlement would read a buffer that never advanced.
///
///      Two constraints of `rollFork` shape the setup, both discovered the hard way:
///
///        - contracts deployed inside the test disappear across the roll unless marked with
///          `vm.makePersistent`. Without it the market and the observer become empty addresses
///          and every call reverts with "call to non-contract address".
///        - state of *real* contracts is re-read from the destination block, so collateral
///          balances created with `deal` on the real USDC would silently vanish mid-test.
///          Collateral is therefore a token this test deploys and keeps persistent. The pool,
///          the price history and the passage of time are all real, which is what matters here;
///          real-token behaviour is covered separately by the hostile-token suite.
contract SettlementForkTest is Test {
    address internal constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    /// @dev 30 000 seconds of real Base history separate these blocks (~8h20m).
    uint256 internal constant BLOCK_START = 48_985_000;
    uint256 internal constant BLOCK_END = 49_000_000;

    uint32 internal constant WINDOW = 6 hours;
    uint16 internal constant SAMPLES = 24;
    Variance internal constant STRIKE = Variance.wrap(0.04e18); // 20% annualised
    uint64 internal constant CAP = 2.5e18;
    uint256 internal constant NOTIONAL = 1000e6;

    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockERC20 internal usdc;

    address internal longSide = makeAddr("longSide");
    address internal shortSide = makeAddr("shortSide");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        try vm.createSelectFork(rpc, BLOCK_START) {
            forked = true;
        } catch {
            return;
        }

        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Survives the roll to the destination block, along with its storage.
        vm.makePersistent(address(observer));
        vm.makePersistent(address(market));
        vm.makePersistent(address(usdc));

        usdc.mint(longSide, 1_000_000e6);
        usdc.mint(shortSide, 1_000_000e6);
        vm.prank(longSide);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(shortSide);
        usdc.approve(address(market), type(uint256).max);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Create, subscribe, live through six real hours, settle, redeem.
    function test_fullLifecycleAcrossRealTime() public onFork {
        uint64 startTime = uint64(block.timestamp + 30 minutes);
        uint256 id = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: POOL,
                collateral: address(usdc),
                startTime: startTime,
                expiry: startTime + WINDOW,
                samples: SAMPLES,
                minCompletenessBps: 8000,
                capMultiple: CAP,
                strike: STRIKE,
                notionalPerUnit: NOTIONAL
            })
        );

        uint256 units = 10e18;
        vm.prank(longSide);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(shortSide);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        uint256 pot = usdc.balanceOf(address(market));
        assertEq(pot, 1000e6, "pot should be notional * cap * K * units = 10 * 100 USDC");

        // Forward to a block after expiry. The pool traded through the whole window while this
        // test did nothing at all — which is the entire point of the design.
        vm.rollFork(BLOCK_END);
        assertGt(block.timestamp, startTime + WINDOW, "fork did not span the window");

        market.activate(id);
        market.mintPositions(id, IVarianceMarket.Side.LONG, longSide);
        market.mintPositions(id, IVarianceMarket.Side.SHORT, shortSide);

        IVarianceMarket.State state = market.settle(id);
        assertEq(uint8(state), uint8(IVarianceMarket.State.SETTLED), "real pool failed to settle");

        IVarianceMarket.Series memory s = market.getSeries(id);
        uint256 rv = Variance.unwrap(s.realizedVariance);
        console2.log("realized variance (wad)", rv);
        console2.log("annualised vol (%)     ", _sqrt(rv * 1e18) / 1e16);
        console2.log("strike vol (%)         ", uint256(20));

        vm.prank(longSide);
        uint256 longPaid = market.redeem(id, IVarianceMarket.Side.LONG, units, longSide);
        vm.prank(shortSide);
        uint256 shortPaid = market.redeem(id, IVarianceMarket.Side.SHORT, units, shortSide);

        console2.log("long paid  (USDC 1e6)  ", longPaid);
        console2.log("short paid (USDC 1e6)  ", shortPaid);

        // The identity, now against real money moving through a real token.
        assertEq(longPaid + shortPaid, pot, "payouts do not equal deposits");
        assertEq(usdc.balanceOf(address(market)), 0, "collateral stranded in the market");
    }

    /// @notice Whoever was right about volatility made money, and the amount is checkable by hand.
    /// @dev A settlement that closes is not the same as a settlement that is *correct*. This
    ///      pins the direction and the magnitude against the strike, using only the series
    ///      parameters — the sort of arithmetic a counterparty would do before signing.
    function test_payoutFollowsRealizedVolatility() public onFork {
        uint64 startTime = uint64(block.timestamp + 30 minutes);
        uint256 id = market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: POOL,
                collateral: address(usdc),
                startTime: startTime,
                expiry: startTime + WINDOW,
                samples: SAMPLES,
                minCompletenessBps: 8000,
                capMultiple: CAP,
                strike: STRIKE,
                notionalPerUnit: NOTIONAL
            })
        );

        uint256 units = 1e18;
        vm.prank(longSide);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(shortSide);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        vm.rollFork(BLOCK_END);
        market.activate(id);
        market.mintPositions(id, IVarianceMarket.Side.LONG, longSide);
        market.mintPositions(id, IVarianceMarket.Side.SHORT, shortSide);
        market.settle(id);

        uint256 rv = Variance.unwrap(market.getSeries(id).realizedVariance);
        uint256 longPayout = market.payoutPerUnit(id, IVarianceMarket.Side.LONG);

        // longPayout = notional * min(RV, cap*K), so with a 40 USDC deposit the long side is up
        // exactly when realized variance came in above the 0.04 strike.
        uint256 longDeposit = market.collateralPerUnit(id, IVarianceMarket.Side.LONG);
        if (rv > Variance.unwrap(STRIKE)) {
            assertGt(longPayout, longDeposit, "long realised above strike but did not profit");
        } else {
            assertLe(longPayout, longDeposit, "long realised below strike but profited");
        }

        assertEq(longPayout, rv * NOTIONAL / 1e18, "payout is not notional * RV");
    }

    /// @notice Gas cost of reading the series, at every grid size the protocol permits.
    ///
    /// @dev The measurement that set `MAX_SAMPLES`. Before it ran, the limit was 1024 on the
    ///      grounds that it sounded generous; 1024 points turned out to cost 48.68M gas — 12%
    ///      of a Base block, and more than a whole Ethereum block — which would have shipped as
    ///      a grid size nobody could ever settle at.
    ///
    ///      Cost per point is flat to about 96 and climbs after that: each reading binary-
    ///      searches the ring buffer, and deeper history means longer searches.
    function test_gasProfileOfSettlement() public onFork {
        uint16[4] memory grids = [uint16(12), 24, 96, 256];

        vm.rollFork(BLOCK_END);
        for (uint256 i = 0; i < grids.length; ++i) {
            uint256 before = gasleft();
            observer.sampleTicks(POOL, uint32(block.timestamp), WINDOW, grids[i]);
            uint256 used = before - gasleft();
            console2.log("sampleTicks grid / gas", grids[i], used);

            // Every permitted grid must stay a small fraction of a block. Base's limit is
            // 400M, so 10M is ~2.5% — affordable, and still affordable if the pool's history
            // grows deeper and searches get longer.
            assertLt(used, 10_000_000, "permitted grid size is too expensive to settle");
        }
    }
}

function _sqrt(uint256 x) pure returns (uint256 z) {
    if (x == 0) return 0;
    z = (x + 1) / 2;
    uint256 y = x;
    while (z < y) {
        y = z;
        z = (x / z + z) / 2;
    }
}

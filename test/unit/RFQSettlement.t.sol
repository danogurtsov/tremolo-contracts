// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RFQSettlement} from "../../src/RFQSettlement.sol";
import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice Trades opened against signed quotes: pricing, partial fills, and every way to abuse them.
contract RFQSettlementTest is Test {
    RFQSettlement internal rfq;
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;
    MockERC20 internal usdc;

    uint256 internal makerKey = 0xA11CE;
    address internal maker;
    address internal taker = makeAddr("taker");

    function setUp() public {
        vm.warp(1_800_000_000);
        maker = vm.addr(makerKey);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));
        rfq = new RFQSettlement(market);
        market.setAuthorizedOpener(address(rfq), true);
        pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));

        usdc.mint(maker, 1_000_000e6);
        usdc.mint(taker, 1_000_000e6);
        vm.prank(maker);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(taker);
        usdc.approve(address(market), type(uint256).max);
    }

    function _quote(uint256 strike, uint256 maxUnits, uint256 nonce)
        internal
        view
        returns (RFQSettlement.Quote memory)
    {
        return RFQSettlement.Quote({
            maker: maker,
            makerIsLong: false, // maker sells variance, the usual direction
            observer: address(observer),
            source: address(pool),
            collateral: address(usdc),
            windowSeconds: 1 days,
            samples: 24,
            minCompletenessBps: 8000,
            capMultiple: 2.5e18,
            strike: strike,
            notionalPerUnit: 1000e6,
            maxUnits: maxUnits,
            deadline: block.timestamp + 10 minutes,
            nonce: nonce
        });
    }

    function _sign(RFQSettlement.Quote memory q) internal view returns (bytes memory) {
        RFQSettlement.Quote[] memory arr = new RFQSettlement.Quote[](1);
        arr[0] = q;
        bytes32 digest = this.hashOf(arr);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Calldata trampoline: `hashQuote` takes `calldata`, and tests build quotes in memory.
    function hashOf(RFQSettlement.Quote[] calldata arr) external view returns (bytes32) {
        return rfq.hashQuote(arr[0]);
    }

    // ---------------------------------------------------------------------
    // The thing it exists for
    // ---------------------------------------------------------------------

    /// @notice A filled quote opens a fully collateralised, already-active series.
    /// @dev The strike came from the maker rather than from whoever created the series, and the
    ///      trade opened on demand rather than inside a subscription window. Those are the two
    ///      things the subscription flow could not do.
    function test_fill_opensActiveSeriesAtQuotedStrike() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 10e18, 1);
        bytes memory sig = _sign(q);

        vm.prank(taker);
        uint256 id = rfq.fill(q, sig, 10e18);

        IVarianceMarket.Series memory s = market.getSeries(id);
        assertEq(uint8(s.state), uint8(IVarianceMarket.State.ACTIVE), "series should be live at once");
        assertEq(Variance.unwrap(s.strike), 0.05e18, "strike must be the quoted one");
        assertEq(s.startTime, block.timestamp, "measurement starts now");
        assertEq(s.matchedUnits, 10e18);

        // Maker is short, taker is long, and both legs are collateralised.
        assertEq(market.balanceOf(maker, market.tokenId(id, IVarianceMarket.Side.SHORT)), 10e18);
        assertEq(market.balanceOf(taker, market.tokenId(id, IVarianceMarket.Side.LONG)), 10e18);
        assertEq(usdc.balanceOf(address(market)), market.totalCollateralPerUnit(id) * 10);
    }

    /// @notice Two quotes at different strikes produce two different instruments.
    /// @dev Price discovery in one test: the same market, the same window, two prices, and the
    ///      contract does not care which is "right".
    function test_fill_differentStrikesAreDifferentSeries() public {
        RFQSettlement.Quote memory cheap = _quote(0.03e18, 5e18, 1);
        RFQSettlement.Quote memory rich = _quote(0.09e18, 5e18, 2);

        bytes memory cheapSig = _sign(cheap);
        bytes memory richSig = _sign(rich);

        vm.startPrank(taker);
        uint256 a = rfq.fill(cheap, cheapSig, 5e18);
        uint256 b = rfq.fill(rich, richSig, 5e18);
        vm.stopPrank();

        assertTrue(a != b);
        assertEq(Variance.unwrap(market.getSeries(a).strike), 0.03e18);
        assertEq(Variance.unwrap(market.getSeries(b).strike), 0.09e18);
        // Same size, higher strike, so more collateral behind the richer series.
        assertLt(market.totalCollateralPerUnit(a), market.totalCollateralPerUnit(b));
    }

    /// @notice A maker can take the long side just as easily.
    function test_fill_makerCanBeLong() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 4e18, 1);
        q.makerIsLong = true;
        bytes memory sig = _sign(q);

        vm.prank(taker);
        uint256 id = rfq.fill(q, sig, 4e18);

        assertEq(market.balanceOf(maker, market.tokenId(id, IVarianceMarket.Side.LONG)), 4e18);
        assertEq(market.balanceOf(taker, market.tokenId(id, IVarianceMarket.Side.SHORT)), 4e18);
    }

    // ---------------------------------------------------------------------
    // Partial fills
    // ---------------------------------------------------------------------

    function test_fill_partialThenRest() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 10e18, 1);
        bytes memory sig = _sign(q);

        vm.prank(taker);
        rfq.fill(q, sig, 4e18);
        assertEq(this.remainingOf(_wrap(q)), 6e18, "remaining after partial fill");

        vm.prank(taker);
        rfq.fill(q, sig, 6e18);
        assertEq(this.remainingOf(_wrap(q)), 0);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(RFQSettlement.ExceedsRemaining.selector, 1e18, 0));
        rfq.fill(q, sig, 1e18);
    }

    function test_fill_cannotExceedQuotedSize() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 3e18, 1);
        bytes memory sig = _sign(q);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(RFQSettlement.ExceedsRemaining.selector, 4e18, 3e18));
        rfq.fill(q, sig, 4e18);
    }

    // ---------------------------------------------------------------------
    // Abuse
    // ---------------------------------------------------------------------

    /// @notice A quote past its deadline is dead, signature or not.
    function test_fill_rejectsExpiredQuote() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 1);
        bytes memory sig = _sign(q);

        vm.warp(q.deadline + 1);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(RFQSettlement.QuoteExpired.selector, q.deadline));
        rfq.fill(q, sig, 1e18);
    }

    /// @notice A cancelled nonce kills every quote carrying it.
    function test_cancel_killsQuote() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 7);
        bytes memory sig = _sign(q);

        vm.prank(maker);
        rfq.cancel(7);

        vm.prank(taker);
        vm.expectRevert(RFQSettlement.QuoteCancelledError.selector);
        rfq.fill(q, sig, 1e18);
    }

    /// @notice A signature over different terms does not authorise these terms.
    /// @dev The whole security model: the maker committed to a strike, and a taker who edits the
    ///      strike after the fact is presenting a signature over something else.
    function test_fill_rejectsTamperedStrike() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 1);
        bytes memory sig = _sign(q);

        q.strike = 0.01e18; // far better for the taker
        vm.prank(taker);
        vm.expectRevert(RFQSettlement.BadSignature.selector);
        rfq.fill(q, sig, 1e18);
    }

    function test_fill_rejectsTamperedSize() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 1);
        bytes memory sig = _sign(q);

        q.maxUnits = 500e18;
        vm.prank(taker);
        vm.expectRevert(RFQSettlement.BadSignature.selector);
        rfq.fill(q, sig, 100e18);
    }

    /// @notice A signature from somebody else is not the maker's signature.
    function test_fill_rejectsForeignSignature() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, this.hashOf(_wrap(q)));

        vm.prank(taker);
        vm.expectRevert(RFQSettlement.BadSignature.selector);
        rfq.fill(q, abi.encodePacked(r, s, v), 1e18);
    }

    /// @notice The same quote cannot be replayed against a second RFQ deployment.
    /// @dev EIP-712 binds the domain separator to this contract's address, so a signature is not
    ///      portable to another instance — a live concern if the RFQ layer is ever redeployed.
    function test_fill_signatureIsNotPortableAcrossDeployments() public {
        RFQSettlement.Quote memory q = _quote(0.05e18, 5e18, 1);
        bytes memory sig = _sign(q);

        RFQSettlement other = new RFQSettlement(market);
        vm.prank(taker);
        vm.expectRevert(RFQSettlement.BadSignature.selector);
        other.fill(q, sig, 1e18);
    }

    // ---------------------------------------------------------------------
    // Exit
    // ---------------------------------------------------------------------

    /// @notice A maker who ends up holding both legs can net out completely.
    /// @dev The exit path the design promised and could not previously deliver: without a way to
    ///      open offsetting trades on demand, nobody could take the other leg off a seller's
    ///      hands, so `net` had nothing to work with.
    function test_makerCanNetOutOfPosition() public {
        RFQSettlement.Quote memory sell = _quote(0.05e18, 5e18, 1);
        // Signed before the prank: `_sign` makes an external call to hash the quote, and that
        // call would consume the prank, leaving `fill` to run as the test contract.
        bytes memory sig = _sign(sell);

        vm.prank(taker);
        uint256 id = rfq.fill(sell, sig, 5e18);

        // The taker later wants out and sells the long leg back to the maker. Token id resolved
        // first: an external call inside an argument consumes the prank.
        uint256 longId = market.tokenId(id, IVarianceMarket.Side.LONG);
        vm.prank(taker);
        market.transfer(maker, longId, 5e18);

        uint256 before = usdc.balanceOf(maker);
        vm.prank(maker);
        uint256 released = market.net(id, 5e18);

        assertEq(released, market.totalCollateralPerUnit(id) * 5, "full collateral released");
        assertEq(usdc.balanceOf(maker), before + released);
        assertEq(usdc.balanceOf(address(market)), 0, "series fully unwound");
    }

    // ---------------------------------------------------------------------

    function remainingOf(RFQSettlement.Quote[] calldata arr) external view returns (uint256) {
        return rfq.remaining(arr[0]);
    }

    function _wrap(RFQSettlement.Quote memory q) internal pure returns (RFQSettlement.Quote[] memory arr) {
        arr = new RFQSettlement.Quote[](1);
        arr[0] = q;
    }
}

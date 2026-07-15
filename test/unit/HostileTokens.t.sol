// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {VarianceMarket} from "../../src/VarianceMarket.sol";
import {IVarianceMarket} from "../../src/interfaces/IVarianceMarket.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {
    NoReturnToken,
    FeeOnTransferToken,
    ReentrantToken,
    RevertOnZeroToken
} from "../../src/mocks/HostileTokens.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice How the market behaves against tokens that break ERC-20 assumptions.
///
/// @dev SECURITY.md used to state which tokens are unsupported. A statement nobody tests is a
///      wish, and the two most likely collateral choices in production — USDT and something
///      with a transfer fee — sit on opposite sides of that line. Each claim below is now
///      either enforced by the contract or proven to work.
contract HostileTokensTest is Test {
    VarianceMarket internal market;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    Variance internal constant STRIKE = Variance.wrap(0.04e18);
    uint64 internal constant CAP = 2.5e18;

    function setUp() public {
        vm.warp(1_800_000_000);
        observer = new UniV3Observer();
        market = new VarianceMarket(address(this));
        pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));
    }

    function _create(address collateral, uint256 notional) internal returns (uint256) {
        return market.createSeries(
            IVarianceMarket.SeriesParams({
                observer: address(observer),
                source: address(pool),
                collateral: collateral,
                startTime: uint64(block.timestamp + 1 hours),
                expiry: uint64(block.timestamp + 1 hours + 1 days),
                samples: 24,
                minCompletenessBps: 8000,
                capMultiple: CAP,
                strike: STRIKE,
                notionalPerUnit: notional
            })
        );
    }

    // ---------------------------------------------------------------------
    // Must work: USDT-style tokens
    // ---------------------------------------------------------------------

    /// @notice A token that returns nothing from `transfer` is fully supported.
    /// @dev USDT is the most likely collateral there is, and a naive `IERC20.transfer` reverts
    ///      against it — the compiler expects 32 bytes of returndata and gets none. This proves
    ///      SafeTransferLib is doing its job rather than assuming it.
    function test_noReturnToken_worksEndToEnd() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(alice, 1_000_000e6);
        usdt.mint(bob, 1_000_000e6);
        vm.prank(alice);
        usdt.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdt.approve(address(market), type(uint256).max);

        uint256 id = _create(address(usdt), 1000e6);
        uint256 units = 5e18;

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        assertEq(usdt.balanceOf(address(market)), 500e6, "pot should be 5 units * 100 USDT");

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);
        market.mintPositions(id, IVarianceMarket.Side.LONG, alice);
        market.mintPositions(id, IVarianceMarket.Side.SHORT, bob);

        // Settle flat: long loses its deposit, short takes the pot. Payment must still land.
        uint32 ts = uint32(s.startTime);
        while (ts <= s.expiry) {
            vm.warp(ts);
            pool.writeObservation(ts, 200_000);
            ts += 1 hours;
        }
        vm.warp(s.expiry);
        market.settle(id);

        vm.prank(bob);
        uint256 paid = market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);
        assertEq(paid, 500e6, "short should take the whole pot");
        assertEq(usdt.balanceOf(address(market)), 0, "collateral stranded");
    }

    /// @notice A token that reverts on zero-value transfers does not break redemption.
    /// @dev The losing side is owed exactly zero. A contract that blindly transfers would
    ///      revert here and trap the position permanently.
    function test_revertOnZeroToken_losingSideCanStillRedeem() public {
        RevertOnZeroToken roz = new RevertOnZeroToken();
        roz.mint(alice, 1000e18);
        roz.mint(bob, 1000e18);
        vm.prank(alice);
        roz.approve(address(market), type(uint256).max);
        vm.prank(bob);
        roz.approve(address(market), type(uint256).max);

        uint256 id = _create(address(roz), 100e18);
        uint256 units = 1e18;

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);
        market.mintPositions(id, IVarianceMarket.Side.LONG, alice);

        uint32 ts = uint32(s.startTime);
        while (ts <= s.expiry) {
            vm.warp(ts);
            pool.writeObservation(ts, 200_000);
            ts += 1 hours;
        }
        vm.warp(s.expiry);
        market.settle(id);

        // RV = 0, so the long side is owed nothing at all.
        vm.prank(alice);
        uint256 paid = market.redeem(id, IVarianceMarket.Side.LONG, units, alice);
        assertEq(paid, 0, "long should be owed nothing on a flat market");
    }

    // ---------------------------------------------------------------------
    // Must be rejected: fee-on-transfer
    // ---------------------------------------------------------------------

    /// @notice A fee-on-transfer token is refused at subscription, not quietly absorbed.
    /// @dev Crediting the smaller amount would be worse than reverting: the deposit is derived
    ///      from `units`, so a partial arrival leaves the series holding less than the position
    ///      it just sold requires. That is an under-collateralised series — the one outcome the
    ///      whole design claims is impossible.
    function test_feeOnTransferToken_isRejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken(100); // 1%
        fot.mint(alice, 1000e18);
        vm.prank(alice);
        fot.approve(address(market), type(uint256).max);

        uint256 id = _create(address(fot), 100e18);
        uint256 expected = market.collateralPerUnit(id, IVarianceMarket.Side.LONG);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVarianceMarket.CollateralShortfall.selector, expected, expected - expected / 100
            )
        );
        market.subscribe(id, IVarianceMarket.Side.LONG, 1e18);

        assertEq(fot.balanceOf(address(market)), 0, "no collateral should have been kept");
    }

    /// @notice The rejection holds for any fee, including a fee of one basis point.
    function testFuzz_feeOnTransferToken_isRejectedAtAnyFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 1, 5000);

        FeeOnTransferToken fot = new FeeOnTransferToken(feeBps);
        fot.mint(alice, 1_000_000e18);
        vm.prank(alice);
        fot.approve(address(market), type(uint256).max);

        uint256 id = _create(address(fot), 100e18);

        vm.prank(alice);
        vm.expectRevert();
        market.subscribe(id, IVarianceMarket.Side.LONG, 1e18);
    }

    // ---------------------------------------------------------------------
    // Must be contained: reentrancy
    // ---------------------------------------------------------------------

    /// @notice A token that calls back mid-transfer cannot re-enter the market.
    /// @dev ERC-777 and friends hand control to the recipient during a transfer. `nonReentrant`
    ///      is on the state-changing entry points, but an unexercised modifier is an assumption
    ///      rather than a property.
    function test_reentrantToken_cannotReenterSubscribe() public {
        ReentrantToken rent = new ReentrantToken();
        rent.mint(alice, 1000e18);
        vm.prank(alice);
        rent.approve(address(market), type(uint256).max);

        uint256 id = _create(address(rent), 100e18);

        // On the way through `subscribe`, call `subscribe` again.
        rent.setAttack(
            address(market), abi.encodeCall(market.subscribe, (id, IVarianceMarket.Side.LONG, 1e18))
        );

        vm.prank(alice);
        vm.expectRevert(); // Reentrancy() from the guard
        market.subscribe(id, IVarianceMarket.Side.LONG, 1e18);
    }

    /// @notice The same guard holds on the way out, during redemption.
    function test_reentrantToken_cannotReenterRedeem() public {
        ReentrantToken rent = new ReentrantToken();
        rent.mint(alice, 1000e18);
        rent.mint(bob, 1000e18);
        vm.prank(alice);
        rent.approve(address(market), type(uint256).max);
        vm.prank(bob);
        rent.approve(address(market), type(uint256).max);

        uint256 id = _create(address(rent), 100e18);
        uint256 units = 1e18;

        vm.prank(alice);
        market.subscribe(id, IVarianceMarket.Side.LONG, units);
        vm.prank(bob);
        market.subscribe(id, IVarianceMarket.Side.SHORT, units);

        IVarianceMarket.Series memory s = market.getSeries(id);
        vm.warp(s.startTime);
        market.activate(id);
        market.mintPositions(id, IVarianceMarket.Side.SHORT, bob);

        uint32 ts = uint32(s.startTime);
        while (ts <= s.expiry) {
            vm.warp(ts);
            pool.writeObservation(ts, 200_000);
            ts += 1 hours;
        }
        vm.warp(s.expiry);
        market.settle(id);

        // Redeem, and on the payout transfer try to redeem again.
        rent.setAttack(
            address(market), abi.encodeCall(market.redeem, (id, IVarianceMarket.Side.SHORT, units, bob))
        );

        vm.prank(bob);
        vm.expectRevert();
        market.redeem(id, IVarianceMarket.Side.SHORT, units, bob);
    }
}

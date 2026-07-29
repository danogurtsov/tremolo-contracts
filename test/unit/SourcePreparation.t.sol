// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {ChainlinkObserver} from "../../src/observers/ChainlinkObserver.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {IUniswapV3PoolOracle} from "../../src/interfaces/IUniswapV3PoolOracle.sol";

/// @notice Buying a source more memory before writing a series against it.
///
/// @dev The buffer paradox makes this operational rather than optional: the pools deep enough to
///      be worth writing series on are exactly the pools whose observation buffer is overwritten
///      fastest. A series that cannot be created because its source forgot too quickly is not a
///      limitation to work around, it is a bill to pay — $0.33 per thousand slots on Base.
contract SourcePreparationTest is Test {
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        observer = new UniV3Observer();
        pool = new MockUniV3Pool(200_000, 16, uint32(block.timestamp - 2 days));
    }

    /// @notice A shallow buffer blocks a series, and extending it unblocks the series.
    /// @dev The two halves belong in one test: the error is only actionable if the action works.
    function test_extendHistory_unblocksASeriesThatCouldNotBeCreated() public {
        // 24 grid points against a 16-slot buffer.
        vm.expectRevert(
            abi.encodeWithSelector(UniV3Observer.InsufficientCardinality.selector, uint16(16), uint16(24))
        );
        observer.validateSource(address(pool), 1 hours, 24);

        observer.extendHistory(address(pool), 64);

        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(address(pool)).slot0();
        assertEq(cardinality, 64, "extension did not take effect");

        observer.validateSource(address(pool), 1 hours, 24);
    }

    /// @notice Anyone may extend; there is nobody to ask.
    /// @dev Uniswap takes payment in gas from whoever calls and refuses to shrink, so there is
    ///      nothing to guard. Guarding it would only mean the protocol could be starved of
    ///      history by whoever held the permission.
    function test_extendHistory_isPermissionless() public {
        vm.prank(makeAddr("a stranger"));
        observer.extendHistory(address(pool), 128);

        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(address(pool)).slot0();
        assertEq(cardinality, 128);
    }

    /// @notice Asking for less than the source already has does nothing, and does not revert.
    /// @dev Uniswap ignores a smaller target. Reverting would make a race between two callers
    ///      extending the same pool fail for the slower one, for no reason.
    function test_extendHistory_shrinkingIsANoop() public {
        observer.extendHistory(address(pool), 64);
        observer.extendHistory(address(pool), 32);

        (,,, uint16 cardinality,,,) = IUniswapV3PoolOracle(address(pool)).slot0();
        assertEq(cardinality, 64, "a smaller target should have been ignored");
    }

    /// @notice A price feed cannot be asked for more history, and says so by doing nothing.
    /// @dev A feed's history is whatever its operators published. Reverting would push callers
    ///      into special-casing the adapter they are supposed to be abstracted from.
    function test_extendHistory_isANoopForFeeds() public {
        ChainlinkObserver link = new ChainlinkObserver();
        MockChainlinkFeed feed = new MockChainlinkFeed(8);
        feed.push(2500e8, block.timestamp);

        link.extendHistory(address(feed), 1000); // must not revert
    }
}

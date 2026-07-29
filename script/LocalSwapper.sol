// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes calldata data
    ) external returns (int256, int256);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Keeps a forked pool alive so it keeps writing observations.
///
/// @dev Nobody trades on a fork. Left alone the pool records nothing, and any series written
///      against it settles on an empty window and voids — which looks exactly like a protocol
///      bug and is not one. This makes the chain move.
///
///      Swaps are round trips: buy then sell the same size back. The pool records an observation
///      either way, while the price ends up roughly where it started, so seeded activity does not
///      quietly turn into a directional move that shows up as realized volatility that never
///      happened.
contract LocalSwapper {
    IPool public immutable pool;
    address public immutable token0;
    address public immutable token1;

    uint160 internal constant MIN_SQRT = 4_295_128_740;
    uint160 internal constant MAX_SQRT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    constructor(address pool_) {
        pool = IPool(pool_);
        token0 = IPool(pool_).token0();
        token1 = IPool(pool_).token1();
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata) external {
        require(msg.sender == address(pool), "bad caller");
        if (a0 > 0) IERC20(token0).transfer(address(pool), uint256(a0));
        if (a1 > 0) IERC20(token1).transfer(address(pool), uint256(a1));
    }

    /// @notice One round trip through the pool, funded by whoever calls it.
    /// @param quoteIn Size in token1 (the quote asset).
    function churn(uint256 quoteIn) external {
        IERC20(token1).transferFrom(msg.sender, address(this), quoteIn);

        (int256 a0,) = pool.swap(address(this), false, int256(quoteIn), MAX_SQRT - 1, "");
        pool.swap(address(this), true, -a0, MIN_SQRT + 1, "");

        uint256 left = IERC20(token1).balanceOf(address(this));
        if (left > 0) IERC20(token1).transfer(msg.sender, left);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of the Uniswap V3 pool interface this protocol depends on.
/// @dev Declared locally rather than pulled in as a dependency. v3-core is BUSL-1.1 and the
///      full interface is far larger than what is used here; an explicit narrow surface also
///      makes the dependency auditable at a glance.
interface IUniswapV3PoolOracle {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );

    /// @notice Returns cumulative tick and liquidity values at each of `secondsAgos`.
    /// @dev Values between recorded observations are interpolated linearly by the pool.
    ///      That interpolation is the known source of downward bias in reconstructed
    ///      variance — see UniV3Observer.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

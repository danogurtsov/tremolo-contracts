// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of Chainlink's AggregatorV3Interface this protocol reads.
/// @dev Declared locally rather than imported, for the same reason as the Uniswap interface: a
///      narrow, auditable surface beats a dependency on a package for four function signatures.
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @dev Reverts for rounds belonging to an earlier aggregator phase, which is why every
    ///      caller here wraps it in try/catch and treats a revert as "history ends".
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 id, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

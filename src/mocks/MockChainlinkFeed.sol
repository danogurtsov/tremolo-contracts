// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";

/// @notice Test double for a Chainlink aggregator, including the parts that make it awkward.
/// @dev Reproduces round-indexed history and a phase boundary: rounds below `phaseStart` revert,
///      exactly as a real aggregator does after an upgrade. A mock without that boundary would
///      hide the case every caller has to handle.
contract MockChainlinkFeed is IChainlinkAggregator {
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latest;
    uint80 public phaseStart = 1;
    uint8 internal immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function push(int256 answer, uint256 updatedAt) external {
        latest += 1;
        rounds[latest] = Round(answer, updatedAt);
    }

    function setPhaseStart(uint80 start) external {
        phaseStart = start;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latest];
        return (latest, r.answer, r.updatedAt, r.updatedAt, latest);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(roundId >= phaseStart && roundId <= latest, "No data present");
        Round memory r = rounds[roundId];
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }
}

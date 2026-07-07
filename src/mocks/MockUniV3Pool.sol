// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IUniswapV3PoolOracle} from "../interfaces/IUniswapV3PoolOracle.sol";

/// @notice Test double for a Uniswap V3 pool oracle.
/// @dev Reproduces the behaviour the protocol actually depends on, including the parts that
///      are inconvenient: a ring buffer of finite size, observations written only when the
///      pool is touched, and linear interpolation between them. A mock that returned clean
///      values on demand would hide exactly the bias this protocol has to survive.
contract MockUniV3Pool is IUniswapV3PoolOracle {
    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        uint160 secondsPerLiquidityCumulativeX128;
        bool initialized;
    }

    Observation[65_535] public obs;
    uint16 public index;
    uint16 public cardinality;
    uint16 public cardinalityNext;
    int24 public currentTick;

    bool public reverting;

    error OldObservation();
    error PoolReverted();

    constructor(int24 initialTick, uint16 initialCardinality, uint32 startTimestamp) {
        currentTick = initialTick;
        cardinality = initialCardinality == 0 ? 1 : initialCardinality;
        cardinalityNext = cardinality;
        obs[0] = Observation(startTimestamp, 0, 0, true);
    }

    /// @notice Records an observation, exactly as a swap would.
    function writeObservation(uint32 timestamp, int24 tick) public {
        Observation memory last = obs[index];
        uint32 delta = timestamp - last.blockTimestamp;
        int56 cumulative = last.tickCumulative + int56(currentTick) * int56(uint56(delta));

        index = uint16((uint256(index) + 1) % cardinality);
        obs[index] = Observation(timestamp, cumulative, 0, true);
        currentTick = tick;
    }

    /// @notice Writes a series of observations on a fixed cadence.
    function writeSeries(uint32 startTs, uint32 step, int24[] calldata ticks) external {
        for (uint256 i = 0; i < ticks.length; ++i) {
            writeObservation(startTs + uint32(i) * step, ticks[i]);
        }
    }

    function setReverting(bool v) external {
        reverting = v;
    }

    function grow(uint16 newCardinality) external {
        require(newCardinality > cardinality, "shrink");
        cardinality = newCardinality;
        cardinalityNext = newCardinality;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, currentTick, index, cardinality, cardinalityNext, 0, true);
    }

    function observations(uint256 i) external view returns (uint32, int56, uint160, bool) {
        Observation memory o = obs[i];
        return (o.blockTimestamp, o.tickCumulative, o.secondsPerLiquidityCumulativeX128, o.initialized);
    }

    /// @dev Mirrors the real pool: binary search for the surrounding observations, then linear
    ///      interpolation. Reverts when asked for a moment older than the buffer remembers.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory)
    {
        if (reverting) revert PoolReverted();

        tickCumulatives = new int56[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = _observeSingle(uint32(block.timestamp) - secondsAgos[i]);
        }
        return (tickCumulatives, new uint160[](secondsAgos.length));
    }

    function _observeSingle(uint32 target) internal view returns (int56) {
        Observation memory last = obs[index];

        // At or after the newest observation: extrapolate forward at the current tick.
        if (target >= last.blockTimestamp) {
            uint32 delta = target - last.blockTimestamp;
            return last.tickCumulative + int56(currentTick) * int56(uint56(delta));
        }

        // Walk back through the ring to find the surrounding pair.
        for (uint16 k = 1; k < cardinality; ++k) {
            uint16 slot = uint16((uint256(index) + cardinality - k) % cardinality);
            Observation memory o = obs[slot];
            if (!o.initialized) break;
            if (o.blockTimestamp <= target) {
                uint16 nextSlot = uint16((uint256(slot) + 1) % cardinality);
                Observation memory n = obs[nextSlot];
                uint32 span = n.blockTimestamp - o.blockTimestamp;
                if (span == 0) return o.tickCumulative;
                // Linear interpolation — the source of the downward variance bias.
                int56 diff = n.tickCumulative - o.tickCumulative;
                return
                    o.tickCumulative + diff * int56(uint56(target - o.blockTimestamp)) / int56(uint56(span));
            }
        }
        revert OldObservation();
    }

    function increaseObservationCardinalityNext(uint16 next) external {
        if (next > cardinality) {
            cardinality = next;
            cardinalityNext = next;
        }
    }
}

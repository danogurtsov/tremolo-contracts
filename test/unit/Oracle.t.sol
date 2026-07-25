// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {RealizedVolatilityOracle} from "../../src/RealizedVolatilityOracle.sol";
import {UniV3Observer} from "../../src/observers/UniV3Observer.sol";
import {IPriceObserver} from "../../src/interfaces/IPriceObserver.sol";
import {MockUniV3Pool} from "../../src/mocks/MockUniV3Pool.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {Variance} from "../../src/types/Variance.sol";

/// @notice The volatility figure as something other contracts can read.
contract OracleTest is Test {
    RealizedVolatilityOracle internal oracle;
    UniV3Observer internal observer;
    MockUniV3Pool internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new RealizedVolatilityOracle();
        observer = new UniV3Observer();
        pool = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));

        // A day of movement: ±60 ticks every fifteen minutes.
        uint32 ts = uint32(block.timestamp - 1 days);
        int24 tick = 200_000;
        while (ts <= block.timestamp) {
            vm.warp(ts);
            tick = tick == int24(200_000) ? int24(200_060) : int24(200_000);
            pool.writeObservation(ts, tick);
            ts += 15 minutes;
        }
        vm.warp(ts);
    }

    /// @notice Volatility is the square root of variance, in the same WAD scale.
    /// @dev Worth pinning: the scaling here produced a figure 100x too large on the first
    ///      attempt elsewhere in this repository, and it looked entirely plausible.
    function test_read_volatilityIsSqrtOfVariance() public view {
        RealizedVolatilityOracle.Reading memory r =
            oracle.read(IPriceObserver(address(observer)), address(pool), 6 hours, 12);

        console2.log("variance (wad)  ", Variance.unwrap(r.variance));
        console2.log("volatility (wad)", r.volatilityWad);
        console2.log("volatility (%)  ", r.volatilityWad / 1e16);

        uint256 squared = r.volatilityWad * r.volatilityWad / 1e18;
        assertApproxEqRel(squared, Variance.unwrap(r.variance), 0.001e18, "vol^2 != variance");
    }

    /// @notice A reading carries what it is worth, not only what it says.
    /// @dev A number without its provenance is worse than no number, because it gets trusted.
    function test_read_carriesProvenance() public view {
        RealizedVolatilityOracle.Reading memory r =
            oracle.read(IPriceObserver(address(observer)), address(pool), 6 hours, 12);

        assertGt(r.genuineObservations, 0, "no genuine recordings reported");
        assertEq(r.expectedObservations, 12);
        assertGt(r.sourceDepth, 0, "a caller cannot size against zero depth");
        assertEq(r.windowSeconds, 6 hours);
    }

    /// @notice A sparse window is reported as sparse rather than smoothed over.
    /// @dev The oracle does not refuse to answer — refusing would be a judgement it has no
    ///      standing to make. It reports how much of the window was real and lets the caller
    ///      decide, which is the same contract the market has with its own settlement.
    function test_read_reportsSparsenessRatherThanHidingIt() public {
        MockUniV3Pool quiet = new MockUniV3Pool(200_000, 512, uint32(block.timestamp - 2 days));
        quiet.writeObservation(uint32(block.timestamp - 3 hours), 200_050);
        quiet.writeObservation(uint32(block.timestamp - 1 hours), 200_000);

        RealizedVolatilityOracle.Reading memory r =
            oracle.read(IPriceObserver(address(observer)), address(quiet), 6 hours, 24);

        assertLt(r.genuineObservations, r.expectedObservations / 4, "sparseness not visible");
    }

    /// @notice Coarser grids report less volatility, and that is the definition, not an error.
    /// @dev Each sample is a TWAP over its step, so averaging inside a step cancels movement
    ///      within it. Measured at roughly a third on live data.
    function test_read_coarserGridReportsLess() public view {
        uint256 fine = oracle.read(IPriceObserver(address(observer)), address(pool), 6 hours, 24)
            .volatilityWad;
        uint256 coarse = oracle.read(IPriceObserver(address(observer)), address(pool), 6 hours, 3)
            .volatilityWad;

        assertLt(coarse, fine, "a coarser grid should report lower volatility");
    }

    /// @notice The term structure comes back in one call.
    function test_termStructure() public view {
        uint32[] memory windows = new uint32[](3);
        windows[0] = 1 hours;
        windows[1] = 6 hours;
        windows[2] = 12 hours;

        RealizedVolatilityOracle.Reading[] memory rs =
            oracle.termStructure(IPriceObserver(address(observer)), address(pool), windows, 12);

        assertEq(rs.length, 3);
        for (uint256 i = 0; i < rs.length; ++i) {
            console2.log("window (h) / vol (%)", rs[i].windowSeconds / 3600, rs[i].volatilityWad / 1e16);
            assertEq(rs[i].windowSeconds, windows[i]);
            assertGt(rs[i].volatilityWad, 0);
        }
    }

    /// @notice Windows longer than the source remembers revert rather than answering short.
    /// @dev Silently measuring a shorter window would be the worst outcome: a plausible number
    ///      describing a period the caller did not ask about.
    function test_read_revertsBeyondSourceHistory() public {
        vm.expectRevert();
        oracle.read(IPriceObserver(address(observer)), address(pool), 30 days, 24);
    }

    function test_read_rejectsDegenerateInputs() public {
        vm.expectRevert(abi.encodeWithSelector(RealizedVolatilityOracle.WindowTooShort.selector, uint32(60)));
        oracle.read(IPriceObserver(address(observer)), address(pool), 60, 12);

        vm.expectRevert(abi.encodeWithSelector(RealizedVolatilityOracle.TooFewSamples.selector, uint16(1)));
        oracle.read(IPriceObserver(address(observer)), address(pool), 6 hours, 1);
    }
}

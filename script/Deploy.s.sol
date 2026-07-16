// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {VarianceMarket} from "../src/VarianceMarket.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {UniV3Observer} from "../src/observers/UniV3Observer.sol";
import {ChainlinkObserver} from "../src/observers/ChainlinkObserver.sol";
import {IVarianceMarket} from "../src/interfaces/IVarianceMarket.sol";
import {Variance} from "../src/types/Variance.sol";

/// @notice Deploys the protocol and, optionally, opens a first series against a real pool.
///
/// @dev Run against a fork before running against a chain. `make deploy-dry` does exactly that
///      and it runs in CI, because a deployment script that has never executed is not a
///      deployment script — it is a file. The dry run catches what only appears at deploy time:
///      constructor ordering, a guardian nobody set, a pool whose buffer is too shallow for the
///      series the script tries to open.
///
///      Usage:
///        forge script script/Deploy.s.sol --fork-url base                      # dry run
///        forge script script/Deploy.s.sol --rpc-url base --broadcast --verify  # for real
///
///      Environment:
///        GUARDIAN         may pause creation of new series; defaults to the sender
///        SEED_POOL        Uniswap V3 pool for the first series
///        SEED_COLLATERAL  collateral token for that series
contract Deploy is Script {
    /// @dev Uniswap V3 WETH/USDC 0.05% on Base, and USDC on Base.
    address internal constant DEFAULT_POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant DEFAULT_COLLATERAL = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev 20% annualised volatility. A placeholder only: with RFQ live, real strikes come from
    ///      signed quotes rather than from whoever ran the deployment.
    Variance internal constant SEED_STRIKE = Variance.wrap(0.04e18);
    uint32 internal constant SEED_WINDOW = 1 days;

    function run()
        external
        returns (
            VarianceMarket market,
            RFQSettlement rfq,
            UniV3Observer uniObserver,
            ChainlinkObserver linkObserver
        )
    {
        address guardian = vm.envOr("GUARDIAN", msg.sender);

        vm.startBroadcast();
        uniObserver = new UniV3Observer();
        linkObserver = new ChainlinkObserver();
        market = new VarianceMarket(guardian);
        rfq = new RFQSettlement(market);
        vm.stopBroadcast();

        console2.log("UniV3Observer     ", address(uniObserver));
        console2.log("ChainlinkObserver ", address(linkObserver));
        console2.log("VarianceMarket    ", address(market));
        console2.log("RFQSettlement     ", address(rfq));
        console2.log("guardian          ", guardian);

        _seedSeries(market, uniObserver);
    }

    /// @dev Opening a series is part of the check rather than decoration: it is the only thing
    ///      that proves the pool being deployed against can actually support one. Skipped
    ///      cleanly when the defaults mean nothing on this chain, so the script still runs.
    function _seedSeries(VarianceMarket market, UniV3Observer observer) internal {
        address pool = vm.envOr("SEED_POOL", DEFAULT_POOL);
        address collateral = vm.envOr("SEED_COLLATERAL", DEFAULT_COLLATERAL);

        if (pool.code.length == 0 || collateral.code.length == 0) {
            console2.log("seed skipped: pool or collateral absent on this chain");
            return;
        }

        try observer.maxLookback(pool) returns (uint32 lookback) {
            console2.log("pool history (s)  ", lookback);

            if (lookback < SEED_WINDOW + observer.LOOKBACK_HEADROOM()) {
                console2.log("seed skipped: buffer too shallow for a daily series");
                console2.log("  extend with increaseObservationCardinalityNext first");
                return;
            }

            vm.startBroadcast();
            uint256 id = market.createSeries(
                IVarianceMarket.SeriesParams({
                    observer: address(observer),
                    source: pool,
                    collateral: collateral,
                    startTime: uint64(block.timestamp + 1 hours),
                    expiry: uint64(block.timestamp + 1 hours + SEED_WINDOW),
                    samples: 24,
                    // One genuine recording per grid point, as derived in ADR-0007.
                    minCompletenessBps: 10_000,
                    capMultiple: 2.5e18,
                    strike: SEED_STRIKE,
                    notionalPerUnit: 1000e6
                })
            );
            vm.stopBroadcast();

            console2.log("seed series id    ", id);
        } catch {
            console2.log("seed skipped: pool did not answer maxLookback");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {VarianceMarket} from "../src/VarianceMarket.sol";
import {RFQSettlement} from "../src/RFQSettlement.sol";
import {UniV3Observer} from "../src/observers/UniV3Observer.sol";
import {ChainlinkObserver} from "../src/observers/ChainlinkObserver.sol";
import {RealizedVolatilityOracle} from "../src/RealizedVolatilityOracle.sol";
import {IVarianceMarket} from "../src/interfaces/IVarianceMarket.sol";
import {Variance} from "../src/types/Variance.sol";
import {LocalSwapper} from "./LocalSwapper.sol";

/// @notice Deploys the protocol onto a local Base fork and leaves it in a state worth looking at.
///
/// @dev A deployment with nothing in it tests nothing. This one creates series in three different
///      phases, so the application has something to render before a single button is wired:
///
///        #1  subscribing  — open, both sides can still join
///        #2  subscribing  — a second strike on the same source, so the list is not a single row
///        #3  short window — meant to be aged and settled by ops/age.sh
///
///      Addresses are written to ops/addresses.local.json, which the frontend reads. Nothing is
///      copied by hand.
contract DeployLocal is Script {
    address internal constant POOL = 0xd0b53D9277642d899DF5C87A3966A349A798F224;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 pk = vm.envOr(
            "PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        UniV3Observer uni = new UniV3Observer();
        ChainlinkObserver link = new ChainlinkObserver();
        VarianceMarket market = new VarianceMarket(me);
        RFQSettlement rfq = new RFQSettlement(market);
        market.setAuthorizedOpener(address(rfq), true);
        RealizedVolatilityOracle oracle = new RealizedVolatilityOracle();
        LocalSwapper swapper = new LocalSwapper(POOL);

        uint256 s1 = market.createSeries(_params(address(uni), 0.04e18, 1 hours, 6 hours, 24));
        uint256 s2 = market.createSeries(_params(address(uni), 0.09e18, 1 hours, 6 hours, 24));
        uint256 s3 = market.createSeries(_params(address(uni), 0.05e18, 20 minutes, 2 hours, 12));

        vm.stopBroadcast();

        _write(
            address(market), address(rfq), address(uni), address(link), address(oracle), address(swapper), me
        );

        console2.log("");
        console2.log("VarianceMarket    ", address(market));
        console2.log("RFQSettlement     ", address(rfq));
        console2.log("UniV3Observer     ", address(uni));
        console2.log("ChainlinkObserver ", address(link));
        console2.log("VolatilityOracle  ", address(oracle));
        console2.log("LocalSwapper      ", address(swapper));
        console2.log("");
        console2.log("series            ", s1, s2, s3);
        console2.log("pool history (s)  ", uni.maxLookback(POOL));
        console2.log("1% depth (USDC)   ", uni.depthQuote(POOL) / 1e6);
    }

    function _params(address observer, uint256 strike, uint256 startIn, uint32 window, uint16 samples)
        internal
        view
        returns (IVarianceMarket.SeriesParams memory)
    {
        return IVarianceMarket.SeriesParams({
            observer: observer,
            source: POOL,
            collateral: USDC,
            startTime: uint64(block.timestamp + startIn),
            expiry: uint64(block.timestamp + startIn + window),
            samples: samples,
            // One genuine recording per grid point; see docs/measurements/variance_bias.md.
            minCompletenessBps: 10_000,
            capMultiple: 2.5e18,
            strike: Variance.wrap(strike),
            notionalPerUnit: 1000e6
        });
    }

    function _write(
        address market,
        address rfq,
        address uni,
        address link,
        address oracle,
        address swapper,
        address guardian
    ) internal {
        string memory j = string.concat(
            "{\n",
            '  "chainId": 8453,\n',
            '  "rpc": "http://127.0.0.1:8545",\n',
            '  "market": "',
            vm.toString(market),
            '",\n',
            '  "rfq": "',
            vm.toString(rfq),
            '",\n',
            '  "uniObserver": "',
            vm.toString(uni),
            '",\n',
            '  "chainlinkObserver": "',
            vm.toString(link),
            '",\n',
            '  "oracle": "',
            vm.toString(oracle),
            '",\n',
            '  "swapper": "',
            vm.toString(swapper),
            '",\n',
            '  "guardian": "',
            vm.toString(guardian),
            '",\n',
            '  "pool": "',
            vm.toString(POOL),
            '",\n',
            '  "collateral": "',
            vm.toString(USDC),
            '"\n',
            "}\n"
        );
        vm.writeFile("../ops/addresses.local.json", j);
    }
}

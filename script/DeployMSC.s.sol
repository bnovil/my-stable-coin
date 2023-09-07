// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {MyStableCoin} from "../src/MyStableCoin.sol";
import {StableCoinEngine} from "../src/StableCoinEngine.sol";

contract DeployMSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (MyStableCoin, StableCoinEngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        MyStableCoin msc = new MyStableCoin();
        StableCoinEngine stableCoinEngine = new StableCoinEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(msc)
        );
        msc.transferOwnership(address(stableCoinEngine));
        vm.stopBroadcast();
        return (msc, stableCoinEngine, helperConfig);
    }
}

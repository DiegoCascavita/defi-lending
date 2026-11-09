// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title DeployLending
 * @notice Deploys LendingPool for Anvil using HelperConfig mocks.
 *
 * Usage:
 *   anvil
 *   forge script script/DeployLending.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployLending is Script {
    function run() external returns (LendingPool, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address wethUsdPrimaryFeed,
            address wethUsdSecondaryOracle,
            address weth,
            address dai,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        vm.startBroadcast(deployerKey);
        LendingPool pool = new LendingPool(weth, dai, wethUsdPrimaryFeed, wethUsdSecondaryOracle);
        vm.stopBroadcast();
        return (pool, helperConfig);
    }
}

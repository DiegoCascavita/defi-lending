// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../test/mocks/MockSecondaryOracle.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

/**
 * @title HelperConfig
 * @notice Network-aware config for Anvil local deployments (and easy extension to Sepolia).
 */
contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPrimaryFeed;
        address wethUsdSecondaryOracle;
        address weth;
        address dai;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    uint256 public constant SECONDARY_CONF = 1e6; // $0.01 absolute confidence
    uint256 public constant DEFAULT_ANVIL_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        activeNetworkConfig = getOrCreateAnvilEthConfig();
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory anvilNetworkConfig) {
        if (activeNetworkConfig.wethUsdPrimaryFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockSecondaryOracle secondary = new MockSecondaryOracle(DECIMALS, ETH_USD_PRICE, SECONDARY_CONF);
        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e18);
        ERC20Mock daiMock = new ERC20Mock("DAI", "DAI", msg.sender, 1_000_000e18);
        vm.stopBroadcast();

        anvilNetworkConfig = NetworkConfig({
            wethUsdPrimaryFeed: address(ethUsdPriceFeed),
            wethUsdSecondaryOracle: address(secondary),
            weth: address(wethMock),
            dai: address(daiMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}

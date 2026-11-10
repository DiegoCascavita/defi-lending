// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {MockSecondaryOracle} from "../test/mocks/MockSecondaryOracle.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

/**
 * @title DeployLending
 * @notice Deploys LendingPool using HelperConfig (Anvil mocks or Sepolia Chainlink primary).
 *
 * Anvil:
 *   anvil
 *   forge script script/DeployLending.s.sol:DeployLending \
 *     --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
 *
 * Sepolia (requires secrets in .env — do NOT invent keys):
 *   source .env   # SEPOLIA_RPC_URL, PRIVATE_KEY, ETHERSCAN_API_KEY
 *   forge script script/DeployLending.s.sol:DeployLending \
 *     --rpc-url "$SEPOLIA_RPC_URL" --broadcast --verify -vvvv
 *
 * If PRIVATE_KEY / SEPOLIA_RPC_URL / ETHERSCAN_API_KEY are missing, leave this as a dry checklist —
 * never hardcode secrets. Dry-run without --broadcast still compiles and simulates locally.
 */
contract DeployLending is Script {
    uint8 private constant DECIMALS = 8;
    uint256 private constant SECONDARY_CONF = 1e6;

    function run() external returns (LendingPool, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address wethUsdPrimaryFeed,
            address wethUsdSecondaryOracle,
            address weth,
            address dai,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        bool isSepolia = block.chainid == helperConfig.SEPOLIA_CHAIN_ID();

        if (isSepolia && deployerKey == 0) {
            revert("DeployLending: PRIVATE_KEY not set - refuse to broadcast without a key");
        }

        // On Sepolia (or any config with zero secondary/dai), deploy the missing pieces inside the
        // same broadcast so the pool constructor receives live addresses.
        vm.startBroadcast(deployerKey);

        if (wethUsdSecondaryOracle == address(0)) {
            (, int256 answer,,,) = AggregatorV3Interface(wethUsdPrimaryFeed).latestRoundData();
            require(answer > 0, "DeployLending: invalid Chainlink answer");
            MockSecondaryOracle secondary = new MockSecondaryOracle(DECIMALS, answer, SECONDARY_CONF);
            wethUsdSecondaryOracle = address(secondary);
        }

        if (dai == address(0)) {
            // Mintable test DAI for Sepolia demos (no reliable Maker faucet).
            ERC20Mock daiMock = new ERC20Mock("DAI", "DAI", msg.sender, 0);
            dai = address(daiMock);
        }

        // Optional: if SEPOLIA_USE_MOCK_WETH=true, replace canonical WETH with a mintable mock.
        // Default keeps HelperConfig's Sepolia WETH so the pool prices real wrapped ETH.
        if (isSepolia && vm.envOr("SEPOLIA_USE_MOCK_WETH", false)) {
            ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 0);
            weth = address(wethMock);
        }

        LendingPool pool = new LendingPool(weth, dai, wethUsdPrimaryFeed, wethUsdSecondaryOracle);

        vm.stopBroadcast();

        console2.log("LendingPool", address(pool));
        console2.log("WETH", weth);
        console2.log("DAI", dai);
        console2.log("PrimaryFeed", wethUsdPrimaryFeed);
        console2.log("SecondaryOracle", wethUsdSecondaryOracle);

        return (pool, helperConfig);
    }
}

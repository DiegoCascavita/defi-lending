// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../test/mocks/MockSecondaryOracle.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

/**
 * @title HelperConfig
 * @notice Network-aware config for Anvil (mocks) and Sepolia (real Chainlink primary feed).
 *
 * Sepolia ETH/USD AggregatorV3 proxy (official Chainlink docs):
 * https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet
 * Address: 0x694AA1769357215DE4FAC081bf1f309aDC325306
 *
 * Sepolia WETH (canonical wrap used by many testnet stacks / bridges):
 * https://sepolia.etherscan.io/token/0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
 *
 * Secondary oracle: no public Pyth-style `ISecondaryOracle` on Sepolia matching this protocol.
 * DeployLending deploys a `MockSecondaryOracle` calibrated to the live Chainlink answer at deploy time
 * when `wethUsdSecondaryOracle == address(0)`.
 *
 * Debt token: no reliable Maker DAI faucet on Sepolia for demos — DeployLending deploys an ERC20Mock
 * DAI when `dai == address(0)`.
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

    /// @dev Chainlink ETH/USD proxy — Sepolia (docs.chain.link data feeds).
    address public constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    /// @dev Canonical Sepolia WETH9.
    address public constant SEPOLIA_WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    /// @dev Chainlink ETH/USD proxy — Ethereum mainnet (docs.chain.link). Useful for fork tests.
    address public constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant MAINNET_CHAIN_ID = 1;

    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    /**
     * @notice Sepolia config with the real Chainlink ETH/USD feed.
     * @dev `wethUsdSecondaryOracle` and `dai` are zero → DeployLending deploys mocks.
     *      `weth` points at canonical Sepolia WETH; set to address(0) in DeployLending only if you
     *      prefer a mintable mock (see script comments). Default uses real WETH.
     *      `deployerKey` reads `PRIVATE_KEY` when present; otherwise 0 (script must not broadcast).
     */
    function getSepoliaEthConfig() public view returns (NetworkConfig memory sepoliaNetworkConfig) {
        sepoliaNetworkConfig = NetworkConfig({
            wethUsdPrimaryFeed: SEPOLIA_ETH_USD_FEED,
            wethUsdSecondaryOracle: address(0),
            weth: SEPOLIA_WETH,
            dai: address(0),
            deployerKey: vm.envOr("PRIVATE_KEY", uint256(0))
        });
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

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {DualOracleLib} from "../../src/libraries/DualOracleLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {ISecondaryOracle} from "../../src/interfaces/ISecondaryOracle.sol";
import {MockSecondaryOracle} from "../mocks/MockSecondaryOracle.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/**
 * @title ForkOracleLiquidation
 * @notice Fork tests against live Chainlink ETH/USD when an RPC URL is configured.
 *
 * Env (optional — CI without RPC skips gracefully):
 *   SEPOLIA_RPC_URL  → prefer Sepolia fork + Chainlink Sepolia ETH/USD
 *   MAINNET_RPC_URL  → fallback mainnet fork + Chainlink mainnet ETH/USD
 *
 * Feed sources (Chainlink docs):
 *   Sepolia:  https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet
 *             0x694AA1769357215DE4FAC081bf1f309aDC325306
 *   Mainnet:  https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#ethereum-mainnet
 *             0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
 *
 * Coverage:
 * - Dual-oracle validates against a real AggregatorV3 primary + calibrated secondary
 * - Deviation path reverts when secondary drifts > 1%
 * - Liquidation path after mocking a price crash on the primary feed
 */
contract ForkOracleLiquidation is Test {
    using OracleLib for AggregatorV3Interface;

    address private constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address private constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint256 private constant MAX_ORACLE_DEVIATION_BPS = 100;
    uint256 private constant SECONDARY_CONF = 1e6;
    uint8 private constant DECIMALS = 8;

    bool private forkActive;
    address private primaryFeed;
    MockSecondaryOracle private secondary;
    LendingPool private pool;
    ERC20Mock private weth;
    ERC20Mock private dai;

    address private user = makeAddr("forkUser");
    address private lp = makeAddr("forkLp");
    address private liquidator = makeAddr("forkLiquidator");

    uint256 private constant COLLATERAL = 10e18;
    uint256 private constant LIQUIDITY = 100_000e18;

    function setUp() public {
        string memory sepoliaRpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        string memory mainnetRpc = vm.envOr("MAINNET_RPC_URL", string(""));

        if (bytes(sepoliaRpc).length > 0) {
            vm.createSelectFork(sepoliaRpc);
            primaryFeed = SEPOLIA_ETH_USD_FEED;
            forkActive = true;
            console2.log("Fork: Sepolia ETH/USD", primaryFeed);
        } else if (bytes(mainnetRpc).length > 0) {
            vm.createSelectFork(mainnetRpc);
            primaryFeed = MAINNET_ETH_USD_FEED;
            forkActive = true;
            console2.log("Fork: Mainnet ETH/USD", primaryFeed);
        } else {
            console2.log("Fork tests skipped: set SEPOLIA_RPC_URL or MAINNET_RPC_URL");
            return;
        }

        (, int256 answer,,,) = AggregatorV3Interface(primaryFeed).latestRoundData();
        require(answer > 0, "fork: bad Chainlink answer");

        secondary = new MockSecondaryOracle(DECIMALS, answer, SECONDARY_CONF);
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        dai = new ERC20Mock("DAI", "DAI", address(this), 0);
        pool = new LendingPool(address(weth), address(dai), primaryFeed, address(secondary));

        weth.mint(user, 100e18);
        dai.mint(lp, LIQUIDITY);
        dai.mint(liquidator, LIQUIDITY);

        vm.startPrank(lp);
        dai.approve(address(pool), type(uint256).max);
        pool.supplyLiquidity(LIQUIDITY);
        vm.stopPrank();

        vm.startPrank(user);
        weth.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    modifier onlyFork() {
        vm.skip(!forkActive);
        _;
    }

    function testFork_PrimaryFeedIsFresh() public onlyFork {
        (,,, uint256 updatedAt,) = AggregatorV3Interface(primaryFeed).staleCheckLatestRoundData();
        assertGt(updatedAt, 0);
        assertLe(block.timestamp - updatedAt, OracleLib.getTimeout(AggregatorV3Interface(primaryFeed)));
    }

    function testFork_DualOracleMatchesLivePrimary() public onlyFork {
        int256 validated = DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(primaryFeed), ISecondaryOracle(address(secondary)), MAX_ORACLE_DEVIATION_BPS
        );
        (, int256 primaryAnswer,,,) = AggregatorV3Interface(primaryFeed).latestRoundData();
        assertEq(validated, primaryAnswer);
        assertGt(validated, 0);
    }

    function testFork_UsdValueUsesLivePrice() public onlyFork {
        (, int256 answer,,,) = AggregatorV3Interface(primaryFeed).latestRoundData();
        uint256 expectedUsd = uint256(answer) * 1e10; // 1 WETH → USD (1e18)
        assertEq(pool.getUsdValue(1e18), expectedUsd);
    }

    function testFork_DeviationRevertsWhenSecondaryDrifts() public onlyFork {
        (, int256 answer,,,) = AggregatorV3Interface(primaryFeed).latestRoundData();
        int256 drifted = answer + (answer * 2) / 100; // +2% > 1% max
        secondary.setPrice(drifted, SECONDARY_CONF);

        vm.expectRevert();
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(primaryFeed), ISecondaryOracle(address(secondary)), MAX_ORACLE_DEVIATION_BPS
        );
    }

    function testFork_BorrowAndHealthFactorWithLiveOracle() public onlyFork {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        uint256 collateralUsd = pool.getUsdValue(COLLATERAL);
        uint256 borrowAmount = collateralUsd / 10;
        pool.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(pool.getDebtBalance(user), borrowAmount);
        assertGt(pool.getHealthFactor(user), 1e18);
    }

    function testFork_LiquidationAfterMockedPriceCrash() public onlyFork {
        (, int256 liveAnswer,,,) = AggregatorV3Interface(primaryFeed).latestRoundData();

        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        uint256 collateralUsd = pool.getUsdValue(COLLATERAL);
        uint256 maxDebtUsd = (collateralUsd * 80) / 100;
        uint256 borrowAmount = (maxDebtUsd * 70) / 100;
        pool.borrow(borrowAmount);
        vm.stopPrank();

        assertGt(pool.getHealthFactor(user), 1e18);

        // Crash primary via mockCall (cannot update live Chainlink) + sync secondary.
        int256 crashed = liveAnswer / 3;
        _mockPrimaryAnswer(crashed);
        secondary.setPrice(crashed, SECONDARY_CONF);

        assertLt(pool.getHealthFactor(user), 1e18);

        uint256 debtToCover = borrowAmount / 2;
        uint256 wethBefore = weth.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(user, debtToCover);

        assertGt(weth.balanceOf(liquidator), wethBefore);
        assertEq(pool.getDebtBalance(user), borrowAmount - debtToCover);
    }

    function _mockPrimaryAnswer(int256 answer) internal {
        bytes memory data = abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector);
        vm.mockCall(
            primaryFeed, data, abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }
}

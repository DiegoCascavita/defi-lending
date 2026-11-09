// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../mocks/MockSecondaryOracle.sol";

/**
 * @title OpenInvariantsTest
 * @notice Stateless fuzz properties for pricing / health-factor math.
 */
contract OpenInvariantsTest is Test {
    LendingPool public pool;
    ERC20Mock public weth;
    ERC20Mock public dai;
    MockV3Aggregator public primary;
    MockSecondaryOracle public secondary;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD = 2000e8;
    uint256 public constant CONF = 1e6;

    function setUp() public {
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        dai = new ERC20Mock("DAI", "DAI", address(this), 0);
        primary = new MockV3Aggregator(DECIMALS, ETH_USD);
        secondary = new MockSecondaryOracle(DECIMALS, ETH_USD, CONF);
        pool = new LendingPool(address(weth), address(dai), address(primary), address(secondary));
    }

    function testFuzz_usdValueLinear(uint96 amount) public view {
        uint256 usd = pool.getUsdValue(amount);
        assertEq(usd, uint256(amount) * 2000);
    }

    function testFuzz_tokenAmountRoundTrip(uint96 usdAmount) public view {
        usdAmount = uint96(bound(usdAmount, 1, 1_000_000_000e18));
        uint256 tokens = pool.getTokenAmountFromUsd(usdAmount);
        uint256 back = pool.getUsdValue(tokens);
        assertLe(back, usdAmount);
        assertApproxEqAbs(back, usdAmount, 1999);
    }

    function testFuzz_healthFactorZeroDebt(uint256 collateralUsd) public view {
        collateralUsd = bound(collateralUsd, 0, type(uint128).max);
        assertEq(pool.calculateHealthFactor(0, collateralUsd), type(uint256).max);
    }

    function testFuzz_healthFactorMonotoneInCollateral(uint256 debtUsd, uint256 c1, uint256 c2) public view {
        debtUsd = bound(debtUsd, 1, type(uint128).max);
        c1 = bound(c1, 0, type(uint128).max);
        c2 = bound(c2, c1, type(uint128).max);
        uint256 hf1 = pool.calculateHealthFactor(debtUsd, c1);
        uint256 hf2 = pool.calculateHealthFactor(debtUsd, c2);
        assertGe(hf2, hf1);
    }
}

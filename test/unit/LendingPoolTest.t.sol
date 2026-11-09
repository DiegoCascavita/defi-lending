// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../mocks/MockSecondaryOracle.sol";

contract LendingPoolTest is Test {
    LendingPool public pool;
    ERC20Mock public weth;
    ERC20Mock public dai;
    MockV3Aggregator public primary;
    MockSecondaryOracle public secondary;

    address public user = makeAddr("user");
    address public lp = makeAddr("lp");
    address public liquidator = makeAddr("liquidator");

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD = 2000e8;
    uint256 public constant CONF = 1e6;

    uint256 public constant COLLATERAL = 10e18;
    uint256 public constant LIQUIDITY = 100_000e18;

    function setUp() public {
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        dai = new ERC20Mock("DAI", "DAI", address(this), 0);
        primary = new MockV3Aggregator(DECIMALS, ETH_USD);
        secondary = new MockSecondaryOracle(DECIMALS, ETH_USD, CONF);
        pool = new LendingPool(address(weth), address(dai), address(primary), address(secondary));

        weth.mint(user, 100e18);
        dai.mint(lp, LIQUIDITY);
        dai.mint(liquidator, LIQUIDITY);
        dai.mint(user, LIQUIDITY);

        vm.startPrank(lp);
        dai.approve(address(pool), type(uint256).max);
        pool.supplyLiquidity(LIQUIDITY);
        vm.stopPrank();

        vm.startPrank(user);
        weth.approve(address(pool), type(uint256).max);
        dai.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(liquidator);
        dai.approve(address(pool), type(uint256).max);
    }

    function testDepositCollateral() public {
        vm.prank(user);
        pool.depositCollateral(COLLATERAL);
        assertEq(pool.getCollateralBalance(user), COLLATERAL);
        assertEq(pool.getTotalCollateral(), COLLATERAL);
        assertEq(weth.balanceOf(address(pool)), COLLATERAL);
    }

    function testDepositRevertsOnZero() public {
        vm.prank(user);
        vm.expectRevert(LendingPool.LendingPool__NeedsMoreThanZero.selector);
        pool.depositCollateral(0);
    }

    function testSupplyLiquidityTracksBalances() public view {
        assertEq(pool.getTotalLiquidity(), LIQUIDITY);
        assertEq(pool.getAvailableLiquidity(), LIQUIDITY);
        assertEq(pool.getLiquiditySupplied(lp), LIQUIDITY);
    }

    function testBorrowAgainstCollateral() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        uint256 borrowAmount = 10_000e18;
        pool.borrow(borrowAmount);
        vm.stopPrank();

        assertEq(pool.getDebtBalance(user), borrowAmount);
        assertEq(dai.balanceOf(user), LIQUIDITY + borrowAmount);
        assertGt(pool.getHealthFactor(user), 1e18);
    }

    function testBorrowRevertsWhenHealthFactorBroken() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        vm.expectRevert();
        pool.borrow(17_000e18);
        vm.stopPrank();
    }

    function testBorrowRevertsWhenInsufficientLiquidity() public {
        ERC20Mock w2 = new ERC20Mock("WETH", "WETH", address(this), 0);
        ERC20Mock d2 = new ERC20Mock("DAI", "DAI", address(this), 0);
        MockV3Aggregator p2 = new MockV3Aggregator(DECIMALS, ETH_USD);
        MockSecondaryOracle s2 = new MockSecondaryOracle(DECIMALS, ETH_USD, CONF);
        LendingPool small = new LendingPool(address(w2), address(d2), address(p2), address(s2));

        d2.mint(lp, 100e18);
        w2.mint(user, 10e18);

        vm.startPrank(lp);
        d2.approve(address(small), type(uint256).max);
        small.supplyLiquidity(100e18);
        vm.stopPrank();

        vm.startPrank(user);
        w2.approve(address(small), type(uint256).max);
        small.depositCollateral(10e18);
        vm.expectRevert(LendingPool.LendingPool__InsufficientLiquidity.selector);
        small.borrow(101e18);
        vm.stopPrank();
    }

    function testRepayDebt() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.borrow(5_000e18);
        pool.repay(5_000e18);
        vm.stopPrank();

        assertEq(pool.getDebtBalance(user), 0);
        assertEq(pool.getHealthFactor(user), type(uint256).max);
    }

    function testWithdrawCollateral() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.withdrawCollateral(COLLATERAL);
        vm.stopPrank();

        assertEq(pool.getCollateralBalance(user), 0);
        assertEq(weth.balanceOf(user), 100e18);
    }

    function testWithdrawCollateralRevertsIfBreaksHf() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.borrow(10_000e18);
        vm.expectRevert();
        pool.withdrawCollateral(COLLATERAL);
        vm.stopPrank();
    }

    function testWithdrawLiquidity() public {
        vm.prank(lp);
        pool.withdrawLiquidity(1_000e18);
        assertEq(pool.getLiquiditySupplied(lp), LIQUIDITY - 1_000e18);
        assertEq(dai.balanceOf(lp), 1_000e18);
    }

    function testWithdrawLiquidityRevertsIfBorrowed() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.prank(lp);
        vm.expectRevert(LendingPool.LendingPool__InsufficientLiquidity.selector);
        pool.withdrawLiquidity(LIQUIDITY);
    }

    function testLiquidateUndercollateralizedPosition() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.borrow(14_000e18);
        vm.stopPrank();

        _setPrice(1000e8);
        assertLt(pool.getHealthFactor(user), 1e18);

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        vm.prank(liquidator);
        pool.liquidate(user, 7_000e18);

        assertGt(weth.balanceOf(liquidator), liquidatorWethBefore);
        assertEq(pool.getDebtBalance(user), 7_000e18);
    }

    function testLiquidateRevertsWhenHealthy() public {
        vm.startPrank(user);
        pool.depositCollateral(COLLATERAL);
        pool.borrow(5_000e18);
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert(LendingPool.LendingPool__HealthFactorOk.selector);
        pool.liquidate(user, 1_000e18);
    }

    function testGetUsdValue() public {
        vm.prank(user);
        pool.depositCollateral(1e18);
        assertEq(pool.getUsdValue(1e18), 2000e18);
    }

    function testOracleDeviationBlocksBorrowPricing() public {
        vm.prank(user);
        pool.depositCollateral(COLLATERAL);

        secondary.setPrice(ETH_USD + (ETH_USD * 2) / 100, CONF);

        vm.prank(user);
        vm.expectRevert();
        pool.borrow(1_000e18);
    }

    function testViewGetters() public view {
        assertEq(pool.getCollateralToken(), address(weth));
        assertEq(pool.getDebtToken(), address(dai));
        assertEq(pool.getPrimaryFeed(), address(primary));
        assertEq(pool.getSecondaryOracle(), address(secondary));
        assertEq(pool.getLiquidationThreshold(), 80);
        assertEq(pool.getLiquidationBonus(), 5);
        assertEq(pool.getMinHealthFactor(), 1e18);
        assertEq(pool.getMaxOracleDeviationBps(), 100);
        assertEq(pool.getPrecision(), 1e18);
        assertEq(pool.calculateHealthFactor(0, 1000e18), type(uint256).max);
    }

    function testHealthFactorMath() public view {
        uint256 hf = pool.calculateHealthFactor(10_000e18, 20_000e18);
        assertEq(hf, 1.6e18);
    }

    function _setPrice(int256 newPrice) internal {
        primary.updateAnswer(newPrice);
        secondary.setPrice(newPrice, CONF);
    }
}

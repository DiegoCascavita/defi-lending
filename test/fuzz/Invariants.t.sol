// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../mocks/MockSecondaryOracle.sol";
import {Handler} from "./Handler.t.sol";

/**
 * @title Invariants
 * @notice Stateful invariant suite for LendingPool solvency accounting.
 */
contract Invariants is StdInvariant, Test {
    LendingPool public pool;
    ERC20Mock public weth;
    ERC20Mock public dai;
    Handler public handler;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD = 2000e8;
    uint256 public constant CONF = 1e6;

    function setUp() public {
        weth = new ERC20Mock("WETH", "WETH", address(this), 0);
        dai = new ERC20Mock("DAI", "DAI", address(this), 0);
        MockV3Aggregator primary = new MockV3Aggregator(DECIMALS, ETH_USD);
        MockSecondaryOracle secondary = new MockSecondaryOracle(DECIMALS, ETH_USD, CONF);
        pool = new LendingPool(address(weth), address(dai), address(primary), address(secondary));
        handler = new Handler(pool);

        targetContract(address(handler));
    }

    function invariant_poolDaiCoversDebtAndLiquidity() public view {
        uint256 poolDai = dai.balanceOf(address(pool));
        assertEq(poolDai + pool.getTotalDebt(), pool.getTotalLiquidity());
    }

    function invariant_poolWethEqualsTrackedCollateral() public view {
        assertEq(weth.balanceOf(address(pool)), pool.getTotalCollateral());
    }

    function invariant_availableLiquidityConsistent() public view {
        uint256 available = pool.getAvailableLiquidity();
        assertLe(available, pool.getTotalLiquidity());
        if (pool.getTotalLiquidity() > pool.getTotalDebt()) {
            assertEq(available, pool.getTotalLiquidity() - pool.getTotalDebt());
        } else {
            assertEq(available, 0);
        }
    }
}

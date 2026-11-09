// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/**
 * @title Handler
 * @notice Restricts fuzz calls to valid paths for invariant testing.
 * @dev Intentionally does NOT crash the oracle. A sudden price drop can make the system
 *      temporarily undercollateralized until liquidations clear bad debt — that breaks the
 *      solvency invariant by design. Liquidation / oracle paths are covered in unit tests.
 */
contract Handler is Test {
    LendingPool public pool;
    ERC20Mock public weth;
    ERC20Mock public dai;

    address[] public actors;
    uint256 public constant MAX_DEPOSIT = type(uint96).max;

    constructor(LendingPool _pool) {
        pool = _pool;
        weth = ERC20Mock(pool.getCollateralToken());
        dai = ERC20Mock(pool.getDebtToken());

        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));

        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            weth.approve(address(pool), type(uint256).max);
            dai.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function depositCollateral(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, MAX_DEPOSIT);
        weth.mint(actor, amount);
        vm.prank(actor);
        pool.depositCollateral(amount);
    }

    function supplyLiquidity(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        amount = bound(amount, 1, MAX_DEPOSIT);
        dai.mint(actor, amount);
        vm.prank(actor);
        pool.supplyLiquidity(amount);
    }

    function borrow(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 available = pool.getAvailableLiquidity();
        if (available == 0) return;

        (uint256 debtUsd, uint256 collateralUsd) = pool.getAccountInformation(actor);
        uint256 maxDebtUsd = (collateralUsd * pool.getLiquidationThreshold()) / 100;
        if (maxDebtUsd <= debtUsd) return;

        uint256 roomUsd = maxDebtUsd - debtUsd;
        uint256 maxBorrow = roomUsd;
        if (maxBorrow > available) maxBorrow = available;
        if (maxBorrow == 0) return;

        amount = bound(amount, 1, maxBorrow);
        vm.prank(actor);
        pool.borrow(amount);
    }

    function repay(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 debt = pool.getDebtBalance(actor);
        if (debt == 0) return;
        amount = bound(amount, 1, debt);
        dai.mint(actor, amount);
        vm.prank(actor);
        pool.repay(amount);
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 bal = pool.getCollateralBalance(actor);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        uint256 debt = pool.getDebtBalance(actor);
        if (debt > 0) {
            uint256 newCollateralUsd = pool.getUsdValue(bal - amount);
            uint256 debtUsd = pool.getDebtValueInUsd(debt);
            uint256 hf = pool.calculateHealthFactor(debtUsd, newCollateralUsd);
            if (hf < pool.getMinHealthFactor()) return;
        }

        vm.prank(actor);
        pool.withdrawCollateral(amount);
    }

    function withdrawLiquidity(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 supplied = pool.getLiquiditySupplied(actor);
        uint256 available = pool.getAvailableLiquidity();
        if (supplied == 0 || available == 0) return;
        uint256 maxOut = supplied < available ? supplied : available;
        amount = bound(amount, 1, maxOut);
        vm.prank(actor);
        pool.withdrawLiquidity(amount);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }
}

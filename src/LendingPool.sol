// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ISecondaryOracle} from "./interfaces/ISecondaryOracle.sol";
import {DualOracleLib} from "./libraries/DualOracleLib.sol";

/**
 * @title LendingPool
 * @author Diego Cascavita
 * @notice Minimal overcollateralized lending market: deposit WETH collateral, borrow DAI liquidity,
 *         repay, withdraw, and liquidate undercollateralized positions.
 *
 * Pricing:
 * - Collateral (WETH) uses a dual oracle: Chainlink AggregatorV3 primary + Pyth-style secondary,
 *   with a max deviation check (`MAX_ORACLE_DEVIATION_BPS`).
 * - Debt asset (DAI) is treated as a $1 USD stable for health-factor math.
 *
 * Risk parameters (Aave-like LTV band, distinct from the sibling DSC 200% CR design):
 * - Liquidation threshold 80% → healthy borrows require ~125% collateralization
 * - Liquidation bonus 5%
 * - Min health factor 1e18
 */
contract LendingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error LendingPool__NeedsMoreThanZero();
    error LendingPool__TransferFailed();
    error LendingPool__BreaksHealthFactor(uint256 healthFactor);
    error LendingPool__HealthFactorOk();
    error LendingPool__InsufficientLiquidity();
    error LendingPool__InsufficientCollateral();
    error LendingPool__InsufficientDebt();
    error LendingPool__InsufficientSupplied();

    /*//////////////////////////////////////////////////////////////
                               STATE VARS
    //////////////////////////////////////////////////////////////*/
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 80; // 80% → ~125% CR
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 5; // 5% liquidator incentive
    uint256 private constant MAX_ORACLE_DEVIATION_BPS = 100; // 1%
    /// @dev DAI is priced at $1 with 8 decimals to match AggregatorV3 USD convention.
    uint256 private constant DAI_USD_PRICE = 1e8;

    IERC20 private immutable i_collateralToken; // WETH
    IERC20 private immutable i_debtToken; // DAI
    AggregatorV3Interface private immutable i_primaryFeed;
    ISecondaryOracle private immutable i_secondaryOracle;

    mapping(address user => uint256 amount) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_debtBorrowed;
    /// @dev Liquidity providers' claim on the DAI pool (supplied DAI not currently borrowed).
    mapping(address user => uint256 amount) private s_liquiditySupplied;

    uint256 private s_totalCollateral;
    uint256 private s_totalDebt;
    uint256 private s_totalLiquidity;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event LiquiditySupplied(address indexed user, uint256 amount);
    event LiquidityWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed liquidator, address indexed borrower, uint256 debtCovered, uint256 collateralSeized
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingPool__NeedsMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(address collateralToken, address debtToken, address primaryFeed, address secondaryOracle) {
        i_collateralToken = IERC20(collateralToken);
        i_debtToken = IERC20(debtToken);
        i_primaryFeed = AggregatorV3Interface(primaryFeed);
        i_secondaryOracle = ISecondaryOracle(secondaryOracle);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit WETH as collateral. Does not mint shares; balances are tracked 1:1.
     */
    function depositCollateral(uint256 amount) external nonReentrant moreThanZero(amount) {
        s_collateralDeposited[msg.sender] += amount;
        s_totalCollateral += amount;
        emit CollateralDeposited(msg.sender, amount);
        i_collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Supply DAI liquidity that borrowers can draw from.
     */
    function supplyLiquidity(uint256 amount) external nonReentrant moreThanZero(amount) {
        s_liquiditySupplied[msg.sender] += amount;
        s_totalLiquidity += amount;
        emit LiquiditySupplied(msg.sender, amount);
        i_debtToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw previously supplied DAI liquidity (only unborrowed portion is available).
     */
    function withdrawLiquidity(uint256 amount) external nonReentrant moreThanZero(amount) {
        if (amount > s_liquiditySupplied[msg.sender]) {
            revert LendingPool__InsufficientSupplied();
        }
        uint256 available = getAvailableLiquidity();
        if (amount > available) {
            revert LendingPool__InsufficientLiquidity();
        }
        s_liquiditySupplied[msg.sender] -= amount;
        s_totalLiquidity -= amount;
        emit LiquidityWithdrawn(msg.sender, amount);
        i_debtToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Borrow DAI against deposited WETH collateral.
     */
    function borrow(uint256 amount) external nonReentrant moreThanZero(amount) {
        if (amount > getAvailableLiquidity()) {
            revert LendingPool__InsufficientLiquidity();
        }
        s_debtBorrowed[msg.sender] += amount;
        s_totalDebt += amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        emit Borrowed(msg.sender, amount);
        i_debtToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Repay DAI debt.
     */
    function repay(uint256 amount) external nonReentrant moreThanZero(amount) {
        uint256 debt = s_debtBorrowed[msg.sender];
        if (amount > debt) {
            amount = debt;
        }
        if (amount == 0) {
            revert LendingPool__InsufficientDebt();
        }
        s_debtBorrowed[msg.sender] -= amount;
        s_totalDebt -= amount;
        emit Repaid(msg.sender, amount);
        i_debtToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw WETH collateral if the resulting health factor stays healthy.
     */
    function withdrawCollateral(uint256 amount) external nonReentrant moreThanZero(amount) {
        if (amount > s_collateralDeposited[msg.sender]) {
            revert LendingPool__InsufficientCollateral();
        }
        s_collateralDeposited[msg.sender] -= amount;
        s_totalCollateral -= amount;
        _revertIfHealthFactorIsBroken(msg.sender);
        emit CollateralWithdrawn(msg.sender, amount);
        i_collateralToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Liquidate an undercollateralized borrower.
     * @param borrower Account with health factor < 1e18
     * @param debtToCover DAI amount the liquidator repays on behalf of the borrower
     * @dev Liquidator receives WETH equal to debtToCover in USD plus LIQUIDATION_BONUS.
     */
    function liquidate(address borrower, uint256 debtToCover) external nonReentrant moreThanZero(debtToCover) {
        uint256 startingHf = _healthFactor(borrower);
        if (startingHf >= MIN_HEALTH_FACTOR) {
            revert LendingPool__HealthFactorOk();
        }

        uint256 borrowerDebt = s_debtBorrowed[borrower];
        if (debtToCover > borrowerDebt) {
            debtToCover = borrowerDebt;
        }

        uint256 collateralToSeize = getTokenAmountFromUsd(debtToCover);
        uint256 bonus = (collateralToSeize * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        collateralToSeize += bonus;

        uint256 borrowerCollateral = s_collateralDeposited[borrower];
        if (collateralToSeize > borrowerCollateral) {
            collateralToSeize = borrowerCollateral;
        }

        s_debtBorrowed[borrower] -= debtToCover;
        s_totalDebt -= debtToCover;
        s_collateralDeposited[borrower] -= collateralToSeize;
        s_totalCollateral -= collateralToSeize;

        emit Liquidated(msg.sender, borrower, debtToCover, collateralToSeize);

        i_debtToken.safeTransferFrom(msg.sender, address(this), debtToCover);
        i_collateralToken.safeTransfer(msg.sender, collateralToSeize);
    }

    /*//////////////////////////////////////////////////////////////
                     PRIVATE / INTERNAL VIEW & PURE
    //////////////////////////////////////////////////////////////*/

    function _getAccountInformation(address user) private view returns (uint256 debtUsd, uint256 collateralUsd) {
        debtUsd = getDebtValueInUsd(s_debtBorrowed[user]);
        collateralUsd = getUsdValue(s_collateralDeposited[user]);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 debtUsd, uint256 collateralUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(debtUsd, collateralUsd);
    }

    function _calculateHealthFactor(uint256 debtUsd, uint256 collateralUsd) internal pure returns (uint256) {
        if (debtUsd == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / debtUsd;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert LendingPool__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getWethUsdPrice() private view returns (uint256) {
        int256 price = DualOracleLib.getValidatedPrice(i_primaryFeed, i_secondaryOracle, MAX_ORACLE_DEVIATION_BPS);
        return uint256(price);
    }

    /*//////////////////////////////////////////////////////////////
                         PUBLIC & EXTERNAL VIEW
    //////////////////////////////////////////////////////////////*/

    function calculateHealthFactor(uint256 debtUsd, uint256 collateralUsd) external pure returns (uint256) {
        return _calculateHealthFactor(debtUsd, collateralUsd);
    }

    function getAccountInformation(address user) external view returns (uint256 debtUsd, uint256 collateralUsd) {
        return _getAccountInformation(user);
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice USD value (1e18) of `amount` WETH using the dual-validated oracle price.
     */
    function getUsdValue(uint256 amount) public view returns (uint256) {
        uint256 price = _getWethUsdPrice();
        return ((price * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * @notice WETH amount whose USD value equals `usdAmountInWei` (1e18).
     */
    function getTokenAmountFromUsd(uint256 usdAmountInWei) public view returns (uint256) {
        uint256 price = _getWethUsdPrice();
        return (usdAmountInWei * PRECISION) / (price * ADDITIONAL_FEED_PRECISION);
    }

    function getDebtValueInUsd(uint256 daiAmount) public pure returns (uint256) {
        return ((DAI_USD_PRICE * ADDITIONAL_FEED_PRECISION) * daiAmount) / PRECISION;
    }

    function getAvailableLiquidity() public view returns (uint256) {
        if (s_totalLiquidity <= s_totalDebt) return 0;
        return s_totalLiquidity - s_totalDebt;
    }

    function getCollateralBalance(address user) external view returns (uint256) {
        return s_collateralDeposited[user];
    }

    function getDebtBalance(address user) external view returns (uint256) {
        return s_debtBorrowed[user];
    }

    function getLiquiditySupplied(address user) external view returns (uint256) {
        return s_liquiditySupplied[user];
    }

    function getTotalCollateral() external view returns (uint256) {
        return s_totalCollateral;
    }

    function getTotalDebt() external view returns (uint256) {
        return s_totalDebt;
    }

    function getTotalLiquidity() external view returns (uint256) {
        return s_totalLiquidity;
    }

    function getCollateralToken() external view returns (address) {
        return address(i_collateralToken);
    }

    function getDebtToken() external view returns (address) {
        return address(i_debtToken);
    }

    function getPrimaryFeed() external view returns (address) {
        return address(i_primaryFeed);
    }

    function getSecondaryOracle() external view returns (address) {
        return address(i_secondaryOracle);
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getMaxOracleDeviationBps() external pure returns (uint256) {
        return MAX_ORACLE_DEVIATION_BPS;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ISecondaryOracle} from "../interfaces/ISecondaryOracle.sol";
import {OracleLib} from "./OracleLib.sol";

/**
 * @title DualOracleLib
 * @notice Cross-checks a Chainlink AggregatorV3 primary feed against a secondary (Pyth-style) oracle.
 * @dev Reverts when either feed is stale, the secondary confidence band is too wide, or the
 *      absolute deviation between feeds exceeds `maxDeviationBps` (basis points of the primary).
 *      On success, returns the primary Chainlink price (8-decimal USD convention assumed by callers).
 */
library DualOracleLib {
    using OracleLib for AggregatorV3Interface;

    error DualOracleLib__InvalidPrimaryPrice();
    error DualOracleLib__InvalidSecondaryPrice();
    error DualOracleLib__SecondaryStale();
    error DualOracleLib__ConfidenceTooWide();
    error DualOracleLib__DeviationExceeded(uint256 deviationBps);

    uint256 private constant SECONDARY_TIMEOUT = 3 hours;
    uint256 private constant BPS = 10_000;
    /// @dev Max relative confidence width allowed: conf / |price| <= 2%
    uint256 private constant MAX_CONF_BPS = 200;

    /**
     * @notice Read a dual-validated USD price.
     * @param primary Chainlink AggregatorV3 feed
     * @param secondary Pyth-style secondary feed
     * @param maxDeviationBps Max allowed |primary-secondary|/primary in basis points (e.g. 100 = 1%)
     * @return price Primary feed answer after validation (same decimals as the AggregatorV3 feed)
     */
    function getValidatedPrice(AggregatorV3Interface primary, ISecondaryOracle secondary, uint256 maxDeviationBps)
        public
        view
        returns (int256 price)
    {
        (, int256 primaryAnswer,,,) = primary.staleCheckLatestRoundData();
        if (primaryAnswer <= 0) {
            revert DualOracleLib__InvalidPrimaryPrice();
        }

        (int256 secondaryPrice, uint256 conf, uint256 publishTime) = secondary.getPrice();
        if (secondaryPrice <= 0) {
            revert DualOracleLib__InvalidSecondaryPrice();
        }
        if (block.timestamp - publishTime > SECONDARY_TIMEOUT) {
            revert DualOracleLib__SecondaryStale();
        }

        uint256 absSecondary = uint256(secondaryPrice);
        if ((conf * BPS) / absSecondary > MAX_CONF_BPS) {
            revert DualOracleLib__ConfidenceTooWide();
        }

        uint256 absPrimary = uint256(primaryAnswer);
        uint256 diff = absPrimary > absSecondary ? absPrimary - absSecondary : absSecondary - absPrimary;
        uint256 deviationBps = (diff * BPS) / absPrimary;
        if (deviationBps > maxDeviationBps) {
            revert DualOracleLib__DeviationExceeded(deviationBps);
        }

        return primaryAnswer;
    }

    function getSecondaryTimeout() public pure returns (uint256) {
        return SECONDARY_TIMEOUT;
    }

    function getMaxConfidenceBps() public pure returns (uint256) {
        return MAX_CONF_BPS;
    }
}

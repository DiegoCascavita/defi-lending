// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISecondaryOracle
 * @notice Pyth-style secondary price feed used as a cross-check against Chainlink.
 * @dev Price is expected in the same decimal convention as the paired AggregatorV3 feed
 *      (typically 8 decimals for USD pairs). `conf` is an absolute confidence interval;
 *      `publishTime` is a unix timestamp of the last update.
 */
interface ISecondaryOracle {
    function getPrice() external view returns (int256 price, uint256 conf, uint256 publishTime);

    function decimals() external view returns (uint8);
}

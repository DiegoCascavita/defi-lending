// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISecondaryOracle} from "../../src/interfaces/ISecondaryOracle.sol";

/**
 * @notice Pyth-style secondary oracle mock for dual-feed deviation checks.
 */
contract MockSecondaryOracle is ISecondaryOracle {
    uint8 private immutable i_decimals;
    int256 private s_price;
    uint256 private s_conf;
    uint256 private s_publishTime;

    constructor(uint8 decimals_, int256 initialPrice, uint256 initialConf) {
        i_decimals = decimals_;
        s_price = initialPrice;
        s_conf = initialConf;
        s_publishTime = block.timestamp;
    }

    function setPrice(int256 price, uint256 conf) external {
        s_price = price;
        s_conf = conf;
        s_publishTime = block.timestamp;
    }

    function setPublishTime(uint256 publishTime) external {
        s_publishTime = publishTime;
    }

    function getPrice() external view returns (int256 price, uint256 conf, uint256 publishTime) {
        return (s_price, s_conf, s_publishTime);
    }

    function decimals() external view returns (uint8) {
        return i_decimals;
    }
}

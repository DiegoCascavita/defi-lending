// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DualOracleLib} from "../../src/libraries/DualOracleLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ISecondaryOracle} from "../../src/interfaces/ISecondaryOracle.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockSecondaryOracle} from "../mocks/MockSecondaryOracle.sol";

contract DualOracleLibTest is Test {
    MockV3Aggregator public primary;
    MockSecondaryOracle public secondary;

    uint8 public constant DECIMALS = 8;
    int256 public constant PRICE = 2000e8;
    uint256 public constant CONF = 1e6;
    uint256 public constant MAX_DEV_BPS = 100; // 1%

    function setUp() public {
        primary = new MockV3Aggregator(DECIMALS, PRICE);
        secondary = new MockSecondaryOracle(DECIMALS, PRICE, CONF);
    }

    function testValidatedPriceWhenFeedsAgree() public view {
        int256 price = DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
        assertEq(price, PRICE);
    }

    function testRevertsWhenDeviationExceeded() public {
        secondary.setPrice(PRICE + (PRICE * 2) / 100, CONF);
        vm.expectRevert(abi.encodeWithSelector(DualOracleLib.DualOracleLib__DeviationExceeded.selector, 200));
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testAllowsWithinDeviation() public {
        secondary.setPrice(PRICE + (PRICE * 50) / 10_000, CONF);
        int256 price = DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
        assertEq(price, PRICE);
    }

    function testRevertsWhenSecondaryStale() public {
        vm.warp(100 days);
        primary.updateAnswer(PRICE);
        secondary.setPrice(PRICE, CONF);
        secondary.setPublishTime(block.timestamp - 3 hours - 1);
        vm.expectRevert(DualOracleLib.DualOracleLib__SecondaryStale.selector);
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testRevertsWhenPrimaryStale() public {
        vm.warp(block.timestamp + 3 hours + 1);
        secondary.setPrice(PRICE, CONF);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testRevertsWhenConfidenceTooWide() public {
        secondary.setPrice(PRICE, uint256(PRICE) * 3 / 100);
        vm.expectRevert(DualOracleLib.DualOracleLib__ConfidenceTooWide.selector);
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testRevertsOnInvalidPrimary() public {
        primary.updateAnswer(0);
        vm.expectRevert(DualOracleLib.DualOracleLib__InvalidPrimaryPrice.selector);
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testRevertsOnInvalidSecondary() public {
        secondary.setPrice(0, CONF);
        vm.expectRevert(DualOracleLib.DualOracleLib__InvalidSecondaryPrice.selector);
        DualOracleLib.getValidatedPrice(
            AggregatorV3Interface(address(primary)), ISecondaryOracle(address(secondary)), MAX_DEV_BPS
        );
    }

    function testConstants() public pure {
        assertEq(DualOracleLib.getSecondaryTimeout(), 3 hours);
        assertEq(DualOracleLib.getMaxConfidenceBps(), 200);
    }
}

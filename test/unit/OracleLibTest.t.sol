// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract OracleLibTest is Test {
    using OracleLib for AggregatorV3Interface;

    MockV3Aggregator public feed;
    uint8 public constant DECIMALS = 8;
    int256 public constant PRICE = 2000e8;

    function setUp() public {
        feed = new MockV3Aggregator(DECIMALS, PRICE);
    }

    function testStaleCheckReturnsFreshPrice() public view {
        (, int256 answer,,,) = AggregatorV3Interface(address(feed)).staleCheckLatestRoundData();
        assertEq(answer, PRICE);
    }

    function testStaleCheckRevertsWhenStale() public {
        vm.warp(block.timestamp + 3 hours + 1);
        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        AggregatorV3Interface(address(feed)).staleCheckLatestRoundData();
    }

    function testGetTimeout() public view {
        assertEq(OracleLib.getTimeout(AggregatorV3Interface(address(feed))), 3 hours);
    }
}

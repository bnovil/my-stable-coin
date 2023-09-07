// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {PriceLib, AggregatorV3Interface} from "../../src/library/PriceLib.sol";

contract PriceLibTest is StdCheats, Test {
    using PriceLib for AggregatorV3Interface;

    MockV3Aggregator public aggregator;
    uint8 public constant DECIMALS = 8;
    int256 public constant INITAL_PRICE = 2000 ether;

    function setUp() public {
        aggregator = new MockV3Aggregator(DECIMALS, INITAL_PRICE);
    }

    function testGetTimeout() public {
        uint256 expectedTimeout = 2 hours;
        assertEq(PriceLib.getTimeout(AggregatorV3Interface(address(aggregator))), expectedTimeout);
    }

    // Foundry Bug - I have to make staleCheckLatestRoundData public
    function testPriceRevertsOnStaleCheck() public {
        vm.warp(block.timestamp + 4 hours + 1 seconds);
        vm.roll(block.number + 1);

        vm.expectRevert(PriceLib.PriceLib__StablePrice.selector);
        AggregatorV3Interface(address(aggregator)).stableCheckLatestPrice();
    }

    function testPriceRevertsOnBadAnsweredInRound() public {
        uint80 _roundId = 0;
        int256 _answer = 0;
        uint256 _timestamp = 0;
        uint256 _startedAt = 0;
        aggregator.updateRoundData(_roundId, _answer, _timestamp, _startedAt);

        vm.expectRevert(PriceLib.PriceLib__StablePrice.selector);
        AggregatorV3Interface(address(aggregator)).stableCheckLatestPrice();
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/*
 * @title OracleLib
 * @author ibourn
 * @dev OracleLib is used to check the Chainlink oracle for stale data
 * if a price is stale, the funciton will revert and render the DSC engine unusable (by design)
 * We want the DSCEngine tio freeze if prices become stale
 *
 * So if the Chainlink network explodes and you have money in ... too bad. (known issue for the moment)
 */
library OracleLib {
    error OracleLib__StalePrice();

    // eht/usd heartbeat is 1 hour, we give more time
    uint256 public constant TIMEOUT = 3 hours; // 3 * 60 * 60 seconds = 10800 seconds

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundID, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSinceUpdate = block.timestamp - updatedAt;

        if (secondsSinceUpdate > TIMEOUT) revert OracleLib__StalePrice();

        if (updatedAt == 0 || answeredInRound < roundID) {
            revert OracleLib__StalePrice();
        }

        return (roundID, price, startedAt, updatedAt, answeredInRound);
    }

    function getTimeout(AggregatorV3Interface /* chainlinkFeed */ ) public pure returns (uint256) {
        return TIMEOUT;
    }
}

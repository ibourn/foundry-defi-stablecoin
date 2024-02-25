// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way funciton are called (to avoid waste runs)

// Our Invariants :
// 1. The total supply of the token should always be less than the total value of collateral
// 2. Getter view functions should never revert

pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

/**
 * @title OpenInvariantsTest
 * @dev OpenInvariantsTest is a contract to test the invariants of the DecentralizedStableCoin
 * without using the handler
 */
contract Invariants is StdInvariant, Test {
    DeployDSC deployDSC;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() public {
        deployDSC = new DeployDSC();
        (dsc, dscEngine, config) = deployDSC.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

        uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("wethValue: %s, wbtcValue, %s, totalSupply: %s", wethValue, wbtcValue, totalSupply);
        console.log("Times mint is called: %s", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        // call all the view functions
        // if any of them revert, the test will fail
        // dscEngine.getTokenAmountFromUsd(address token, uint256 usdAmountinWei);

        // dscEngine.getAccountCollateralValueInUsd(address user);

        // dscEngine.getUsdValue(address token, uint256 amount);

        dscEngine.getDsc();

        dscEngine.getCollateralTokens();

        // dscEngine.getCollateralTokenPriceFeed(address token);

        // dscEngine.getCollateralBalanceOfUser(address user, address token);

        // dscEngine.getAccountInformation(address user);

        dscEngine.getAdditionalFeedPrecision();

        dscEngine.getPrecision();

        dscEngine.getMinHealthFactor();

        // dscEngine.getHealthFactor(address user)

        // dscEngine.calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd);

        dscEngine.getLiquidationThreshold();

        dscEngine.getLiquidationBonus();
    }
}
// first invariant => 128 runs : 1.36s -> 1000 runs : 14.95s (1000 runs * 128 depth)

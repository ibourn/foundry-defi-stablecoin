// // SPDX-License-Identifier: MIT

// // Handler is going to narrow down the way funciton are called (to avoid waste runs)

// // Our Invariants :
// // 1. The total supply of the token should always be less than the total value of collateral
// // 2. Getter view functions should never revert

// pragma solidity 0.8.20;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// /**
//  * @title OpenInvariantsTest
//  * @dev OpenInvariantsTest is a contract to test the invariants of the DecentralizedStableCoin
//  * without using the handler
//  */
// contract OpenInvariants is StdInvariant, Test {
//     DeployDSC deployDSC;
//     DSCEngine dscEngine;
//     DecentralizedStableCoin dsc;
//     HelperConfig config;
//     address weth;
//     address wbtc;

//     function setUp() public {
//         deployDSC = new DeployDSC();
//         (dsc, dscEngine, config) = deployDSC.run();
//         (,, weth, wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dscEngine));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt (dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

//         assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
// // first invariant => 128 runs : 1.36s -> 1000 runs : 14.95s (1000 runs * 128 depth)

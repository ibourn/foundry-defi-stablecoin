// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way funciton are called (to avoid waste runs)

// Our Invariants :
// 1. The total supply of the token should always be less than the total value of collateral
// 2. Getter view functions should never revert

pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    MockV3Aggregator wethUsdPriceFeed;

    ERC20Mock weth;
    ERC20Mock wbtc;

    // ghost variables
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max uint96 value is 2^96 - 1 = 79_228_162_514_264_337_593_543_950_335

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        wethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    /**
     *
     *             DSCEngine functions
     *
     */
    function mint(uint256 amount, uint256 addressSeed) public {
        // ! call with random addresses
        // need to call only with address that have collateral
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);

        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);
        if (maxDscToMint < 0) {
            return;
        }
        // timesMintIsCalled++;
        amount = bound(amount, 0, uint256(maxDscToMint));
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dscEngine.mintDsc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        collateralAmount = bound(collateralAmount, 1, MAX_DEPOSIT_SIZE);

        // if (collateralAmount > MAX_DEPOSIT_SIZE) {
        //     return;
        // }
        // if (collateralAmount <= 0) {
        //     return;
        // }

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, collateralAmount);
        collateral.approve(address(dscEngine), collateralAmount);
        dscEngine.depositCollateral(address(collateral), collateralAmount);
        vm.stopPrank();
        // caveat: we are not checking if the user already deposited collateral (risk double push)
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 collateralAmount) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        collateralAmount = bound(collateralAmount, 0, maxCollateralToRedeem);
        if (collateralAmount == 0) {
            return;
        }

        // if ((maxCollateralToRedeem - collateralAmount) <= 0) {
        //     return;
        // }
        // if (collateralAmount <= 0) {
        //     return;
        // }
        // if (collateralAmount > maxCollateralToRedeem) {
        //     return;
        // }
        // if (collateralAmount > type(uint96).max) {
        //     return;
        // }

        // https://github.com/Cyfrin/foundry-defi-stablecoin-f23/pull/35
        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), collateralAmount);
    }

    function burnDsc(uint256 amountDsc, uint256 addressSeed) public {
        // Must burn at least 1 DSC
        // Balance could be 0 but bound 1 - 0 will cause max < min
        // So let min == 0 and return if amountDsc == 0
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
        if (amountDsc == 0) {
            return;
        }
        vm.startPrank(msg.sender);
        dsc.approve(address(dscEngine), amountDsc);
        dscEngine.burnDsc(amountDsc);
        vm.stopPrank();
    }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        uint256 userHealthFactor = dscEngine.getHealthFactor(userToBeLiquidated);
        if (userHealthFactor >= minHealthFactor) {
            return;
        }
        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        dscEngine.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    // /*
    //  * Only the DSCEngine can mint DSC!
    //  */
    // function mintDsc(uint256 amountDsc) public {
    //     amountDsc = bound(amountDsc, 0, MAX_DEPOSIT_SIZE);
    //     vm.prank(dsc.owner());
    //     dsc.mint(msg.sender, amountDsc);
    // }

    /**
     *
     *             Aggregator functions
     *
     */

    // /**
    //  * Protocol i sfine as long as collateralization is 110% - 200%
    //  * if collateralization is below 110% protocol is broken
    //  *
    //  * Breaks invariant in case of price quickly plummeting
    //  * => need to fix
    //  */
    // function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
    //     int256 intNewPrice = int256(uint256(newPrice));
    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    //     MockV3Aggregator priceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(collateral)));

    //     priceFeed.updateAnswer(intNewPrice);
    // }

    /**
     *
     *             DecentralizedStableCoin functions
     *
     */
    // function transferDsc(uint256 amountDsc, address to) public {
    //     if (to == address(0)) {
    //         to = address(1);
    //     }
    //     amountDsc = bound(amountDsc, 0, dsc.balanceOf(msg.sender));
    //     vm.prank(msg.sender);
    //     dsc.transfer(to, amountDsc);
    // }

    /**
     *
     *             Helpers functions
     *
     */
    function _getCollateralFromSeed(uint256 seed) internal view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address wethUsdPriceFeed;
    address weth;
    address wbtcUsdPriceFeed;
    address wbtc;

    uint256 private constant ADDITIONNAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // => need to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant COLLATERAL_TO_COVER = 20 ether;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");

    /* events */
    event CollateralDeposited(address indexed USER, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
        console.log("DSCEngineTest / setUP : USER address ", USER);
        console.log("DSCEngineTest / setUP : LIQUIDATOR address ", LIQUIDATOR);
        console.log("DSCEngineTest / setUP : deployer address ", address(deployer));
    }

    /* constructor test */

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function test_RevertIfTokenLenghtDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /* price test */
    function test_GetUsdValue() public {
        uint256 ethAmount = 15e18; // 15e18 *2000$/USD = 30_000e18
        uint256 expectedUsd = 30_000e18; // not working for fork-url $SEPOLIA (cuase of "real price feed")
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function getTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH,  $100 -> 0.05 ETH
        uint256 expectedEth = 0.05 ether;
        uint256 actualEth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedEth, actualEth);
    }

    /* deposit collateral test */
    function test_RevertIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_RevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(ranToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    function test_CanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function test_CanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositValueInUsd = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(COLLATERAL_AMOUNT, expectedDepositValueInUsd);
    }

    // this test needs it's own setup
    function test_RevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        // load DSC with failing transferFrom
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), COLLATERAL_AMOUNT);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    /* depositCollateralAndMintDsc test */

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function test_CanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    function test_RevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        // get amount of DSC to mint equivalent to the collateral amount
        uint256 amountToMint =
            (COLLATERAL_AMOUNT * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);

        // amountToMint doesn't respect collateralization ratio (1-1 instead of 2-1)
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
    }

    /* mintDsc test */

    function test_RevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function test_CanMintDsc() public depositedCollateral {
        vm.prank(USER);
        dscEngine.mintDsc(AMOUNT_TO_MINT);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    function test_RevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            (COLLATERAL_AMOUNT * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT));

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function test_RevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), COLLATERAL_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    /* burnDsc test */

    function test_RevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function test_CantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function test_CanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /* redeemCollateral test */

    function test_RevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_CanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function test_EmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    // this test needs it's own setup
    function test_RevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), COLLATERAL_AMOUNT);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), COLLATERAL_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    /* redeemCollateralForDsc test__ */

    function test_MustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function test_CanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.redeemCollateralForDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    /* healthFactor test */

    function test_ProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function test_HealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    /* Liquidation test */

    function test_CantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        // ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        // dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    modifier liquidated() {
        // user deposits 10 ETH and mint 100 DSC
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.stopPrank();
        int256 wethUsdUpdatedPrice = 18e8;
        // ETH : $2000 -> $18 (env= /112)
        // To cover 100$ DSC, we need 200$ of collateral 200/18 == 11.11 ETH
        // COLLATERAL_TO_COVER == 20 ETH so >> amount to cover
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(wethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        // Liquidator will pay the user's debt, so he needs to mint 100 DSC
        // DSC loan of user will be erased
        // DSC will be transfer from liquidator to contract to burn it
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_TO_COVER);
        dscEngine.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, AMOUNT_TO_MINT);
        dsc.approve(address(dscEngine), AMOUNT_TO_MINT);
        dscEngine.liquidate(weth, USER, AMOUNT_TO_MINT); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function test_LiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dscEngine.getLiquidationBonus());
        // Liquidator deposited 20 ether and minted 100 DSC for 11.11... ETH => his balance then : 0
        // 100 DSC is now 5.55... ETH
        // reward is 5.55... * 1.1 = 6.11... ETH => his balance now : 6.11...
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function test_UserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT)
            + (dscEngine.getTokenAmountFromUsd(weth, AMOUNT_TO_MINT) / dscEngine.getLiquidationBonus());

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        // user deposited 10 ETH and minted 100 DSC and ETH : $2000 -> $18
        // user balance = (10 * 18) - (6.11... * 18) = 180 - 110 = 70...2 (70e18 usd)
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function test_LiquidatorTakesOnUsersDebt() public liquidated {
        // loan from user is erased
        // but liquidator minted 100 DSC to pay it => his DSC was sent to the contract to be burned
        // he then should burn it with the equivalent received from the liquidation
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, AMOUNT_TO_MINT);
    }

    // TRY bug => liquidator can't burn DSC (he has balance but we transfered it to the contract to burn it)
    // FAIL. Reason: ERC20InsufficientBalance(0x0C88b4C83333fBF7C6469bFF99449bA16BCBaB63, 0, 100000000000000000000 [1e20]
    // function test_LiquidatorCanBurnDscAfterLiquidation() public liquidated {
    //     (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);
    //     console.log("liquidatorDscMinted after liquidation : %s", liquidatorDscMinted);

    //     vm.startPrank(LIQUIDATOR);
    //     dsc.approve(address(dscEngine), liquidatorDscMinted);
    //     dscEngine.burnDsc(liquidatorDscMinted);
    //     vm.stopPrank();

    //     uint256 liquidatorDscBalance = dsc.balanceOf(LIQUIDATOR);
    //     console.log("liquidatorDscBalance After burn : %s", liquidatorDscBalance);
    //     assertEq(liquidatorDscBalance, 0);
    // }

    function test_LiquidatorHasNoDscAfterLiquidation() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);
        // console.log("liquidatorDscMinted after liquidation : %s", liquidatorDscMinted);

        // vm.startPrank(LIQUIDATOR);
        // dsc.approve(address(dscEngine), liquidatorDscMinted);
        // dscEngine.burnDsc(liquidatorDscMinted);
        // vm.stopPrank();

        uint256 liquidatorDscBalance = dsc.balanceOf(LIQUIDATOR);
        console.log("dscEngine : liquidatorDscMinted After burn : %s", liquidatorDscMinted);
        console.log("dsc : liquidatorDscBalance After burn : %s", liquidatorDscBalance);
        // He has no more DSC but there's still an amount of minted DSC in the engine registry
        assertEq(liquidatorDscMinted, 100000000000000000000);
        assertEq(liquidatorDscBalance, 0);
    }

    function test_MustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(wethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), COLLATERAL_AMOUNT);
        mockDsce.depositCollateralAndMintDsc(weth, COLLATERAL_AMOUNT, AMOUNT_TO_MINT);
        vm.stopPrank();

        // Arrange - Liquidator
        uint256 collateralToCover = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, AMOUNT_TO_MINT);
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    // // SEE DSCEngine.sol _burnDsc comment
    // function test_LiquidatorCanBurnDscNeededForLiquidation() public liquidated {
    //     // uint256 liquidatorDscMinted = dsc.balanceOf(LIQUIDATOR);
    //     (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(LIQUIDATOR);

    //     vm.startPrank(LIQUIDATOR);
    //     dsc.approve(address(dscEngine), liquidatorDscMinted);
    //     dscEngine.burnDsc(liquidatorDscMinted);
    //     vm.stopPrank();

    //     uint256 liquidatorDscBalance = dsc.balanceOf(LIQUIDATOR);
    //     assertEq(liquidatorDscBalance, 0);
    // }

    function test_UserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    /* Getters test */

    function test_GetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, wethUsdPriceFeed);
    }

    function test_GetCollateralTokens() public {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function test_GetMinHealthFactor() public {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function test_GetLiquidationThreshold() public {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function test_GetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function test_GetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, COLLATERAL_AMOUNT);
    }

    function test_GetAccountCollateralValueInUsd() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), COLLATERAL_AMOUNT);
        dscEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        uint256 collateralValue = dscEngine.getAccountCollateralValueInUsd(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, COLLATERAL_AMOUNT);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function test_GetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }
}

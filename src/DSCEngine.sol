// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity 0.8.20;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/Script.sol";

/*
 * @title DSCEngine
 * @author ibourn
 *
 * System design to me minimalistic and simple to maintain a '1 token to 1 USD' peg.
 * StableCoin properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Satble
 *
 * This is similar to DAI without governance, with no fees, and if only backed by WETH and WBTC
 *
 * Our DSC system should always be overcollateralized. Value of all collateral should never be <= $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC system, it handles all the logic for minting and redeeming DSC, depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS system.
 */
contract DSCEngine is ReentrancyGuard {
    /* errors */
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustMatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    /* state variables */
    uint256 private constant ADDITIONNAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // => need to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    // mapping (address => bool) private s_tokenAllowed;
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    mapping(address user => mapping(address token => uint256 amount)) private s_userToCollateralDeposited;
    mapping(address user => uint256 dscAmountMinted) private s_userToDscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /* events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    /* modifiers */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_tokenToPriceFeed[tokenAddress] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /* functions */

    /*
     * @notice The constructor will set the price feeds for the collateral tokens
     * @dev tokenAddresses and priceFeedAddresses must match the same index
     * @param tokenAdresses The addresses of the tokens to be used as collateral
     * @param priceFeedAddresses The addresses of the price feeds for the collateral tokens
     * @param dscAddress The address of the DSC contract
     */
    constructor(address[] memory tokenAdresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        // owner deploy the DSC contract so no interest to mess with the size of array
        if (tokenAdresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustMatch();
        }
        for (uint256 i; i < tokenAdresses.length;) {
            s_tokenToPriceFeed[tokenAdresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAdresses[i]);
            console.log(
                "DSCEngine / constructor : tokenAdresses[%s] %s => priceFeed %s ",
                i,
                tokenAdresses[i],
                priceFeedAddresses[i]
            );
            // i always inferior to tokenAdresses.length
            unchecked {
                ++i;
            }
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /* external functions */

    /*
     * @notice This function will deposit collateral and mint DSC in one transaction
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param collateralAmount The amount of collateral to be deposited
     * @param dscAmountToMint The amount of DSC to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 dscAmountToMint
    ) external {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDsc(dscAmountToMint);
    }

    /*
     * @notice Follows CEI pattern (checks in modofiers)
     * @param tokenCollateralAddress The address of the token to be used as collateral
     * @param collateralAmount The amount of collateral to be deposited
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_userToCollateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);

        bool succes = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!succes) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @notice This funciton burns DSC and redeems collateral in one transaction
     * @param collateralTokenAddress The address of the token to be used as collateral
     * @param collateralAmount The amount of collateral to be redeemed
     * @param dscAmountToBurn The amount of DSC to burn
     */
    function redeemCollateralForDsc(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmountToBurn)
        external
    {
        burnDsc(dscAmountToBurn);
        redeemCollateral(collateralTokenAddress, collateralAmount);
        // redeemCollateral already checks health factor
    }

    /*
     * @notice In order to redeem collateral :
     * 1. health factor must be over 1 AFTER the redemption
     * DRY => don't repeat yourself : need future refactor
     * @param collateralTokenAddress The address of the token to be redeemed
     * @param collateralAmount The amount of collateral to be redeemed
     */
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, collateralTokenAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * Check if the collateral value > DSC value, checks PriceFeed, values..
     *
     * @notice Follows CEI pattern (checks in modifiers)
     * @notice They must have more collateral value than the minimum threshold
     * @param dscAmountToMint The amount of DSC to mint
     */
    function mintDsc(uint256 dscAmountToMint) public moreThanZero(dscAmountToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += dscAmountToMint;
        // if they minted too much should revert
        _revertIfHealthFactorIsBroken(msg.sender);

        // ??? => what if mint makes the health factor go below 1 ??? => shouldn't check if mint is possible before minting ???
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
     * @notice This function will burn DSC
     * @param amount The amount of DSC to burn
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);
        _revertIfHealthFactorIsBroken(msg.sender); // Shouldn't be hit due to the burn. High probality of being removed
    }

    /*
     * @notice The liquidator need to have amount of DSC to cover the debt (will receive the equivalent in collateral + bonus)
     * @notice If someone is almost undercollateralized, we will pay you to liquidate them
     * ex : $100 ETH backing 50 DSC, then ETH price drops 
     * -> $75 ETH backing 50 DSC => liquidator take 75$ backing and burn off 50 DSC
     * @notice You can partially liquidate someone (as long as their health factor is improved above 1)
     * @notice You will get a liquidation bonus for taking user's funds
     * @notice This funciton working assumes the protocol will be roughly 200% overcollateralized in order to this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive liquidators.
     * @param collateralToken The address of the token to liquidate
     * @param user The address of the user to liquidate. Their health factor should be below MIN_HEALTH_FACTOR
     * @param dscDebtToCover The amount of DSC to to burn to improve user's health factor
     */
    function liquidate(address collateralTokenAddress, address user, uint256 dscDebtToCover)
        external
        moreThanZero(dscDebtToCover)
        nonReentrant
    {
        // need check health factor
        uint256 startingHealthFactor = _healthFactor(user);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk();
        }
        // We want to burn dsc debt and take collateral
        // Bad user : $140 ETH, 100 DSC
        // debtToCover = 100 DSC => 100 DSC == how much ETH we need to take : 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralTokenAddress, dscDebtToCover);
        // And give them a 10% bonus => we are giving the liquidator $110 of WETH for $100 of DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra ammounts in treasury
        uint256 collateralBonus = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + collateralBonus;

        // As bonus is fixed, pb if can't redeem enough
        // https://www.codehawks.com/finding/clm81m6ub01jtw9rukyr1h50o
        // uint256 totalDepositedCollateral = s_userToCollateralDeposited[user][collateralTokenAddress];
        // if (tokenAmountFromDebtCovered < totalDepositedCollateral && totalCollateralToRedeem > totalDepositedCollateral)
        // {
        //     totalCollateralToRedeem = totalDepositedCollateral;
        // }

        _redeemCollateral(user, msg.sender, collateralTokenAddress, totalCollateralToRedeem);
        // Burn the DSC (transfer from liquidator to this contract and burn it)
        _burnDsc(user, msg.sender, dscDebtToCover);
        // Check if the user's health factor is now above 1
        uint256 endingHealthFactor = _healthFactor(user);
        if (endingHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /* private & internal functions */

    /*
     * @notice Returns the haelth factor corresponding to the total DSC minted and the total collateral value in USD
     * @param totalDscMinted The total amount of DSC minted
     * @param collateralValueInUsd The total collateral value in USD
     */
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // if no DSC minted, return max value (it avoids division by 0)
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * !!! But what about liquidator DSC ?
     * he mint to pay off debt then his DSC are transfered to the contract to be burned
     * So he has a loan but how to burn it ? => he can't now more send DSC to the contract
     */

    /*
     * @notice To burn DSC : transfer DSC from user to this contract and burn it
     * @dev Low level inrernatl function, do not call unless funciton calling it is checking for health factor being broken
     * @param onBehalfOf The address of the user to burn DSC for
     * @param dscFrom The address of the user to burn DSC from
     * @param dscAmountToBurn The amount of DSC to burn
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 dscAmountToBurn) private {
        s_userToDscMinted[onBehalfOf] -= dscAmountToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), dscAmountToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(dscAmountToBurn);
    }

    /*
     * @param from The address of the user to redeem collateral from
     * @param to The address of the user to redeem collateral to
     * @param collateralTokenAddress The address of the token to be redeemed
     * @param collateralAmount The amount of collateral to be redeemed
     */
    function _redeemCollateral(address from, address to, address collateralTokenAddress, uint256 collateralAmount)
        private
    {
        // if they redeem too much solidity make revert due to underflow check
        s_userToCollateralDeposited[from][collateralTokenAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);

        bool succes = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!succes) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * @notice Returns the total DSC minted and the total collateral value in USD
     * @param user The address of the user to get the information for
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_userToDscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValueInUsd(user);
    }

    /*
     * @notice Returns the health factor of a user : how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     * @param user The address of the user to get the health factor for
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        // uint256 collateralAdjustedForThreshold =
        //     (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // consider 50% of the collateral value

        // // $150 ETH / 100 DSC = 1.5
        // // adjusted : 150 * 50 / 100 => 75 / 100 = 0.75 => HF < 1

        // // $1000 ETH / 100 DSC = 10
        // // adjusted : 1000 * 50 / 100 => 500 / 100 = 5 => HF > 1
        // return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    /*
     * 1. check Health Factor (do they have enough collateral)
     * 2. if not, revert
     * @param user The address of the user to check the health factor for
     */
    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /* pure & view functions */

    /*
     * @notice Returns the amount of tokens equivalent to the amount of USD
     * @param token The address of the token to get the amount for
     * @param usdAmountinWei The amount of USD to get the amount for
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountinWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // Eth price : 2000$ & usdAmountinWei : 1000 => 1000e18 * 1e18 / 2000e8 * 1e10 = 0.5 ETH (5e17)
        return (usdAmountinWei * PRECISION) / (uint256(price) * ADDITIONNAL_FEED_PRECISION);
    }

    /*
     * @notice Returns the total collateral value in USD of a user
     * @param user The address of the user to get the collateral value for
     */
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price to get the USD value at this moment
        for (uint256 i; i < s_collateralTokens.length;) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_userToCollateralDeposited[user][token];

            totalCollateralValueInUsd += getUsdValue(token, amountDeposited);
            // i always inferior to s_collateralTokens.length
            unchecked {
                ++i;
            }
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_tokenToPriceFeed[token]);
        console.log("DSCEngine / getUsdValue : token %s, amount %s", token, amount);
        console.log(
            "DSCEngine / getUsdValue : priceFeed mapping/result %s / %s", s_tokenToPriceFeed[token], address(priceFeed)
        );

        (, int256 price,,,) = priceFeed.latestRoundData();
        console.log("DSCEngine / getUsdValue : price %s", uint256(price));
        // ex: 1 ETH = 1000$
        // The return value from CL will be 1000 * 1e8 (or 10^8) cause Eth/USD & BTC/USD have 8 decimals
        // return price * amount; // too big : (1000 * 1e8) * (1000 * 1e18) = 1e26
        // => (1000 * 1e8 *(1e10)) * (1000 * 1e18) = 1e26
        return (uint256(price) * ADDITIONNAL_FEED_PRECISION * amount) / PRECISION;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) public view returns (address) {
        return s_tokenToPriceFeed[token];
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_userToCollateralDeposited[user][token];
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONNAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }
}

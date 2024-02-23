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

    /* state variables */
    uint256 private constant ADDITIONNAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // => need to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    // mapping (address => bool) private s_tokenAllowed;
    mapping(address token => address priceFeed) private s_tokenToPriceFeed;
    mapping(address user => mapping(address token => uint256 amount))
        private s_userToCollateralDeposited;
    mapping(address user => uint256 dscAmountMinted) private s_userToDscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /* events */
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed user,
        address indexed token,
        uint256 indexed amount
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
    constructor(
        address[] memory tokenAdresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        // owner deploy the DSC contract so no interest to mess with the size of array
        if (tokenAdresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustMatch();
        }
        for (uint256 i; i < tokenAdresses.length; ) {
            s_tokenToPriceFeed[tokenAdresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAdresses[i]);
            console.log("DSCEngine / constructor : tokenAdresses[%s] %s => priceFeed %s ", i, tokenAdresses[i], priceFeedAddresses[i]);
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
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 collateralAmount
    )
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_userToCollateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += collateralAmount;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            collateralAmount
        );

        bool succes = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            collateralAmount
        );
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
    function redeemCollateralForDsc(address collateralTokenAddress, uint256 collateralAmount, uint256 dscAmountToBurn) external {
        burnDsc(dscAmountToBurn);
        redeemCollateral(collateralTokenAddress, collateralAmount);
        // redeemCollateral already checks health factor
    }

    /*
     * @notice In order to redeem collateral :
     * 1. health factor must be over 1 AFTER the redemption
     * DRY => don't repeat yourself : need future refactor
     */
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount) public moreThanZero(collateralAmount) nonReentrant() {
        // if they redeem too much solidity make revert due to underflow check
        s_userToCollateralDeposited[msg.sender][collateralTokenAddress] -= collateralAmount;
        emit CollateralRedeemed(msg.sender, collateralTokenAddress, collateralAmount);

        bool succes = IERC20(collateralTokenAddress).transfer(msg.sender, collateralAmount);
        if (!succes) {
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    } 

    /*
     * Check if the collateral value > DSC value, checks PriceFeed, values..
     *
     * @notice Follows CEI pattern (checks in modifiers)
     * @notice They must have more collateral value than the minimum threshold
     * @param dscAmountToMint The amount of DSC to mint
     */
    function mintDsc(
        uint256 dscAmountToMint
    ) public moreThanZero(dscAmountToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += dscAmountToMint;
        // if they minted too much should revert
        _revertIfHealthFactorIsBroken(msg.sender);

        // ??? => what if mint makes the health factor go below 1 ??? => shouldn't check if mint is possible before minting ???
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_userToDscMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // Shouldn't be hit due to the burn. High probality of being removed
    }

    function liquidate() external {}

    function getHealthFactor() external view returns (uint256) {}

    /* private & internal functions */

    /*
     * @notice Returns the health factor of a user : how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     *
     *
     */
    function _getAccountInformation(
        address user
    )
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
     *
     *
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (
            uint256 totalDscMinted,
            uint256 totalCollateralValueInUsd
        ) = _getAccountInformation(user);

        uint256 collateralAdjustedForThreshold = (totalCollateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // consider 50% of the collateral value

        // $150 ETH / 100 DSC = 1.5
        // adjusted : 150 * 50 / 100 => 75 / 100 = 0.75 => HF < 1

        // $1000 ETH / 100 DSC = 10
        // adjusted : 1000 * 50 / 100 => 500 / 100 = 5 => HF > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /*
     * 1. check Health Factor (do they have enough collateral)
     * 2. if not, revert
     */
    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /* pure & view functions */

    function getAccountCollateralValueInUsd(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price to get the USD value at this moment
        for (uint256 i; i < s_collateralTokens.length; ) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_userToCollateralDeposited[user][token];

            totalCollateralValueInUsd += getUsdValue(token, amountDeposited);
            // i always inferior to s_collateralTokens.length
            unchecked {
                ++i;
            }
        }
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_tokenToPriceFeed[token]
        );
        console.log("DSCEngine / getUsdValue : token %s, amount %s", token, amount);
        console.log("DSCEngine / getUsdValue : priceFeed mapping/result %s / %s", s_tokenToPriceFeed[token], address(priceFeed));

        (, int256 price, , , ) = priceFeed.latestRoundData();
        console.log("DSCEngine / getUsdValue : price %s", uint256(price));
        // ex: 1 ETH = 1000$
        // The return value from CL will be 1000 * 1e8 (or 10^8) cause Eth/USD & BTC/USD have 8 decimals
        // return price * amount; // too big : (1000 * 1e8) * (1000 * 1e18) = 1e26
        // => (1000 * 1e8 *(1e10)) * (1000 * 1e18) = 1e26
        return
            (uint256(price) * ADDITIONNAL_FEED_PRECISION * amount) / PRECISION;
    }
}

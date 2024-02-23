// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
    }

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8; // 2000 * 10 ** DECIMALS
    int256 public constant BTC_USD_PRICE = 1000e8; // 1000 * 10 ** DECIMALS
    uint256 public constant ETH_INITIAL_BALANCE = 1000 * 10 ** DECIMALS; // 1000e8
    uint256 public constant BTC_INITIAL_BALANCE = 1000 * 10 ** DECIMALS; // 1000e8
    uint256 public constant DEFAULT_ANVIL_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
   
    NetworkConfig public activeNetworkConfig;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        // https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1
        // custom weth9 and wbtc already deployed
        return
            NetworkConfig({
                wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
                wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
                weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
                wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
                deployerKey: vm.envUint("PRIVATE_KEY")
            });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator wethUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            ETH_USD_PRICE
        );
        ERC20Mock wethMock = new ERC20Mock(
            "Wrapped Ether",
            "WETH",
            msg.sender,
            ETH_INITIAL_BALANCE
        );

        MockV3Aggregator wbtcUsdPriceFeed = new MockV3Aggregator(
            DECIMALS,
            BTC_USD_PRICE
        );
        ERC20Mock wbtcMock = new ERC20Mock(
            "Wrapped Bitcoin",
            "WBTC",
            msg.sender,
            BTC_INITIAL_BALANCE
        );
        vm.stopBroadcast();

        console.log("HelperConfig / getOrCreateAnvilEthConfig : wethUsdPriceFeed: ", address(wethUsdPriceFeed));
        console.log("HelperConfig / getOrCreateAnvilEthConfig : wbtcUsdPriceFeed: ", address(wbtcUsdPriceFeed));
        console.log("HelperConfig / getOrCreateAnvilEthConfig : wethMock: ", address(wethMock));
        console.log("HelperConfig / getOrCreateAnvilEthConfig : wbtcMock: ", address(wbtcMock));

        return
            NetworkConfig({
                wethUsdPriceFeed: address(wethUsdPriceFeed),
                wbtcUsdPriceFeed: address(wbtcUsdPriceFeed),
                weth: address(wethMock),
                wbtc: address(wbtcMock),
                deployerKey: DEFAULT_ANVIL_KEY
            });
    }
}

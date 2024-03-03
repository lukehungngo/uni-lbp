// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {PriceMath} from "../src/lib/PriceMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract PriceMathTest is Test {
    using PriceMath for uint256;
    using PriceMath for uint160;
    using TickMath for uint160;

    address link = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address dai = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    ERC20 token0 = ERC20(link);
    ERC20 token1 = ERC20(dai);

    function setUp() public {
        vm.createSelectFork({
            urlOrAlias: "https://mainnet.infura.io/v3/1f15d22470684b4a8c92c130925fc679",
            blockNumber: 19_312_842
        });
        deal(link, address(this), 10000 ether);
        deal(dai, address(this), 10000 ether);
    }

    function testGetPrice() public {
        uint160 sqrtPriceX96 = 367261546943856803819000;
        uint256 price = sqrtPriceX96.getPrice(link, usdc);
        console2.log("Price", price / 1e12);
    }

    function testGetSqrtPriceX96() public {
        uint256 price = 100000000;
        uint8 priceDecimal = 6;
        uint160 sqrtPriceX96 = price.getSqrtPriceX96(priceDecimal, link, usdc);
        int24 tick = sqrtPriceX96.getTickAtSqrtRatio();
        console2.log("sqrtPriceX96", sqrtPriceX96);
        console2.log("tick", tick);
    }
}

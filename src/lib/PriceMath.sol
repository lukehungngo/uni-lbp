// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

library PriceMath {
    using Math for uint256;
    using SafeMath for uint256;
    using TickMath for int24;

    function getSqrtPriceX96(uint256 price, uint8 priceDecimal, address token0_, address token1_)
        external
        view
        returns (uint160 sqrtPriceX96)
    {
        ERC20 token0 = ERC20(token0_);
        ERC20 token1 = ERC20(token1_);
        uint8 decimals0 = token0.decimals();
        uint8 decimals1 = token1.decimals();
        uint256 token0Amount = 10 ** decimals0;
        uint256 token1Amount = 10 ** decimals1;
        uint256 tempSqrtPriceX96 = price.sqrt() * (2 ** 96);
        tempSqrtPriceX96 = tempSqrtPriceX96 / (10 ** priceDecimal).sqrt();
        tempSqrtPriceX96 = tempSqrtPriceX96 / token0Amount.sqrt();
        tempSqrtPriceX96 = tempSqrtPriceX96 * token1Amount.sqrt();
        sqrtPriceX96 = uint160(tempSqrtPriceX96);
    }

    function getPrice(uint160 sqrtPriceX96, address token0_, address token1_) external view returns (uint256) {
        ERC20 token0 = ERC20(token0_);
        ERC20 token1 = ERC20(token1_);
        uint8 decimals0 = token0.decimals();
        uint8 decimals1 = token1.decimals();
        uint256 price = uint256(sqrtPriceX96).mul(uint256(sqrtPriceX96)).mul(1e18) >> (96 * 2);
        return price.mul(10 ** (decimals0 - decimals1));
    }

    function getPriceAtTick(int24 tick, address token0_, address token1_) external view returns (uint256) {
        uint160 sqrtPriceX96 = tick.getSqrtRatioAtTick();
        ERC20 token0 = ERC20(token0_);
        ERC20 token1 = ERC20(token1_);
        uint8 decimals0 = token0.decimals();
        uint8 decimals1 = token1.decimals();
        uint256 price = uint256(sqrtPriceX96).mul(uint256(sqrtPriceX96)).mul(1e18) >> (96 * 2);
        return price.mul(10 ** (decimals0 - decimals1));
    }
}

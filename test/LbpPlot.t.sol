// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";
import "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {LiquidityBootstrappingHooksImplementation} from "./LiquidityBootstrappingHooksImplementation.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {PriceMath} from "../src/lib/PriceMath.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Plot} from "@solplot/src/Plot.sol";

contract LiquidityBootstrappingHooksTest is Test, Deployers, Plot {
    using PoolIdLibrary for PoolKey;
    using PriceMath for uint256;
    using PriceMath for uint160;
    using PriceMath for int24;
    using TickMath for uint160;
    using TickMath for int24;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;
    uint160 constant SQRT_RATIO_MAX = 792281625142643375935000; // 1 LINK = 100 USD, tick = -230271
    uint160 constant SQRT_RATIO_MIN = 79228162514264337593000; // 1 LINK = 1 USD, tick = -276325

    address link = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    ERC20 token0 = ERC20(link);
    ERC20 token1 = ERC20(usdc);
    PoolManager manager;
    LiquidityBootstrappingHooksImplementation liquidityBootstrappingHooks = LiquidityBootstrappingHooksImplementation(
        address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG))
    );
    PoolKey key;
    PoolId id;

    PoolSwapTest swapRouter;
    PoolModifyPositionTest modifyPositionRouter;
    LiquidityInfo liquidityInfo;
    uint256 constant lbpDuration = 1 days;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
        bool isToken0; // Whether the token to provide liquidity for is token0
    }

    function setUp() public {
        vm.createSelectFork({
            urlOrAlias: "https://mainnet.infura.io/v3/1f15d22470684b4a8c92c130925fc679",
            blockNumber: 19_312_842
        });
        deal(link, address(this), 10000000 ether);
        deal(usdc, address(this), 0 ether);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }
        console2.log(token0.name(), token1.name());

        manager = new PoolManager(500000);

        vm.record();
        LiquidityBootstrappingHooksImplementation impl =
            new LiquidityBootstrappingHooksImplementation(manager, liquidityBootstrappingHooks);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(liquidityBootstrappingHooks), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(liquidityBootstrappingHooks), slot, vm.load(address(impl), slot));
            }
        }
        key = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            MIN_TICK_SPACING,
            liquidityBootstrappingHooks
        );
        id = key.toId();

        swapRouter = new PoolSwapTest(manager);
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));

        token0.approve(address(liquidityBootstrappingHooks), type(uint256).max);
        token1.approve(address(liquidityBootstrappingHooks), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(modifyPositionRouter), type(uint256).max);
        token1.approve(address(modifyPositionRouter), type(uint256).max);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + lbpDuration),
            minTick: SQRT_RATIO_MIN.getTickAtSqrtRatio(),
            maxTick: SQRT_RATIO_MAX.getTickAtSqrtRatio(),
            isToken0: true
        });
    }

    function testPlotPriceDrop() public {
        manager.initialize(key, SQRT_RATIO_MAX, abi.encode(liquidityInfo, 30 minutes));
        unchecked {
            // Remove previous demo input CSV if it exists locally
            try vm.removeFile("input.csv") {} catch {}

            // Write legend on the first line of demo output CSV
            // NOTE: Use the 'writeRowToCSV(string memory, string[] memory)'
            //       if more than 9 columns are needed.
            writeRowToCSV("input.csv", "timestamp (30 minute each step)", "price (LINK/USDC)");

            (uint160 sqrtPriceX96,,,,,) = manager.getSlot0(id);
            console2.log("price", sqrtPriceX96.getPrice(link, usdc));

            writeRowToCSV("input.csv", 0, sqrtPriceX96.getPrice(link, usdc));
            for (uint32 i = 1; i <= 48; i++) {
                uint32 nextTimestmap = liquidityInfo.startTime + i * 30 minutes;
                vm.warp(nextTimestmap);

                liquidityBootstrappingHooks.sync(key);

                (sqrtPriceX96,,,,,) = manager.getSlot0(id);
                console2.log(">>>>>", uint256(i) * 1e18);
                writeRowToCSV("input.csv", uint256(i) * 1e18, sqrtPriceX96.getPrice(link, usdc));
            }

            // Once the input CSV is fully created, use it to plot the output SVG
            // NOTE: Output file can be .png or .svg
            plot("input.csv", "output.svg", "Price Drop Plot", 18, 2, 900, 600, true);
        }
    }
}

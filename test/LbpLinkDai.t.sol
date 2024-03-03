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

contract LiquidityBootstrappingHooksTest is Test, Deployers {
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
    address alice = makeAddr("alice");
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
        deal(usdc, alice, 10000 * 10 ** 6);

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

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + lbpDuration),
            minTick: SQRT_RATIO_MIN.getTickAtSqrtRatio(),
            maxTick: SQRT_RATIO_MAX.getTickAtSqrtRatio(),
            isToken0: true
        });
    }

    function testAfterInitializeSetsStorageAndTransfersTokens() public {
        manager.initialize(key, SQRT_RATIO_MAX, abi.encode(liquidityInfo, 1 hours));
        (uint128 totalAmount, uint32 startTime, uint32 endTime, int24 minTick, int24 maxTick, bool isToken0) =
            liquidityBootstrappingHooks.liquidityInfo(id);

        assertEq(totalAmount, liquidityInfo.totalAmount);
        assertEq(startTime, liquidityInfo.startTime);
        assertEq(endTime, liquidityInfo.endTime);
        assertEq(minTick, liquidityInfo.minTick);
        assertEq(maxTick, liquidityInfo.maxTick);
        assertEq(isToken0, liquidityInfo.isToken0);

        assertEq(token0.balanceOf(address(liquidityBootstrappingHooks)), liquidityInfo.totalAmount);
    }

    function testPriceDrop() public {
        manager.initialize(key, SQRT_RATIO_MAX, abi.encode(liquidityInfo, 1 minutes));
        (,,, int24 minTick, int24 maxTick,) = liquidityBootstrappingHooks.liquidityInfo(id);
        console2.log("minTick", minTick);
        console2.log("maxTick", maxTick);
        uint256 minPrice = minTick.getPriceAtTick(link, usdc);
        uint256 maxPrice = maxTick.getPriceAtTick(link, usdc);
        console2.log("minPrice", minPrice);
        console2.log("maxPrice", maxPrice);

        (uint160 sqrtPriceX96,,,,,) = manager.getSlot0(id);
        console2.log("price", sqrtPriceX96.getPrice(link, usdc));
        uint128 liquidity = manager.getLiquidity(id);
        console2.log("liquidity", liquidity / 1e18);

        for (uint32 i = 1; i <= 48; i++) {
            vm.warp(liquidityInfo.startTime + i * 30 minutes);

            liquidityBootstrappingHooks.sync(key);

            (sqrtPriceX96,,,,,) = manager.getSlot0(id);

            console.log("price", i, "hour:", sqrtPriceX96.getPrice(link, usdc) / 1e16);
        }
    }

    function testSwap() public {
        manager.initialize(key, SQRT_RATIO_MAX, abi.encode(liquidityInfo, 1 minutes));
        vm.warp(liquidityInfo.startTime + 30 minutes);
        bool zeroForOne = false;
        int256 amountSpecified = 100 * 10 ** 6;

        uint256 linkBalanceBuyerBefore = token0.balanceOf(address(alice));
        uint256 usdcBalanceBuyerBefore = token1.balanceOf(address(alice));
        console.log("-----------------------Swap-----------------------");
        console.log("linkBalanceBuyerBefore: ", linkBalanceBuyerBefore);
        console.log("usdcBalanceBuyerBefore: ", usdcBalanceBuyerBefore);

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true})
        );

        uint256 linkBalanceBuyerAfter = token0.balanceOf(address(alice));
        uint256 usdcBalanceBuyerAfter = token1.balanceOf(address(alice));

        console.log("linkBalanceBuyerAfter: ", linkBalanceBuyerAfter);
        console.log("usdcBalanceBuyerAfter: ", usdcBalanceBuyerAfter);
        console.log("-----------------------Swap2-----------------------");
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true})
        );

        uint256 linkBalanceBuyerAfter2 = token0.balanceOf(address(alice));
        uint256 usdcBalanceBuyerAfter2 = token1.balanceOf(address(alice));

        console.log("linkBalanceBuyerAfter2: ", linkBalanceBuyerAfter2);
        console.log("usdcBalanceBuyerAfter2: ", usdcBalanceBuyerAfter2);

        vm.warp(liquidityInfo.startTime + 1 days / 2);
        console.log("-----------------------Swap3-after-half-duration-----------------------");
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true})
        );

        uint256 linkBalanceBuyerAfter3 = token0.balanceOf(address(alice));
        uint256 usdcBalanceBuyerAfter3 = token1.balanceOf(address(alice));

        console.log("linkBalanceBuyerAfter3: ", linkBalanceBuyerAfter3);
        console.log("usdcBalanceBuyerAfter3: ", usdcBalanceBuyerAfter3);

        vm.warp(liquidityInfo.endTime + 1 minutes);
        vm.stopPrank();
        console.log("-----------------------Swap4-after-end-time-----------------------");
        liquidityBootstrappingHooks.exit(key);

        uint256 linkBalanceBuyerEnd = token0.balanceOf(address(alice));
        uint256 usdcBalanceBuyerEnd = token1.balanceOf(address(alice));

        uint256 linkBalanceSellerEnd = token0.balanceOf(address(this));
        uint256 usdcBalanceSellerEnd = token1.balanceOf(address(this));

        console.log("linkBalanceBuyerEnd: ", linkBalanceBuyerEnd);
        console.log("usdcBalanceBuyerEnd: ", usdcBalanceBuyerEnd);

        console.log("linkBalanceSellerEnd: ", linkBalanceSellerEnd);
        console.log("usdcBalanceSellerEnd: ", usdcBalanceSellerEnd);

        uint256 linkBalanceManagerEnd = token0.balanceOf(address(manager));
        uint256 usdcBalanceManagerEnd = token1.balanceOf(address(manager));

        console.log("linkBalanceManagerEnd: ", linkBalanceManagerEnd);
        console.log("usdcBalanceManagerEnd: ", usdcBalanceManagerEnd);
    }
}

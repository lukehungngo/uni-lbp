// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {LiquidityBootstrappingPoolImplementation} from "./LiquidityBootstrappingPoolImplementation.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";

contract LiquidityBootstrappingPool is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    int24 constant MIN_TICK_SPACING = 1;
    uint160 constant SQRT_RATIO_2_1 = 112045541949572279837463876454;

    TestERC20 token0;
    TestERC20 token1;
    PoolManager manager;
    LiquidityBootstrappingPoolImplementation liquidityBootstrappingPool =
        LiquidityBootstrappingPoolImplementation(address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG)));
    PoolKey key;
    PoolId id;

    PoolSwapTest swapRouter;

    struct LiquidityInfo {
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        int24 minTick; // The minimum tick to provide liquidity at
        int24 maxTick; // The maximum tick to provide liquidity at
        bool isToken0; // Whether the token to provide liquidity for is token0
    }

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        manager = new PoolManager(500000);

        vm.record();
        LiquidityBootstrappingPoolImplementation impl =
            new LiquidityBootstrappingPoolImplementation(manager, liquidityBootstrappingPool);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(liquidityBootstrappingPool), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(liquidityBootstrappingPool), slot, vm.load(address(impl), slot));
            }
        }
        key = PoolKey(
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            0,
            MIN_TICK_SPACING,
            liquidityBootstrappingPool
        );
        id = key.toId();

        swapRouter = new PoolSwapTest(manager);

        token0.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token1.approve(address(liquidityBootstrappingPool), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
    }

    function testAfterInitializeSetsStorageAndTransfersTokens() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        (uint128 totalAmount, uint32 startTime, uint32 endTime, int24 minTick, int24 maxTick, bool isToken0) =
            liquidityBootstrappingPool.liquidityInfo();

        assertEq(totalAmount, liquidityInfo.totalAmount);
        assertEq(startTime, liquidityInfo.startTime);
        assertEq(endTime, liquidityInfo.endTime);
        assertEq(minTick, liquidityInfo.minTick);
        assertEq(maxTick, liquidityInfo.maxTick);
        assertEq(isToken0, liquidityInfo.isToken0);

        assertEq(token0.balanceOf(address(liquidityBootstrappingPool)), liquidityInfo.totalAmount);
    }

    function testAfterInitializeRevertsInvalidTimeRange() public {
        // CASE 1: startTime > endTime
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp + 86400),
            endTime: uint32(block.timestamp),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTimeRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 2: endTime < block.timestamp
        vm.warp(1000);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(998),
            endTime: uint32(999),
            minTick: int24(0),
            maxTick: int24(1000),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTimeRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));
    }

    function testAfterInitializeRevertsInvalidTickRange() public {
        // CASE 1: minTick > maxTick
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(1000),
            maxTick: int24(0),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 2: minTick < minUsableTick
        int24 minUsableTick = TickMath.minUsableTick(MIN_TICK_SPACING);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(minUsableTick - 1),
            maxTick: int24(0),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 3: maxTick > maxUsableTick
        int24 maxUsableTick = TickMath.maxUsableTick(MIN_TICK_SPACING);

        liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 86400),
            minTick: int24(0),
            maxTick: int24(maxUsableTick + 1),
            isToken0: true
        });

        vm.expectRevert(bytes4(keccak256("InvalidTickRange()")));
        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));
    }

    function testGetTargetMinTick() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: No time has passed, so the target min tick should be the max tick
        vm.warp(100000);
        assertEq(liquidityBootstrappingPool.getTargetMinTick(), 42069);

        // CASE 2: Half the time has passed, so the target min tick should be the average of the min and max ticks
        vm.warp(100000 + 864000 / 2);
        assertEq(liquidityBootstrappingPool.getTargetMinTick(), 0);

        // CASE 3: All the time has passed, so the target min tick should be the min tick
        vm.warp(100000 + 864000);
        assertEq(liquidityBootstrappingPool.getTargetMinTick(), -42069);

        // CASE 4: More time has passed, so the target min tick should still be the min tick
        vm.warp(100000 + 864000 + 1000);
        assertEq(liquidityBootstrappingPool.getTargetMinTick(), -42069);
    }

    function testGetTargetMinTickRevertsBeforeStartTime() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.warp(99999);
        vm.expectRevert(bytes4(keccak256("BeforeStartTime()")));
        liquidityBootstrappingPool.getTargetMinTick();
    }

    // int16 ticks to ensure they're within the usable tick range
    // uint16 startTime to ensure the endTime doesn't exceed uint32.max
    function testFuzzGetTargetMinTick(
        uint16 startTime,
        uint16 timeRange,
        int16 minTick,
        int16 maxTick,
        uint8 timePassedDenominator
    ) public {
        vm.assume(minTick < maxTick);
        vm.assume(timePassedDenominator > 0);

        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(block.timestamp + startTime),
            endTime: uint32(block.timestamp + startTime + timeRange),
            minTick: int24(minTick),
            maxTick: int24(maxTick),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.warp(block.timestamp + startTime + timeRange / timePassedDenominator);
        // Assert less than or equal to maxTick and greater than or equal to minTick
        assertTrue(
            liquidityBootstrappingPool.getTargetMinTick() < maxTick
                || liquidityBootstrappingPool.getTargetMinTick() == maxTick
        );
        assertTrue(
            liquidityBootstrappingPool.getTargetMinTick() > minTick
                || liquidityBootstrappingPool.getTargetMinTick() == minTick
        );
    }

    function testGetTargetLiquidity() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(42069e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        // CASE 1: No time has passed, so the target liquidity should be 0
        vm.warp(100000);
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(), 0);

        // CASE 2: Half the time has passed, so the target liquidity should be half the total amount
        vm.warp(100000 + 864000 / 2);
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(), 210345e17);

        // CASE 3: All the time has passed, so the target liquidity should be the total amount
        vm.warp(100000 + 864000);
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(), 42069e18);

        // CASE 4: More time has passed, so the target liquidity should still be the total amount
        vm.warp(100000 + 864000 + 1000);
        assertEq(liquidityBootstrappingPool.getTargetLiquidity(), 42069e18);
    }

    function testGetTargetLiquidityRevertsBeforeStartTime() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(100000),
            endTime: uint32(100000 + 864000), // 10 day range
            minTick: int24(-42069),
            maxTick: int24(42069),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.warp(99999);
        vm.expectRevert(bytes4(keccak256("BeforeStartTime()")));
        liquidityBootstrappingPool.getTargetLiquidity();
    }

    function testFuzzGetTargetLiquidity(
        uint128 totalAmount,
        uint16 startTime,
        uint16 timeRange,
        int16 minTick,
        int16 maxTick,
        uint8 timePassedDenominator
    ) public {
        vm.assume(minTick < maxTick);
        vm.assume(timePassedDenominator > 0);

        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(totalAmount),
            startTime: uint32(block.timestamp + startTime),
            endTime: uint32(block.timestamp + startTime + timeRange),
            minTick: int24(minTick),
            maxTick: int24(maxTick),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.warp(block.timestamp + startTime + timeRange / timePassedDenominator);
        // Assert less than or equal to target amount
        assertTrue(
            liquidityBootstrappingPool.getTargetLiquidity() < totalAmount
                || liquidityBootstrappingPool.getTargetLiquidity() == totalAmount
        );
    }

    function testBeforeSwapOutOfRangeSetsInitialLiquidityPosition() public {
        LiquidityInfo memory liquidityInfo = LiquidityInfo({
            totalAmount: uint128(1000e18),
            startTime: uint32(10000),
            endTime: uint32(10000 + 86400),
            minTick: int24(5000),
            maxTick: int24(10000),
            isToken0: true
        });

        manager.initialize(key, SQRT_RATIO_2_1, abi.encode(liquidityInfo));

        vm.warp(50000);

        vm.prank(address(manager));
        liquidityBootstrappingPool.beforeSwap(address(0xBEEF), key, IPoolManager.SwapParams(true, 0, 0), bytes(""));

        // Check liquidity at expected tick range
        Position.Info memory position = manager.getPosition(id, address(liquidityBootstrappingPool), 7686, 10000);

        // Assert liquidity value is proportional amount of liquidity to time passed
        assertEq(position.liquidity, 462962962962962962962);
    }
}

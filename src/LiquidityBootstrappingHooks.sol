// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
// TODO: Import from v4-periphery once it's merged
import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";
import "forge-std/console2.sol";

error InvalidTimeRange();
error InvalidTickRange();
error BeforeStartTime();
error BeforeEndTime();
error Unauthorized();

/// @title LiquidityBootstrappingHooks
/// @notice Uniswap V4 hook-enabled, capital efficient, liquidity bootstrapping pool.
/// @author https://github.com/kadenzipfel
contract LiquidityBootstrappingHooks is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// Generic pool info used by hooks
    struct LiquidityInfo {
        // @hung total amount of project token provided (current amount, not total) ???
        uint128 totalAmount; // The total amount of liquidity to provide
        uint32 startTime; // Start time of the liquidity bootstrapping period
        uint32 endTime; // End time of the liquidity bootstrapping period
        // NOTE: If token1 is bootstrapping token, value is inverted and used as upper tick
        int24 minTick; // The minimum tick to provide liquidity at
        // NOTE: If token1 is bootstrapping token, value is inverted and used as lower tick
        int24 maxTick; // The maximum tick to provide liquidity at
        bool isToken0; // Whether the token to provide liquidity for is token0
    }

    /// Modify position callback received in `lockAcquired`
    struct ModifyPositionCallback {
        PoolKey key;
        IPoolManager.ModifyPositionParams params;
        bool takeToOwner;
    }

    /// Swap callback received in `lockAcquired`
    struct SwapCallback {
        PoolKey key;
        IPoolManager.SwapParams params;
    }

    // Data received by `afterInitialize`
    struct InitializeData {
        LiquidityInfo liquidityInfo_;
        uint256 epochSize_;
    }

    /// Time between each epoch for a given pool
    mapping(PoolId => uint256) epochSize;
    /// Whether the epoch of a given pool at a given floored timestamp has been synced
    /// poolId => epoch floored timestamp => synced
    mapping(PoolId => mapping(uint256 => bool)) epochSynced;

    /// The liquidity info for the given pool
    mapping(PoolId => LiquidityInfo) public liquidityInfo;

    /// The total amount of liquidity provided to the given pool so far
    // @hung the liquidity amount will increase over time, this is the liquidity that can be provided (not total amount) at specific time
    /// Note: Represents total of tokens provided as liquidity or sold,
    ///       not just liquidity provided,
    mapping(PoolId => uint256) amountProvided;
    /// Current minimum tick of liquidity range of the given pool
    /// Note: In the case of token1 being the bootstrapping token,
    ///       ticks are inverted and this is used as the upper tick
    mapping(PoolId => int24) currentMinTick;
    /// Whether to skip syncing logic for the given pool
    mapping(PoolId => bool) skipSync;
    /// Owner of the given pool
    mapping(PoolId => address) owner;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Enforces only pool owner can call
    modifier poolOwnerOnly(PoolId poolId) {
        if (msg.sender != owner[poolId]) revert Unauthorized();
        _;
    }

    /// @notice Transfer pool ownership to newOwner
    /// @param poolId Pool id
    /// @param newOwner New owner
    function transferPoolOwnership(PoolId poolId, address newOwner) external poolOwnerOnly(poolId) {
        owner[poolId] = newOwner;
    }

    /// @notice Used by PoolManager to determine which hooks to use
    /// @return Hooks struct indicating which hooks to use
    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: true,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    /// @notice Hook called by the poolManager after initialization
    /// @param sender PoolManager.initialize msg.sender
    /// @param key Pool key
    /// @param data LiquidityInfo encoded as bytes
    /// @return Function selector (used to proceed execution in PoolManager)
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24, bytes calldata data)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        InitializeData memory data_ = abi.decode(data, (InitializeData));

        if (
            data_.liquidityInfo_.startTime > data_.liquidityInfo_.endTime
                || data_.liquidityInfo_.endTime < block.timestamp
        ) {
            revert InvalidTimeRange();
        }
        if (
            data_.liquidityInfo_.minTick > data_.liquidityInfo_.maxTick
                || data_.liquidityInfo_.minTick < TickMath.minUsableTick(key.tickSpacing)
                || data_.liquidityInfo_.maxTick > TickMath.maxUsableTick(key.tickSpacing)
        ) revert InvalidTickRange();

        PoolId poolId = key.toId();

        liquidityInfo[poolId] = data_.liquidityInfo_;
        currentMinTick[poolId] = data_.liquidityInfo_.minTick;
        epochSize[poolId] = data_.epochSize_;
        owner[poolId] = sender;

        // Transfer bootstrapping token to this contract
        uint256 senderBalanceBefore = getProjectTokenBalance(key, sender);
        uint256 lbpBalanceBefore = getProjectTokenBalance(key, address(this));
        uint256 poolManagerBalanceBefore = getProjectTokenBalance(key, address(poolManager));
        if (data_.liquidityInfo_.isToken0) {
            ERC20(Currency.unwrap(key.currency0)).transferFrom(sender, address(this), data_.liquidityInfo_.totalAmount);
        } else {
            ERC20(Currency.unwrap(key.currency1)).transferFrom(sender, address(this), data_.liquidityInfo_.totalAmount);
        }

        uint256 senderBalanceAfter = getProjectTokenBalance(key, sender);
        uint256 lbpBalanceAfter = getProjectTokenBalance(key, address(this));
        uint256 poolManagerBalanceAfter = getProjectTokenBalance(key, address(poolManager));

        console2.log("afterInitialize|senderBalanceBefore: ", senderBalanceBefore);
        console2.log("afterInitialize|lbpBalanceBefore: ", lbpBalanceBefore);
        console2.log("afterInitialize|poolManagerBalanceBefore: ", poolManagerBalanceBefore);

        console2.log("afterInitialize|senderBalanceAfter: ", senderBalanceAfter);
        console2.log("afterInitialize|lbpBalanceAfter: ", lbpBalanceAfter);
        console2.log("afterInitialize|poolManagerBalanceAfter: ", poolManagerBalanceAfter);

        return LiquidityBootstrappingHooks.afterInitialize.selector;
    }

    /// @notice Hook called by the poolManager before swap
    /// @param key Pool key
    /// @return Function selector (used to proceed execution in PoolManager)
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        if (liquidityInfo[poolId].startTime > block.timestamp) {
            // Liquidity bootstrapping period has not started yet,
            // allow swapping as usual
            return LiquidityBootstrappingHooks.beforeSwap.selector;
        }
        string memory projectTokenName = ERC20(Currency.unwrap(key.currency0)).name();
        uint256 lbpBalanceBefore = getProjectTokenBalance(key, address(this));
        uint256 poolManagerBalanceBefore = getProjectTokenBalance(key, address(poolManager));
        bool isSkipSync = skipSync[poolId];
        if (!isSkipSync) {
            console2.log("beforeSwap|", projectTokenName, "|lbpBalanceBefore: ", lbpBalanceBefore);
            console2.log("beforeSwap|", projectTokenName, "|poolManagerBalanceBefore: ", poolManagerBalanceBefore);
        }

        sync(key);

        uint256 lbpBalanceAfter = getProjectTokenBalance(key, address(this));
        uint256 poolManagerBalanceAfter = getProjectTokenBalance(key, address(poolManager));
        if (!isSkipSync) {
            console2.log("beforeSwap|", projectTokenName, "|lbpBalanceAfter: ", lbpBalanceAfter);
            console2.log("beforeSwap|", projectTokenName, "|poolManagerBalanceAfter: ", poolManagerBalanceAfter);
        }

        return LiquidityBootstrappingHooks.beforeSwap.selector;
    }

    /// @notice Logic to sync the pool to the current epoch
    ///         - Provides liquidity at new target range and
    ///           sells tokens if necessary to hit target price
    ///         - Called in beforeSwap hook or manually by anyone
    /// @param key Pool key
    function sync(PoolKey calldata key) public {
        PoolId poolId = key.toId();
        uint256 epochTimestamp = _floorToEpoch(epochSize[poolId], block.timestamp);

        if (skipSync[poolId] || epochSynced[poolId][epochTimestamp]) {
            // Already synced for this epoch or syncing is disabled
            return;
        }

        LiquidityInfo memory liquidityInfo_ = liquidityInfo[poolId];
        bool isToken0 = liquidityInfo_.isToken0;

        uint256 targetLiquidity = _getTargetLiquidity(poolId, epochTimestamp);
        uint256 amountToProvide = targetLiquidity - amountProvided[poolId];

        amountProvided[poolId] = targetLiquidity;

        (, int24 tick,,,,) = poolManager.getSlot0(poolId);
        int24 targetMinTick = _getTargetMinTick(poolId, epochTimestamp);

        // @hung:
        // targetLiquidty will increase over time, so the amountToProvide will increase over time
        // targetMinTick will decrease over time, so the tick will decrease over time
        // so as time passed, we have more liquidity and smaller tick => price will drop
        if (isToken0 && tick < targetMinTick || !isToken0 && tick > targetMinTick) {
            /*
            Ex:
                - isToken0: (token0 is project token): ----0-----tick----targetMinTick----------maxTick-----
                    tick < targetMinTick meaning the price is lower than the target lowest price
                - !isToken0: (token1 is project token): ----maxTick----targetMinTick-------tick--------0------
                    tick > targetMinTick meaning the price is lower than the target lowest price
                    because the price is inverted
            **/
            // Current tick is below target minimum tick
            // Update liquidity range to [targetMinTick, maxTick]
            // and provide additional liquidity according to target liquidity
            // replacePosition will remove current liquidity and provide new liquidity
            _replacePosition(key, liquidityInfo_, amountToProvide, targetMinTick);
        } else {
            // Current tick is above target minimum tick
            // Sell all available tokens or enough to reach targetMinTick - 1
            // If remaining tokens, update liquidity range to [targetMinTick, maxTick]
            // and provide additional liquidity according to target liquidity

            // Get bootstrapping token balance before swap
            uint256 amountSwapped = _getTokenBalance(key);

            // Swap
            skipSync[poolId] = true; // Skip beforeSwap hook logic to avoid infinite loop
            // @hung: when call swap, it would invoke beforeSwap hook => which then invoke sync again
            // so skipSync would avoid infinite loop
            _swap(
                key,
                IPoolManager.SwapParams(
                    liquidityInfo_.isToken0, // @hung: zeroForOne, if token0 is bootstrapping token the swap is for token1 ??? must be vice versa
                    int256(amountToProvide),
                    TickMath.getSqrtRatioAtTick(isToken0 ? targetMinTick - 1 : -targetMinTick + 1)
                )
            );
            skipSync[poolId] = false;

            // amountSwapped = token balance before - token balance after
            // get number of swapped amount
            amountSwapped -= _getTokenBalance(key);

            if (amountSwapped < amountToProvide) {
                _replacePosition(key, liquidityInfo_, amountToProvide - amountSwapped, targetMinTick);
            }
        }

        epochSynced[poolId][epochTimestamp] = true;
    }

    /// @notice Withdraw LBP liquidity to pool owner
    ///         - Liquidity bootstrapping period must have ended
    ///         - Permanently disables syncing logic
    /// @param key Pool key
    function exit(PoolKey calldata key) external poolOwnerOnly(key.toId()) {
        PoolId poolId = key.toId();
        LiquidityInfo memory liquidityInfo_ = liquidityInfo[poolId];

        if (_floorToEpoch(epochSize[poolId], block.timestamp) < uint256(liquidityInfo_.endTime)) {
            // Liquidity bootstrapping period has not ended yet
            revert BeforeEndTime();
        }

        // Run final sync to ensure all liquidity is provided
        sync(key);

        // Withdraw all liquidity to owner
        int24 currentMinTick_ = currentMinTick[poolId];
        bool isToken0 = liquidityInfo_.isToken0;
        Position.Info memory position = poolManager.getPosition(
            poolId,
            address(this),
            isToken0 ? currentMinTick_ : -liquidityInfo_.maxTick,
            isToken0 ? liquidityInfo_.maxTick : -currentMinTick_
        );
        _modifyPosition(
            key,
            IPoolManager.ModifyPositionParams(
                isToken0 ? currentMinTick_ : -liquidityInfo_.maxTick,
                isToken0 ? liquidityInfo_.maxTick : -currentMinTick_,
                -int256(uint256(position.liquidity))
            ),
            true
        );

        // Disable syncing logic
        skipSync[poolId] = true;
    }

    /// @notice Close and reopen the LP position
    function _replacePosition(
        PoolKey calldata key,
        LiquidityInfo memory liquidityInfo_,
        uint256 liquidityChange,
        int24 targetMinTick
    ) internal {
        PoolId poolId = key.toId();

        bool isToken0 = liquidityInfo_.isToken0;

        int24 currentMinTick_ = currentMinTick[poolId];
        int24 currentTickLower = isToken0 ? currentMinTick_ : -liquidityInfo_.maxTick;
        int24 currentTickUpper = isToken0 ? liquidityInfo_.maxTick : -currentMinTick_;
        int24 newTickLower = isToken0 ? targetMinTick : -liquidityInfo_.maxTick;
        int24 newTickUpper = isToken0 ? liquidityInfo_.maxTick : -targetMinTick;

        /**
         * Ex:
         * (token0 is project token): ----0-----newTickLower----currentTickLower----------currentTickUpper/newTickUpper-----
         * (token1 is project token): ----currentTickLower/newTickLower----currentTickUpper-------newTickUpper--------0------
         *      currentMinTick > targetMinTick
         */
        // Update liquidity range to [targetMinTick, maxTick]
        // and provide additional liquidity according to target liquidity
        Position.Info memory position =
            poolManager.getPosition(poolId, address(this), currentTickLower, currentTickUpper);
        uint256 newLiquidity =
            _getTokenAmount(currentTickLower, currentTickUpper, position.liquidity, isToken0) + liquidityChange;

        // Close current position
        if (position.liquidity > 0) {
            _modifyPosition(
                key,
                IPoolManager.ModifyPositionParams(
                    currentTickLower, currentTickUpper, -int256(uint256(position.liquidity))
                ),
                false
            );
        }

        // Get liquidity amount for new position
        int256 liquidity = _getLiquidityAmount(newTickLower, newTickUpper, newLiquidity, isToken0);

        // Open new position
        _modifyPosition(key, IPoolManager.ModifyPositionParams(newTickLower, newTickUpper, liquidity), false);

        // Update liquidity range
        currentMinTick[poolId] = targetMinTick;
    }

    /// @notice Get the target minimum tick for the given timestamp for the given pool
    /// @param poolId Pool ID
    /// @param timestamp Epoch floored timestamp
    /// @return Target minimum tick
    // @hung targetMinTick will decrease over time. as the timeElapsed increase, the numerator will increase, so the targetMinTick will decrease
    // @hung targetMinTick decrease mean the price would drop over time
    function _getTargetMinTick(PoolId poolId, uint256 timestamp) internal view returns (int24) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo[poolId];

        if (timestamp < uint256(liquidityInfo_.startTime)) revert BeforeStartTime();

        if (timestamp >= uint256(liquidityInfo_.endTime)) return liquidityInfo_.minTick;

        uint256 timeElapsed = timestamp - uint256(liquidityInfo_.startTime);
        uint256 timeTotal = uint256(liquidityInfo_.endTime) - uint256(liquidityInfo_.startTime);

        // Get the target minimum tick of the liquidity range such that:
        // (maxTick - targetMinTick) / (maxTick - minTick) = timeElapsed / timeTotal
        // Solving for targetMinTick, we get:
        // targetMinTick = maxTick - ((timeElapsed / timeTotal) * (maxTick - minTick))
        // To avoid integer truncation, we rearrange as follows:
        // numerator = timeElapsed * (maxTick - minTick)
        // targetMinTick = maxTick - (numerator / timeTotal)
        int256 numerator = int256(timeElapsed) * int256(liquidityInfo_.maxTick - liquidityInfo_.minTick);
        return int24(int256(liquidityInfo_.maxTick) - (numerator / int256(timeTotal)));
    }

    /// @notice Get the target liquidity for the given timestamp for the given pool
    ///         Note: target liquidity represents total of intended tokens
    ///         provided as liquidity or sold, not just liquidity provided,
    ///         denominated in bootstrapping token
    /// @param poolId Pool ID
    /// @param timestamp Epoch floored timestamp
    /// @return Target liquidity
    // @hung the target liquidity amount will increase over time
    function _getTargetLiquidity(PoolId poolId, uint256 timestamp) internal view returns (uint256) {
        LiquidityInfo memory liquidityInfo_ = liquidityInfo[poolId];
        console2.log("targetMinTick|liquidityInfo_.startTime: ", liquidityInfo_.startTime);
        console2.log("targetMinTick|timestamp: ", timestamp);
        if (timestamp < uint256(liquidityInfo_.startTime)) revert BeforeStartTime();

        if (timestamp >= uint256(liquidityInfo_.endTime)) return liquidityInfo_.totalAmount;

        uint256 timeElapsed = timestamp - uint256(liquidityInfo_.startTime);
        uint256 timeTotal = uint256(liquidityInfo_.endTime) - uint256(liquidityInfo_.startTime);

        // Get the target liquidity such that:
        // (targetLiquidity / totalAmount) = timeElapsed / timeTotal
        // Solving for targetLiquidity, we get:
        // targetLiquidity = (timeElapsed / timeTotal) * totalAmount
        return (timeElapsed * liquidityInfo_.totalAmount) / timeTotal;
    }

    /// @notice Get the intended amount of liquidity for the given amount of tokens and ticks
    /// @param tickLower Lower tick of the liquidity range
    /// @param tickUpper Upper tick of the liquidity range
    /// @param tokenAmount Amount of tokens
    /// @param isToken0 Whether token0 is the token to use as liquidity
    /// @return liquidity Intended amount of liquidity
    function _getLiquidityAmount(int24 tickLower, int24 tickUpper, uint256 tokenAmount, bool isToken0)
        internal
        pure
        returns (int256 liquidity)
    {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (isToken0) {
            liquidity =
                int256(uint256(LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, tokenAmount)));
        } else {
            liquidity =
                int256(uint256(LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, tokenAmount)));
        }
    }

    /// @notice Get the amount of tokens for the given amount of liquidity and ticks
    /// @param tickLower Lower tick of the liquidity range
    /// @param tickUpper Upper tick of the liquidity range
    /// @param liquidity Amount of liquidity
    /// @param isToken0 Whether token0 is the token used as liquidity
    function _getTokenAmount(int24 tickLower, int24 tickUpper, uint128 liquidity, bool isToken0)
        internal
        pure
        returns (uint256 tokenAmount)
    {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (isToken0) {
            tokenAmount = LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else {
            tokenAmount = LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    /// @notice Get the bootstrapping token balance of the contract for the given pool
    /// @param key Pool key
    /// @return Bootstrapping token balance
    function _getTokenBalance(PoolKey calldata key) internal view returns (uint256) {
        PoolId poolId = key.toId();
        LiquidityInfo memory liquidityInfo_ = liquidityInfo[poolId];

        if (liquidityInfo_.isToken0) {
            return ERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        } else {
            return ERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        }
    }

    /// @notice Floor timestamp to current epoch
    /// @param epochSize_ Epoch size
    /// @param timestamp Timestamp
    /// @return Floored timestamp
    function _floorToEpoch(uint256 epochSize_, uint256 timestamp) internal pure returns (uint256) {
        return (timestamp / epochSize_) * epochSize_;
    }

    /// @notice Helper function to modify position
    ///         Creates lock with intended parameters, later used in callback to `lockAcquired`
    /// @param key Pool key
    /// @param params Modify position parameters
    /// @param takeToOwner Whether to take the tokens to the owner
    /// @return delta Balance delta
    function _modifyPosition(PoolKey calldata key, IPoolManager.ModifyPositionParams memory params, bool takeToOwner)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(
            poolManager.lock(abi.encode(IPoolManager.modifyPosition.selector, key, params, takeToOwner)), (BalanceDelta)
        );
    }

    /// @notice Helper function to swap tokens
    ///         Creates lock with intended parameters, later used in callback to `lockAcquired`
    /// @param key Pool key
    /// @param params Swap parameters
    /// @return delta Balance delta
    function _swap(PoolKey calldata key, IPoolManager.SwapParams memory params) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.lock(abi.encode(IPoolManager.swap.selector, key, params)), (BalanceDelta));
    }

    /// @notice Helper function to take tokens according to balance deltas
    /// @param delta Balance delta
    /// @param takeToOwner Whether to take the tokens to the owner
    function _takeDeltas(PoolKey memory key, BalanceDelta delta, bool takeToOwner) internal {
        PoolId poolId = key.toId();
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        if (delta0 < 0) {
            poolManager.take(key.currency0, takeToOwner ? owner[poolId] : address(this), uint256(-delta0));
        }

        if (delta1 < 0) {
            poolManager.take(key.currency1, takeToOwner ? owner[poolId] : address(this), uint256(-delta1));
        }
    }

    /// @notice Helper function to settle tokens according to balance deltas
    /// @param key Pool key
    /// @param delta Balance delta
    function _settleDeltas(PoolKey memory key, BalanceDelta delta) internal {
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        if (delta0 > 0) {
            key.currency0.transfer(address(poolManager), uint256(delta0));
            poolManager.settle(key.currency0);
        }

        if (delta1 > 0) {
            key.currency1.transfer(address(poolManager), uint256(delta1));
            poolManager.settle(key.currency1);
        }
    }

    /// @notice Callback function called by the poolManager when a lock is acquired
    ///         Used for modifying positions and swapping tokens internally
    /// @param data Data passed to the lock function
    /// @return Balance delta
    function lockAcquired(bytes calldata data) external override poolManagerOnly returns (bytes memory) {
        bytes4 selector = abi.decode(data[:32], (bytes4));

        if (selector == IPoolManager.modifyPosition.selector) {
            ModifyPositionCallback memory callback = abi.decode(data[32:], (ModifyPositionCallback));

            BalanceDelta delta = poolManager.modifyPosition(callback.key, callback.params, bytes(""));

            int256 delta0 = delta.amount0();
            int256 delta1 = delta.amount1();
            PoolKey memory key = callback.key;
            console2.log("modifyPosition|delta|amount0: ", int256(delta.amount0()));
            console2.log("modifyPosition|delta|amount1: ", int256(delta.amount1()));
            string memory token0Name = ERC20(Currency.unwrap(key.currency0)).name();
            string memory token1Name = ERC20(Currency.unwrap(key.currency1)).name();
            if (callback.params.liquidityDelta < 0) {
                string memory takeTo = callback.takeToOwner ? "owner" : "poolManager";
                if (delta0 < 0) {
                    console2.log(
                        "modifyPosition|takes|", string(abi.encodePacked(takeTo, token0Name)), ":", uint256(-delta0)
                    );
                }

                if (delta1 < 0) {
                    console2.log(
                        "modifyPosition|takes|", string(abi.encodePacked(takeTo, token1Name)), ":", uint256(-delta1)
                    );
                }
                // Removing liquidity, take tokens from the poolManager
                _takeDeltas(callback.key, delta, callback.takeToOwner); // Take to owner if specified (exit)
            } else {
                if (delta0 > 0) {
                    console2.log("modifyPosition|settle|toPoolManager|", token0Name, ":", uint256(delta0));
                }

                if (delta1 > 0) {
                    console2.log("modifyPosition|settle|toPoolManager|", token1Name, ":", uint256(delta1));
                }
                // Adding liquidity, settle tokens to the poolManager
                _settleDeltas(callback.key, delta);
            }

            return abi.encode(delta);
        }

        if (selector == IPoolManager.swap.selector) {
            SwapCallback memory callback = abi.decode(data[32:], (SwapCallback));

            BalanceDelta delta = poolManager.swap(callback.key, callback.params, bytes(""));
            console2.log("swap|delta|amount0: ", int256(delta.amount0()));
            console2.log("swap|delta|amount1: ", int256(delta.amount1()));
            // Take and settle deltas
            int256 delta0 = delta.amount0();
            int256 delta1 = delta.amount1();
            PoolKey memory key = callback.key;
            string memory token0Name = ERC20(Currency.unwrap(key.currency0)).name();
            string memory token1Name = ERC20(Currency.unwrap(key.currency1)).name();

            if (delta0 < 0) {
                console2.log("swap|takes|toOwner|", token0Name, ":", uint256(-delta0));
            }

            if (delta1 < 0) {
                console2.log("swap|takes|toOwner|", token1Name, ":", uint256(-delta1));
            }
            _takeDeltas(callback.key, delta, true); // Take tokens to the owner

            if (delta0 > 0) {
                console2.log("swap|settle|toPoolManager|", token0Name, ":", uint256(delta0));
            }

            if (delta1 > 0) {
                console2.log("swap|settle|toPoolManager|", token1Name, ":", uint256(delta1));
            }
            _settleDeltas(callback.key, delta);

            return abi.encode(delta);
        }

        return bytes("");
    }

    function getProjectTokenBalance(PoolKey calldata key, address target) public view returns (uint256) {
        PoolId poolId = key.toId();
        LiquidityInfo memory info = liquidityInfo[poolId];
        if (info.isToken0) {
            return ERC20(Currency.unwrap(key.currency0)).balanceOf(target);
        } else {
            return ERC20(Currency.unwrap(key.currency1)).balanceOf(target);
        }
    }
}

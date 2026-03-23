// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {BaseOracleHook} from "uniswap-hooks/src/oracles/panoptic/BaseOracleHook.sol";

/// @title SigilXOracleHook
/// @notice Uniswap V4 oracle hook for the SIGILX/USDC pool.
///         Records price observations on every swap via beforeSwap().
///         Exposes TWAP via observe() — consumed by the TreasuryManager
///         buyback mechanism for manipulation-resistant price protection.
///
///         Inherits from OpenZeppelin's BaseOracleHook which provides:
///           - Observation array (65535 slots per pool)
///           - Truncated tick accumulator (capped by MAX_ABS_TICK_DELTA)
///           - afterInitialize: seeds first observation
///           - beforeSwap: records tick on every swap
///           - observe(): standard TWAP query interface
///           - increaseObservationCardinalityNext(): grow observation buffer
///
/// @dev Deploy at an address whose low bits match the required V4 hook
///      permission flags (afterInitialize=true, beforeSwap=true).
///      Use CREATE2 with appropriate salt for address mining.
contract SigilXOracleHook is BaseOracleHook {
    /// @param _poolManager  The Uniswap V4 PoolManager singleton.
    /// @param _maxAbsTickDelta Maximum tick change per observation.
    ///        Rejects flash-loan price manipulation beyond this bound.
    ///        100 ticks ~= 1% per block — conservative for a new token.
    constructor(
        IPoolManager _poolManager,
        int24 _maxAbsTickDelta
    ) BaseHook(_poolManager) BaseOracleHook(_maxAbsTickDelta) {}
}

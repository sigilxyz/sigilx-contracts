// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title ISigilXOracleHook
/// @notice Minimal interface for the SigilX oracle hook.
///         Consumed by TreasuryManager to query TWAP without
///         importing the full V4 hook dependency tree.
interface ISigilXOracleHook {
    /// @notice Returns tick cumulatives at each `secondsAgos` offset.
    /// @param secondsAgos Lookback offsets (e.g. [1800, 0] for 30-min TWAP).
    /// @param underlyingPoolId The V4 pool to query.
    /// @return tickCumulatives Raw tick * time accumulators.
    /// @return tickCumulativesTruncated Manipulation-resistant (capped) accumulators.
    function observe(
        uint32[] calldata secondsAgos,
        PoolId underlyingPoolId
    ) external view returns (int56[] memory tickCumulatives, int56[] memory tickCumulativesTruncated);

    /// @notice Returns the number of observations stored for a pool.
    /// @param underlyingPoolId The V4 pool to query.
    /// @return count Number of stored observations.
    function observationCount(PoolId underlyingPoolId) external view returns (uint16 count);
}

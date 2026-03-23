// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVRFCoordinatorV2Plus
/// @notice Minimal interface for Chainlink VRF v2.5 coordinator.
///         When the real chainlink/contracts dependency is available,
///         this can be swapped for the canonical import.
interface IVRFCoordinatorV2Plus {
    /// @notice Request random words from the VRF coordinator.
    /// @param extraArgs ABI-encoded request parameters (keyHash, subId, confirmations, callbackGasLimit, numWords, extraArgs)
    /// @return requestId The ID of the randomness request
    function requestRandomWords(bytes calldata extraArgs) external returns (uint256 requestId);
}

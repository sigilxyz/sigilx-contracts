// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEvaluatorRegistry
/// @notice Interface for the EvaluatorRegistry that manages evaluator
///         registration and committee selection.
interface IEvaluatorRegistry {
    /// @notice Returns the required committee size based on job value.
    /// @param jobValue The value of the job in wei
    /// @return size The number of evaluators needed
    function committeeSizeForValue(uint256 jobValue) external view returns (uint8 size);

    /// @notice Select a committee of evaluators using a random seed.
    /// @param seed Random seed from VRF
    /// @param committeeSize Number of evaluators to select
    /// @return committee Array of selected evaluator addresses
    function selectCommittee(uint256 seed, uint8 committeeSize) external view returns (address[] memory committee);
}

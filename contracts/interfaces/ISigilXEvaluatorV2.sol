// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISigilXEvaluatorV2
/// @notice Minimal interface for SigilXEvaluatorV2 committee-based evaluation initialization.
interface ISigilXEvaluatorV2 {
    /// @notice Initialize an evaluation with a pre-selected committee.
    /// @param jobId The job ID to evaluate
    /// @param committee Array of evaluator addresses assigned to this job
    /// @param jobValue The job value used for evaluator fee calculation
    function initializeEvaluation(uint256 jobId, address[] calldata committee, uint256 jobValue) external;

    /// @notice Replace a committee member after VRF selects a replacement.
    /// @param evalId Evaluation ID
    /// @param oldMember Address of the member being replaced
    /// @param newMember Address of the replacement member
    function replaceCommitteeMember(uint256 evalId, address oldMember, address newMember) external;

    /// @notice Look up the evaluation ID for a VRF-initiated job.
    /// @param jobId The job ID
    /// @return evalId The evaluation ID (0 if not found)
    function vrfJobEvaluation(uint256 jobId) external view returns (uint256 evalId);

    /// @notice Create an evaluation with explicit parameters (for ACP-originated evals).
    ///         Only authorized creators can call this.
    /// @param acpContract Address of the ERC-8183 contract
    /// @param jobId The job ID
    /// @param deliverableHash Hash of the deliverable
    /// @param deadline Evaluation deadline
    /// @param budget Job budget for fee calculation (must be > 0)
    /// @return evalId The new evaluation ID
    function createEvaluation(
        address acpContract,
        uint256 jobId,
        bytes32 deliverableHash,
        uint256 deadline,
        uint256 budget
    ) external returns (uint256 evalId);

    /// @notice Add an authorized creator address. Only owner.
    function addAuthorizedCreator(address creator) external;

    /// @notice Remove an authorized creator address. Only owner.
    function removeAuthorizedCreator(address creator) external;
}

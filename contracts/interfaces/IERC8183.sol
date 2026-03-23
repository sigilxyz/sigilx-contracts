/*
                         ██████████████████████
                     ████████████████████████████████
                   ████████████████████████████████████
                 ████████████████████████████████████████
                ██████████████████████████████████████████
                ██████████  ██████████████████  ██████████
                ██████████  ██████████████████  ██████████
                ██████████  ████████            ██████████
                ██████████  ██████████████      ██████████
                ██████████  ██████████████      ██████████
                ██████████  ████████            ██████████
                ██████████  ██████████          ██████████
                ██████████                      ██████████
                 ████████████████████████████████████████
                  ██████████████████████████████████████
                    ██████████████████████████████████
                      ██████████████████████████████
                         ████████████████████████
                            ██████████████████
                               ████████████
                                  ██████
                                    ██

                                 PLEDGE
                              usepledge.xyz
*/
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC8183 - Agentic Commerce Protocol Interface
/// @notice Minimal interface for ERC-8183 Job lifecycle
/// @dev See https://eips.ethereum.org/EIPS/eip-8183
interface IERC8183 {
    enum Status { Open, Funded, Submitted, Completed, Rejected, Expired }

    struct Job {
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        Status status;
        address hook;
    }

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId);

    function setProvider(uint256 jobId, address provider, bytes calldata optParams) external;
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
    function claimRefund(uint256 jobId) external;

    event JobCreated(uint256 indexed jobId, address client, address provider, address evaluator, uint256 expiredAt);
    event ProviderSet(uint256 indexed jobId, address provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address client, uint256 amount);
    event JobSubmitted(uint256 indexed jobId, address provider, bytes32 deliverable);
    event JobCompleted(uint256 indexed jobId, address evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address client, uint256 amount);
}

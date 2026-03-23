// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IERC8183.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockACP - Mock ERC-8183 for testnet integration testing
/// @notice Minimal implementation for lifecycle testing. NOT for production.
contract MockACP is IERC8183 {
    using SafeERC20 for IERC20;

    IERC20 public paymentToken;
    uint256 public nextJobId;
    mapping(uint256 => Job) public jobs;
    mapping(uint256 => uint256) public escrow;

    constructor(address _paymentToken) {
        paymentToken = IERC20(_paymentToken);
        nextJobId = 1;
    }

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId) {
        jobId = nextJobId++;
        jobs[jobId] = Job({
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: Status.Open,
            hook: hook
        });
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt);
    }

    function setProvider(uint256 jobId, address provider, bytes calldata) external {
        jobs[jobId].provider = provider;
        emit ProviderSet(jobId, provider);
    }

    function setBudget(uint256 jobId, uint256 amount, bytes calldata) external {
        jobs[jobId].budget = amount;
        emit BudgetSet(jobId, amount);
    }

    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata) external {
        require(jobs[jobId].budget == expectedBudget, "budget mismatch");
        paymentToken.safeTransferFrom(msg.sender, address(this), expectedBudget);
        jobs[jobId].status = Status.Funded;
        escrow[jobId] = expectedBudget;
        emit JobFunded(jobId, msg.sender, expectedBudget);
    }

    function submit(uint256 jobId, bytes32 deliverable, bytes calldata) external {
        jobs[jobId].status = Status.Submitted;
        emit JobSubmitted(jobId, jobs[jobId].provider, deliverable);
    }

    function complete(uint256 jobId, bytes32 reason, bytes calldata) external {
        require(
            msg.sender == jobs[jobId].evaluator || msg.sender == jobs[jobId].client,
            "not authorized"
        );
        jobs[jobId].status = Status.Completed;
        // Release escrowed funds to provider
        uint256 amount = escrow[jobId];
        if (amount > 0) {
            escrow[jobId] = 0;
            paymentToken.safeTransfer(jobs[jobId].provider, amount);
        }
        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, jobs[jobId].provider, amount);
    }

    function reject(uint256 jobId, bytes32 reason, bytes calldata) external {
        require(
            msg.sender == jobs[jobId].evaluator || msg.sender == jobs[jobId].client,
            "not authorized"
        );
        jobs[jobId].status = Status.Rejected;
        // Refund to client
        uint256 amount = escrow[jobId];
        if (amount > 0) {
            escrow[jobId] = 0;
            paymentToken.safeTransfer(jobs[jobId].client, amount);
        }
        emit JobRejected(jobId, msg.sender, reason);
        emit Refunded(jobId, jobs[jobId].client, amount);
    }

    function claimRefund(uint256 jobId) external {
        require(block.timestamp >= jobs[jobId].expiredAt, "not expired");
        require(jobs[jobId].status != Status.Completed, "already completed");
        jobs[jobId].status = Status.Expired;
        uint256 amount = escrow[jobId];
        if (amount > 0) {
            escrow[jobId] = 0;
            paymentToken.safeTransfer(jobs[jobId].client, amount);
        }
        emit JobExpired(jobId);
        emit Refunded(jobId, jobs[jobId].client, amount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SimpleReputationRegistry
/// @notice ERC-8004-compatible permissionless reputation registry for SigilX.
///         O(1) writes and reads via running summary accumulators.
contract SimpleReputationRegistry is Pausable, Ownable {

    struct Feedback {
        address reviewer;
        int128  value;
        uint8   valueDecimals;
        string  tag1;
        string  tag2;
        string  feedbackURI;
        bytes32 feedbackHash;
        uint64  timestamp;
        bool    isRevoked;
    }

    struct Summary {
        uint64  count;
        int128  summaryValue;
    }

    mapping(uint256 => Feedback[]) private _feedback;
    mapping(uint256 => Summary) private _summary;
    mapping(uint256 => mapping(address => uint64[])) private _reviewerIndices;

    event FeedbackGiven(uint256 indexed agentId, address indexed reviewer, uint64 indexed globalIndex, int128 value, string tag1);
    event FeedbackRevoked(uint256 indexed agentId, address indexed reviewer, uint64 indexed globalIndex);

    error IndexOutOfBounds(uint256 agentId, address reviewer, uint64 feedbackIndex);
    error NotReviewer(address caller, address reviewer);
    error AlreadyRevoked(uint256 agentId, uint64 globalIndex);
    error ValueOutOfBounds(int128 value);

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Pause the registry. Only owner (timelock in prod).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the registry. Only owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Submit feedback. Permissionless. ERC-8004 compatible signature.
    function giveFeedback(
        uint256 agentId,
        int128  value,
        uint8   valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external whenNotPaused {
        if (value < -1000 || value > 1000) revert ValueOutOfBounds(value);
        uint64 globalIndex = uint64(_feedback[agentId].length);

        _feedback[agentId].push(Feedback({
            reviewer: msg.sender,
            value: value,
            valueDecimals: valueDecimals,
            tag1: tag1,
            tag2: tag2,
            feedbackURI: feedbackURI,
            feedbackHash: feedbackHash,
            timestamp: uint64(block.timestamp),
            isRevoked: false
        }));

        _reviewerIndices[agentId][msg.sender].push(globalIndex);

        _summary[agentId].count += 1;
        _summary[agentId].summaryValue += value;

        emit FeedbackGiven(agentId, msg.sender, globalIndex, value, tag1);
    }

    /// @notice Revoke own feedback. Subtracts from running summary.
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        uint64[] storage indices = _reviewerIndices[agentId][msg.sender];
        if (feedbackIndex >= indices.length) revert IndexOutOfBounds(agentId, msg.sender, feedbackIndex);

        uint64 globalIndex = indices[feedbackIndex];
        Feedback storage fb = _feedback[agentId][globalIndex];

        if (fb.reviewer != msg.sender) revert NotReviewer(msg.sender, fb.reviewer);
        if (fb.isRevoked) revert AlreadyRevoked(agentId, globalIndex);

        fb.isRevoked = true;

        _summary[agentId].count -= 1;
        _summary[agentId].summaryValue -= fb.value;

        emit FeedbackRevoked(agentId, msg.sender, globalIndex);
    }

    function getSummary(uint256 agentId) external view returns (uint64 count, int128 summaryValue) {
        Summary storage s = _summary[agentId];
        return (s.count, s.summaryValue);
    }

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external view returns (int128 value, string memory tag1, bool isRevoked)
    {
        uint64[] storage indices = _reviewerIndices[agentId][clientAddress];
        if (feedbackIndex >= indices.length) revert IndexOutOfBounds(agentId, clientAddress, feedbackIndex);
        Feedback storage fb = _feedback[agentId][indices[feedbackIndex]];
        return (fb.value, fb.tag1, fb.isRevoked);
    }

    function totalFeedbackCount(uint256 agentId) external view returns (uint256) {
        return _feedback[agentId].length;
    }
}

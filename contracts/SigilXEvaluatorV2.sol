// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IERC8183.sol";
import "./interfaces/ISigilXEvaluatorV2.sol";
import "./utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SigilXEvaluatorV2
/// @notice Upgraded ERC-8183 Evaluator with fee splits, inaction slashing,
///         and VRF committee-gated voting.
/// @dev SigilX decentralised evaluation engine. Key upgrades:
///      1. Fee Split — evaluatorFeeBps deducted from job payment on resolve(),
///         distributed proportionally to committee by stake weight (pull pattern).
///      2. Inaction Slash — inactive committee members slashed after INACTION_TIMEOUT.
///      3. Committee-Gated Voting — only VRF-assigned members can castVote().
///      Deployed behind an ERC1967 UUPS proxy for upgradeability.
contract SigilXEvaluatorV2 is ISigilXEvaluatorV2, OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    enum Vote {
        None,
        Approve,
        Reject
    }

    enum EvalStatus {
        Pending,
        Approved,
        Rejected,
        Disputed,
        Expired
    }

    struct Evaluation {
        address acpContract;
        uint256 jobId;
        uint256 expiredAt;
        EvalStatus status;
        uint256 totalApproveWeight;
        uint256 totalRejectWeight;
        uint256 totalVoteWeight;
        bytes32 deliverableHash;
        bytes32 resolvedReason;
        uint256 jobBudget;
        bool feesDistributed;
    }

    struct AttesterVote {
        Vote vote;
        uint256 weight;
        bytes32 evidence;
    }

    // =========================================================================
    // State
    // =========================================================================

    address public stakingContract;
    uint256 public quorumBps;
    uint256 public minAttesterCount;
    uint256 public nextEvalId;

    /// @notice Evaluator fee in basis points (default 300 = 3%)
    uint256 public evaluatorFeeBps;

    /// @notice Inaction timeout in seconds (default 7200 = 2 hours)
    uint256 public inactionTimeout;

    /// @notice VRF committee selector contract — only it can initialize evaluations
    address public vrfSelector;

    /// @notice Payment token used for fee distribution
    IERC20 public paymentToken;

    /// @notice Addresses authorized to call createEvaluation
    mapping(address => bool) public authorizedCreators;

    mapping(uint256 => Evaluation) public evaluations;
    mapping(uint256 => mapping(address => AttesterVote)) public votes;
    mapping(uint256 => address[]) public evalAttesters;
    mapping(bytes32 => uint256) public jobEvaluation;

    /// @notice jobId => evalId for VRF-initiated evaluations (no acpContract key needed)
    mapping(uint256 => uint256) public vrfJobEvaluation;

    /// @notice Committee members for each evaluation
    mapping(uint256 => address[]) public committee;

    /// @notice Fast lookup for committee membership
    mapping(uint256 => mapping(address => bool)) public isCommitteeMember;

    /// @notice Accumulated fee claims per evaluation per member (pull pattern)
    mapping(uint256 => mapping(address => uint256)) public feeClaims;

    /// @notice Timestamp when evaluation was created (for inaction timeout)
    mapping(uint256 => uint256) public evalCreatedAt;

    // =========================================================================
    // Events
    // =========================================================================

    event EvaluationInitialized(uint256 indexed evalId, uint256 indexed jobId, address[] committee);
    event VoteCast(uint256 indexed evalId, address indexed attester, Vote vote, uint256 weight, bytes32 evidence);
    event QuorumReached(uint256 indexed evalId, EvalStatus outcome, uint256 approveWeight, uint256 rejectWeight);
    event EvaluationResolved(uint256 indexed evalId, EvalStatus outcome, bytes32 reason);
    event DisputeTriggered(uint256 indexed evalId);
    event InactionSlashed(uint256 indexed evalId, address indexed attester);
    event AttesterReplaced(uint256 indexed evalId, address indexed oldMember, address indexed newMember);
    event FeesDistributed(uint256 indexed evalId, uint256 totalFee);
    event FeesClaimed(uint256 indexed evalId, address indexed member, uint256 amount);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotCommitteeMember();
    error NotActiveAttester();
    error AlreadyVoted();
    error EvaluationNotPending();
    error EvaluationExpired();
    error QuorumNotReached();
    error InvalidVote();
    error JobAlreadyUnderEvaluation();
    error OnlyVRFSelector();
    error OnlyStakingContract();
    error EvaluationNotDisputed();
    error InactionTimeoutNotReached();
    error AttesterAlreadyVoted();
    error NoFeesToClaim();
    error ZeroAddress();
    error ZeroBudget();
    error UnauthorizedCreator();

    // =========================================================================
    // Constructor (disabled for proxy) & Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _stakingContract The staking/registry contract address
    /// @param _quorumBps Quorum threshold in basis points
    /// @param _minAttesterCount Minimum number of attesters required
    /// @param _vrfSelector VRF committee selector contract
    /// @param _paymentToken Payment token for fee distribution
    /// @param _owner The initial owner address
    function initialize(
        address _stakingContract,
        uint256 _quorumBps,
        uint256 _minAttesterCount,
        address _vrfSelector,
        address _paymentToken,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        // __UUPSUpgradeable_init(); // Not available in this OZ version (no-op anyway)
        stakingContract = _stakingContract;
        quorumBps = _quorumBps;
        minAttesterCount = _minAttesterCount;
        vrfSelector = _vrfSelector;
        paymentToken = IERC20(_paymentToken);
        evaluatorFeeBps = 300; // 3% default
        inactionTimeout = 7200; // 2 hours default
    }

    /// @notice UUPS authorization — only owner can upgrade
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Committee Initialization (VRF-gated)
    // =========================================================================

    /// @notice Initialize an evaluation with a VRF-assigned committee.
    ///         Can ONLY be called by the vrfSelector (VRFCommitteeSelector).
    /// @param jobId The job ID to evaluate
    /// @param members Array of committee member addresses
    /// @param jobValue The job value used for evaluator fee calculation
    function initializeEvaluation(uint256 jobId, address[] calldata members, uint256 jobValue) external override {
        if (msg.sender != vrfSelector) revert OnlyVRFSelector();

        uint256 evalId = ++nextEvalId;

        evaluations[evalId] = Evaluation({
            acpContract: address(0), // Set later or by governance
            jobId: jobId,
            expiredAt: block.timestamp + 24 hours, // Default 24h deadline
            status: EvalStatus.Pending,
            totalApproveWeight: 0,
            totalRejectWeight: 0,
            totalVoteWeight: 0,
            deliverableHash: bytes32(0),
            resolvedReason: bytes32(0),
            jobBudget: jobValue,
            feesDistributed: false
        });

        evalCreatedAt[evalId] = block.timestamp;
        vrfJobEvaluation[jobId] = evalId;

        for (uint256 i = 0; i < members.length; i++) {
            committee[evalId].push(members[i]);
            isCommitteeMember[evalId][members[i]] = true;
        }

        emit EvaluationInitialized(evalId, jobId, members);
    }

    /// @notice Create an evaluation with explicit parameters (for ACP-originated evals).
    /// @param acpContract Address of the ERC-8183 contract
    /// @param jobId The job ID
    /// @param deliverableHash Hash of the deliverable
    /// @param deadline Evaluation deadline
    /// @param budget Job budget for fee calculation
    function createEvaluation(
        address acpContract,
        uint256 jobId,
        bytes32 deliverableHash,
        uint256 deadline,
        uint256 budget
    ) external returns (uint256 evalId) {
        if (!authorizedCreators[msg.sender]) revert UnauthorizedCreator();
        if (budget == 0) revert ZeroBudget();
        bytes32 key = keccak256(abi.encodePacked(acpContract, jobId));
        if (jobEvaluation[key] != 0) revert JobAlreadyUnderEvaluation();

        evalId = ++nextEvalId;

        evaluations[evalId] = Evaluation({
            acpContract: acpContract,
            jobId: jobId,
            expiredAt: deadline,
            status: EvalStatus.Pending,
            totalApproveWeight: 0,
            totalRejectWeight: 0,
            totalVoteWeight: 0,
            deliverableHash: deliverableHash,
            resolvedReason: bytes32(0),
            jobBudget: budget,
            feesDistributed: false
        });

        evalCreatedAt[evalId] = block.timestamp;
        jobEvaluation[key] = evalId;
    }

    // =========================================================================
    // Committee-Gated Voting
    // =========================================================================

    /// @notice Cast a vote on an evaluation. Only VRF-assigned committee members can vote.
    /// @param evalId Evaluation ID
    /// @param vote Approve or Reject
    /// @param evidence Hash of off-chain evidence
    function castVote(uint256 evalId, Vote vote, bytes32 evidence) external nonReentrant {
        if (vote == Vote.None) revert InvalidVote();
        if (!isCommitteeMember[evalId][msg.sender]) revert NotCommitteeMember();

        Evaluation storage eval = evaluations[evalId];
        if (eval.status != EvalStatus.Pending) revert EvaluationNotPending();
        if (block.timestamp >= eval.expiredAt) revert EvaluationExpired();

        if (votes[evalId][msg.sender].vote != Vote.None) revert AlreadyVoted();

        (bool isActive, uint256 weight) = _getAttesterInfo(msg.sender);
        if (!isActive || weight == 0) revert NotActiveAttester();

        votes[evalId][msg.sender] = AttesterVote({vote: vote, weight: weight, evidence: evidence});
        evalAttesters[evalId].push(msg.sender);

        if (vote == Vote.Approve) {
            eval.totalApproveWeight += weight;
        } else {
            eval.totalRejectWeight += weight;
        }
        eval.totalVoteWeight += weight;

        emit VoteCast(evalId, msg.sender, vote, weight, evidence);

        _checkQuorum(evalId);
    }

    // =========================================================================
    // Resolution with Fee Split
    // =========================================================================

    /// @notice Resolve an evaluation after quorum. Calls complete/reject on ACP
    ///         and distributes evaluator fees to the committee.
    /// @param evalId Evaluation ID
    function resolve(uint256 evalId) external nonReentrant {
        Evaluation storage eval = evaluations[evalId];
        if (eval.status != EvalStatus.Approved && eval.status != EvalStatus.Rejected) {
            revert QuorumNotReached();
        }

        bytes32 reason = keccak256(
            abi.encodePacked(
                "sigilx-eval-v2",
                evalId,
                eval.totalApproveWeight,
                eval.totalRejectWeight,
                evalAttesters[evalId].length
            )
        );
        eval.resolvedReason = reason;

        // Call complete or reject on ACP
        if (eval.acpContract != address(0)) {
            if (eval.status == EvalStatus.Approved) {
                IERC8183(eval.acpContract).complete(eval.jobId, reason, "");
            } else {
                IERC8183(eval.acpContract).reject(eval.jobId, reason, "");
            }
        }

        // Distribute evaluator fees
        if (eval.jobBudget > 0 && !eval.feesDistributed) {
            uint256 totalFee = (eval.jobBudget * evaluatorFeeBps) / 10000;
            if (totalFee > 0) {
                _distributeEvaluatorFees(evalId, totalFee);
            }
        }

        emit EvaluationResolved(evalId, eval.status, reason);
    }

    /// @notice Resolve a disputed evaluation by owner decision.
    /// @param evalId Evaluation ID
    /// @param outcome Must be Approved or Rejected
    function resolveDispute(uint256 evalId, EvalStatus outcome) external onlyOwner {
        Evaluation storage eval = evaluations[evalId];
        if (eval.status != EvalStatus.Disputed) revert EvaluationNotDisputed();
        if (outcome != EvalStatus.Approved && outcome != EvalStatus.Rejected) {
            revert QuorumNotReached();
        }
        eval.status = outcome;
        emit QuorumReached(evalId, outcome, eval.totalApproveWeight, eval.totalRejectWeight);
    }

    // =========================================================================
    // Inaction Slashing
    // =========================================================================

    /// @notice Slash a committee member who hasn't voted within the inaction timeout.
    ///         Anyone can call this after the timeout expires.
    /// @param evalId Evaluation ID
    /// @param attester Address of the inactive committee member
    function slashInactive(uint256 evalId, address attester) external nonReentrant {
        if (!isCommitteeMember[evalId][attester]) revert NotCommitteeMember();

        Evaluation storage eval = evaluations[evalId];
        if (eval.status != EvalStatus.Pending) revert EvaluationNotPending();

        // Check attester hasn't voted
        if (votes[evalId][attester].vote != Vote.None) revert AttesterAlreadyVoted();

        // Check inaction timeout has passed
        if (block.timestamp <= evalCreatedAt[evalId] + inactionTimeout) {
            revert InactionTimeoutNotReached();
        }

        // Slash via staking contract
        bytes32 slashReason = keccak256(abi.encodePacked("inaction-slash", evalId, attester));
        (bool success,) = stakingContract.call(
            abi.encodeWithSignature("slash(address,bytes32)", attester, slashReason)
        );
        // Slash is best-effort; continue even if staking contract reverts
        if (success) {
            emit InactionSlashed(evalId, attester);
        }

        // Request VRF replacement via vrfSelector
        // The VRFCommitteeSelector.requestReplacement will handle the VRF request
        (success,) = vrfSelector.call(
            abi.encodeWithSignature("requestReplacement(uint256,address)", evaluations[evalId].jobId, attester)
        );
    }

    // =========================================================================
    // Committee Replacement
    // =========================================================================

    /// @notice Replace a committee member. Can only be called by the vrfSelector
    ///         after VRF selects a replacement.
    /// @param evalId Evaluation ID
    /// @param old Address of the member being replaced
    /// @param new_ Address of the replacement member
    function replaceCommitteeMember(uint256 evalId, address old, address new_) external override {
        if (msg.sender != vrfSelector) revert OnlyVRFSelector();
        if (new_ == address(0)) revert ZeroAddress();

        // Remove old member from committee mapping
        isCommitteeMember[evalId][old] = false;

        // Add new member
        isCommitteeMember[evalId][new_] = true;

        // Update the committee array
        address[] storage members = committee[evalId];
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == old) {
                members[i] = new_;
                break;
            }
        }

        emit AttesterReplaced(evalId, old, new_);
    }

    // =========================================================================
    // Fee Distribution (Pull Pattern)
    // =========================================================================

    /// @notice Distribute evaluator fees proportionally to committee members by stake weight.
    /// @param evalId Evaluation ID
    /// @param totalFee Total fee amount to distribute
    function _distributeEvaluatorFees(uint256 evalId, uint256 totalFee) internal {
        Evaluation storage eval = evaluations[evalId];
        eval.feesDistributed = true;

        address[] storage members = committee[evalId];
        uint256 totalWeight = 0;

        // Calculate total stake weight of committee members who voted
        for (uint256 i = 0; i < members.length; i++) {
            if (votes[evalId][members[i]].vote != Vote.None) {
                (, uint256 w) = _getAttesterInfo(members[i]);
                totalWeight += w;
            }
        }

        if (totalWeight == 0) return;

        // Distribute proportionally
        uint256 distributed = 0;
        for (uint256 i = 0; i < members.length; i++) {
            if (votes[evalId][members[i]].vote != Vote.None) {
                (, uint256 w) = _getAttesterInfo(members[i]);
                uint256 share = (totalFee * w) / totalWeight;
                feeClaims[evalId][members[i]] += share;
                distributed += share;
            }
        }

        // Handle dust — give remainder to last voter
        if (distributed < totalFee && members.length > 0) {
            // Find last voting member
            for (uint256 i = members.length; i > 0; i--) {
                if (votes[evalId][members[i - 1]].vote != Vote.None) {
                    feeClaims[evalId][members[i - 1]] += (totalFee - distributed);
                    break;
                }
            }
        }

        emit FeesDistributed(evalId, totalFee);
    }

    /// @notice Claim accumulated fees for a given evaluation.
    /// @param evalId Evaluation ID
    function claimFees(uint256 evalId) external nonReentrant {
        uint256 amount = feeClaims[evalId][msg.sender];
        if (amount == 0) revert NoFeesToClaim();

        feeClaims[evalId][msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, amount);

        emit FeesClaimed(evalId, msg.sender, amount);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _checkQuorum(uint256 evalId) internal {
        Evaluation storage eval = evaluations[evalId];

        if (evalAttesters[evalId].length < minAttesterCount) return;

        uint256 totalActiveStake = _getTotalActiveStake();
        uint256 quorumWeight = (totalActiveStake * quorumBps) / 10000;

        if (eval.totalApproveWeight >= quorumWeight) {
            eval.status = EvalStatus.Approved;
            emit QuorumReached(evalId, EvalStatus.Approved, eval.totalApproveWeight, eval.totalRejectWeight);
            return;
        }

        if (eval.totalRejectWeight >= quorumWeight) {
            eval.status = EvalStatus.Rejected;
            emit QuorumReached(evalId, EvalStatus.Rejected, eval.totalApproveWeight, eval.totalRejectWeight);
            return;
        }

        uint256 disputeThreshold = quorumWeight / 3;
        if (eval.totalApproveWeight >= disputeThreshold && eval.totalRejectWeight >= disputeThreshold) {
            eval.status = EvalStatus.Disputed;
            emit DisputeTriggered(evalId);
        }
    }

    function _getAttesterInfo(address attester) internal view returns (bool isActive, uint256 weight) {
        (bool success, bytes memory data) =
            stakingContract.staticcall(abi.encodeWithSignature("isActiveAttester(address)", attester));
        if (!success) return (false, 0);
        isActive = abi.decode(data, (bool));

        (success, data) = stakingContract.staticcall(abi.encodeWithSignature("stakeWeight(address)", attester));
        if (!success) return (isActive, 0);
        weight = abi.decode(data, (uint256));
    }

    function _getTotalActiveStake() internal view returns (uint256) {
        (bool success, bytes memory data) =
            stakingContract.staticcall(abi.encodeWithSignature("totalActiveStake()"));
        if (!success) return 0;
        return abi.decode(data, (uint256));
    }

    // =========================================================================
    // Views
    // =========================================================================

    function getVoteCount(uint256 evalId) external view returns (uint256) {
        return evalAttesters[evalId].length;
    }

    function getEvalAttesters(uint256 evalId) external view returns (address[] memory) {
        return evalAttesters[evalId];
    }

    function getCommittee(uint256 evalId) external view returns (address[] memory) {
        return committee[evalId];
    }

    function getEvalForJob(address acpContract, uint256 jobId) external view returns (uint256) {
        return jobEvaluation[keccak256(abi.encodePacked(acpContract, jobId))];
    }

    // =========================================================================
    // Governance (owner = timelock)
    // =========================================================================

    function setQuorumBps(uint256 _quorumBps) external onlyOwner {
        quorumBps = _quorumBps;
    }

    function setMinAttesterCount(uint256 _minAttesterCount) external onlyOwner {
        minAttesterCount = _minAttesterCount;
    }

    function setStakingContract(address _stakingContract) external onlyOwner {
        stakingContract = _stakingContract;
    }

    function setVRFSelector(address _vrfSelector) external onlyOwner {
        vrfSelector = _vrfSelector;
    }

    function setEvaluatorFeeBps(uint256 _feeBps) external onlyOwner {
        evaluatorFeeBps = _feeBps;
    }

    function setInactionTimeout(uint256 _timeout) external onlyOwner {
        inactionTimeout = _timeout;
    }

    function setPaymentToken(address _token) external onlyOwner {
        paymentToken = IERC20(_token);
    }

    function addAuthorizedCreator(address creator) external onlyOwner {
        if (creator == address(0)) revert ZeroAddress();
        authorizedCreators[creator] = true;
    }

    function removeAuthorizedCreator(address creator) external onlyOwner {
        authorizedCreators[creator] = false;
    }

    // =========================================================================
    // Storage Gap (H-2 audit fix: reserve slots for future upgrades)
    // =========================================================================

    uint256[50] private __gap;
}

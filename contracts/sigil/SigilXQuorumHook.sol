// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IACPHook.sol";
import "./SigilXCertificateRegistry.sol";
import "./SimpleReputationRegistry.sol";

/// @title SigilXQuorumHook
/// @notice ERC-8183 hook implementing N-of-M multi-evaluator quorum for SigilX.
///
///         Flow:
///           1. ACP calls beforeAction(submit) -> stages a pending job
///           2. Each evaluator independently calls submitEvaluation(jobId, verdict, certHash)
///           3. When passCount >= quorumThreshold  -> auto-finalize PASS, write cert
///              When failCount >  (evaluatorCount - quorumThreshold) -> auto-finalize FAIL
///              When all voted but no clear majority -> DIVERGENCE event
///           4. ACP afterAction(complete) -> write reputation + emit attestation
contract SigilXQuorumHook is IACPHook, Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ──────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────

    struct Evaluation {
        address evaluator;
        bool    verdict;   // true = PASS, false = FAIL
        bytes32 certHash;
        uint256 timestamp;
    }

    struct PendingJob {
        bytes32 certHash;
        bytes32 theoremHash;
        uint256 evaluationCount;
        uint256 passCount;
        uint256 failCount;
        bool    finalized;
        bool    exists;
    }

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    bytes4 public constant SUBMIT_SELECTOR =
        bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR =
        bytes4(keccak256("complete(uint256,bytes32,bytes)"));

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    address public acpContract;
    SigilXCertificateRegistry public registry;
    address public reputationRegistry;

    EnumerableSet.AddressSet private _evaluators;
    uint256 public quorumThreshold; // e.g., 2 for 2-of-3

    mapping(uint256 => PendingJob) private _pendingJobs;
    mapping(uint256 => Evaluation[]) public jobEvaluations;
    /// @dev Track which evaluator has already voted on a given job
    mapping(uint256 => mapping(address => bool)) public hasEvaluated;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event EvaluatorAdded(address indexed evaluator);
    event EvaluatorRemoved(address indexed evaluator);
    event EvaluationSubmitted(uint256 indexed jobId, address indexed evaluator, bool verdict);
    event QuorumReached(uint256 indexed jobId, bool finalVerdict, uint256 passCount, uint256 failCount);
    event Divergence(uint256 indexed jobId, uint256 passCount, uint256 failCount);
    event ACPContractUpdated(address indexed oldACP, address indexed newACP);
    event SigilXAttestation(
        uint256 indexed jobId,
        bytes32 indexed certHash,
        bytes32 theoremHash,
        bool    verdict,
        uint256 timestamp
    );

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error OnlyACPContract();
    error ZeroCertHash();
    error NoPendingJob(uint256 jobId);
    error NotEvaluator(address caller);
    error AlreadyEvaluated(uint256 jobId, address evaluator);
    error JobAlreadyFinalized(uint256 jobId);
    error JobDoesNotExist(uint256 jobId);
    error EvaluatorAlreadyRegistered(address evaluator);
    error EvaluatorNotRegistered(address evaluator);
    error InvalidQuorumThreshold(uint256 threshold, uint256 evaluatorCount);
    error ZeroAddress();

    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    modifier onlyACP() {
        if (msg.sender != acpContract) revert OnlyACPContract();
        _;
    }

    modifier onlyRegisteredEvaluator() {
        if (!_evaluators.contains(msg.sender)) revert NotEvaluator(msg.sender);
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    /// @param _acpContract          Address of the ACP contract (or deployer for testing)
    /// @param _registry             SigilXCertificateRegistry address
    /// @param _reputationRegistry   SimpleReputationRegistry address (or zero)
    /// @param _owner                Contract owner (timelock in prod)
    /// @param _quorumThreshold      Number of PASS votes required for quorum
    constructor(
        address _acpContract,
        address _registry,
        address _reputationRegistry,
        address _owner,
        uint256 _quorumThreshold
    ) Ownable(_owner) {
        if (_acpContract == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        acpContract        = _acpContract;
        registry           = SigilXCertificateRegistry(_registry);
        reputationRegistry = _reputationRegistry;
        quorumThreshold    = _quorumThreshold;
    }

    // ──────────────────────────────────────────────
    // Evaluator Management (onlyOwner)
    // ──────────────────────────────────────────────

    function addEvaluator(address evaluator) external onlyOwner {
        if (evaluator == address(0)) revert ZeroAddress();
        if (!_evaluators.add(evaluator)) revert EvaluatorAlreadyRegistered(evaluator);
        emit EvaluatorAdded(evaluator);
    }

    function removeEvaluator(address evaluator) external onlyOwner {
        if (!_evaluators.remove(evaluator)) revert EvaluatorNotRegistered(evaluator);

        // If quorum threshold is now impossible, clamp it
        uint256 len = _evaluators.length();
        if (quorumThreshold > len && len > 0) {
            quorumThreshold = len;
        }

        emit EvaluatorRemoved(evaluator);
    }

    function setQuorumThreshold(uint256 threshold) external onlyOwner {
        if (threshold == 0 || threshold > _evaluators.length()) {
            revert InvalidQuorumThreshold(threshold, _evaluators.length());
        }
        quorumThreshold = threshold;
    }

    function getEvaluatorCount() external view returns (uint256) {
        return _evaluators.length();
    }

    function getEvaluators() external view returns (address[] memory) {
        return _evaluators.values();
    }

    /// @notice Check if an address is a registered evaluator.
    function isEvaluator(address account) external view returns (bool) {
        return _evaluators.contains(account);
    }

    // ──────────────────────────────────────────────
    // ERC-8183 Hook Interface
    // ──────────────────────────────────────────────

    /// @notice Called by ACP before a core action. Stages pending job on submit.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            if (deliverable == bytes32(0)) revert ZeroCertHash();

            bytes32 theoremHash;
            if (optParams.length >= 32) {
                theoremHash = abi.decode(optParams, (bytes32));
            }

            _pendingJobs[jobId] = PendingJob({
                certHash:        deliverable,
                theoremHash:     theoremHash,
                evaluationCount: 0,
                passCount:       0,
                failCount:       0,
                finalized:       false,
                exists:          true
            });
        }
    }

    /// @notice Called by ACP after a core action. Writes reputation on complete.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override onlyACP nonReentrant {
        if (selector == COMPLETE_SELECTOR) {
            bytes32 certHash = registry.certHashForJob(jobId);
            if (certHash == bytes32(0)) return; // No cert yet, skip

            ISigilXCertificateRegistry.CertMetadata memory meta = registry.getCertMetadata(certHash);

            if (reputationRegistry != address(0)) {
                try SimpleReputationRegistry(reputationRegistry).giveFeedback(
                    jobId,       // agentId
                    int128(100), // value (positive)
                    2,           // valueDecimals
                    "sigilx:quorum-verified", // tag1
                    "formal-proof",           // tag2
                    "",                       // endpoint (unused)
                    string(abi.encodePacked("cert:", certHash)), // feedbackURI
                    certHash                  // feedbackHash
                ) {} catch {
                    // Best-effort: don't block completion on reputation failure
                }
            }

            emit SigilXAttestation(jobId, certHash, meta.theoremHash, meta.verdict, block.timestamp);
        }
    }

    // ──────────────────────────────────────────────
    // Evaluation Submission
    // ──────────────────────────────────────────────

    /// @notice Called by each evaluator after independent verification.
    /// @param jobId    The ACP job ID
    /// @param verdict  true = PASS, false = FAIL
    /// @param certHash The evaluator's computed certificate hash
    function submitEvaluation(uint256 jobId, bool verdict, bytes32 certHash) external onlyRegisteredEvaluator nonReentrant {
        PendingJob storage job = _pendingJobs[jobId];
        if (!job.exists) revert JobDoesNotExist(jobId);
        if (job.finalized) revert JobAlreadyFinalized(jobId);
        if (hasEvaluated[jobId][msg.sender]) revert AlreadyEvaluated(jobId, msg.sender);

        // Record evaluation
        hasEvaluated[jobId][msg.sender] = true;
        job.evaluationCount++;

        if (verdict) {
            job.passCount++;
        } else {
            job.failCount++;
        }

        jobEvaluations[jobId].push(Evaluation({
            evaluator: msg.sender,
            verdict:   verdict,
            certHash:  certHash,
            timestamp: block.timestamp
        }));

        emit EvaluationSubmitted(jobId, msg.sender, verdict);

        // Check finalization conditions
        _checkQuorum(jobId);
    }

    // ──────────────────────────────────────────────
    // Internal Quorum Logic
    // ──────────────────────────────────────────────

    function _checkQuorum(uint256 jobId) internal {
        PendingJob storage job = _pendingJobs[jobId];
        uint256 totalEvaluators = _evaluators.length();

        // PASS quorum reached
        if (job.passCount >= quorumThreshold) {
            job.finalized = true;

            // Write certificate to registry using the job's certHash
            registry.registerCertificate(jobId, job.certHash, job.theoremHash, true);

            emit QuorumReached(jobId, true, job.passCount, job.failCount);
            return;
        }

        // FAIL: impossible to reach quorum (remaining votes can't push pass over threshold)
        uint256 remainingVotes = totalEvaluators - job.evaluationCount;
        if (job.passCount + remainingVotes < quorumThreshold) {
            job.finalized = true;
            emit QuorumReached(jobId, false, job.passCount, job.failCount);
            return;
        }

        // All evaluators voted but no clear quorum -> DIVERGENCE
        if (job.evaluationCount == totalEvaluators && !job.finalized) {
            job.finalized = true;
            emit Divergence(jobId, job.passCount, job.failCount);
        }
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getPendingJob(uint256 jobId)
        external view
        returns (
            bytes32 certHash,
            bytes32 theoremHash,
            uint256 evaluationCount,
            uint256 passCount,
            uint256 failCount,
            bool    finalized,
            bool    exists_
        )
    {
        PendingJob storage j = _pendingJobs[jobId];
        return (j.certHash, j.theoremHash, j.evaluationCount, j.passCount, j.failCount, j.finalized, j.exists);
    }

    function getJobEvaluations(uint256 jobId) external view returns (Evaluation[] memory) {
        return jobEvaluations[jobId];
    }

    // ──────────────────────────────────────────────
    // Admin Setters (onlyOwner, via Timelock in prod)
    // ──────────────────────────────────────────────

    function setACPContract(address _acp) external onlyOwner {
        emit ACPContractUpdated(acpContract, _acp);
        acpContract = _acp;
    }

    function setRegistry(address _registry) external onlyOwner {
        registry = SigilXCertificateRegistry(_registry);
    }

    function setReputationRegistry(address _rep) external onlyOwner {
        reputationRegistry = _rep;
    }
}

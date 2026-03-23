// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "../interfaces/IACPHook.sol";
import "./ISigilXCertificateRegistry.sol";
import "./SimpleReputationRegistryV1.sol";

contract SigilXQuorumHookV1 is IACPHook, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    struct Evaluation { address evaluator; bool verdict; bytes32 certHash; uint256 timestamp; }
    struct PendingJob { bytes32 certHash; bytes32 theoremHash; uint256 evaluationCount; uint256 passCount; uint256 failCount; bool finalized; bool exists; }

    bytes4 public constant SUBMIT_SELECTOR = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR = bytes4(keccak256("complete(uint256,bytes32,bytes)"));

    address public acpContract;
    ISigilXCertificateRegistry public registry;
    address public reputationRegistry;
    EnumerableSet.AddressSet private _evaluators;
    uint256 public quorumThreshold;
    mapping(uint256 => PendingJob) private _pendingJobs;
    mapping(uint256 => Evaluation[]) public jobEvaluations;
    mapping(uint256 => mapping(address => bool)) public hasEvaluated;

    event EvaluatorAdded(address indexed evaluator);
    event EvaluatorRemoved(address indexed evaluator);
    event EvaluationSubmitted(uint256 indexed jobId, address indexed evaluator, bool verdict);
    event QuorumReached(uint256 indexed jobId, bool finalVerdict, uint256 passCount, uint256 failCount);
    event Divergence(uint256 indexed jobId, uint256 passCount, uint256 failCount);
    event ACPContractUpdated(address indexed oldACP, address indexed newACP);
    event SigilXAttestation(uint256 indexed jobId, bytes32 indexed certHash, bytes32 theoremHash, bool verdict, uint256 timestamp);

    error OnlyACPContract();
    error ZeroCertHash();
    error NotEvaluator(address caller);
    error AlreadyEvaluated(uint256 jobId, address evaluator);
    error JobAlreadyFinalized(uint256 jobId);
    error JobDoesNotExist(uint256 jobId);
    error EvaluatorAlreadyRegistered(address evaluator);
    error EvaluatorNotRegistered(address evaluator);
    error InvalidQuorumThreshold(uint256 threshold, uint256 evaluatorCount);
    error ZeroAddress();

    modifier onlyACP() { if (msg.sender != acpContract) revert OnlyACPContract(); _; }
    modifier onlyRegisteredEvaluator() { if (!_evaluators.contains(msg.sender)) revert NotEvaluator(msg.sender); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _acpContract, address _registry, address _reputationRegistry, address _owner, uint256 _quorumThreshold) public initializer {
        if (_acpContract == address(0)) revert ZeroAddress();
        if (_registry == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        acpContract = _acpContract;
        registry = ISigilXCertificateRegistry(_registry);
        reputationRegistry = _reputationRegistry;
        quorumThreshold = _quorumThreshold;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function addEvaluator(address evaluator) external onlyOwner { if (evaluator == address(0)) revert ZeroAddress(); if (!_evaluators.add(evaluator)) revert EvaluatorAlreadyRegistered(evaluator); emit EvaluatorAdded(evaluator); }
    function removeEvaluator(address evaluator) external onlyOwner { if (!_evaluators.remove(evaluator)) revert EvaluatorNotRegistered(evaluator); uint256 len = _evaluators.length(); if (quorumThreshold > len && len > 0) quorumThreshold = len; emit EvaluatorRemoved(evaluator); }
    function setQuorumThreshold(uint256 threshold) external onlyOwner { if (threshold == 0 || threshold > _evaluators.length()) revert InvalidQuorumThreshold(threshold, _evaluators.length()); quorumThreshold = threshold; }
    function getEvaluatorCount() external view returns (uint256) { return _evaluators.length(); }
    function getEvaluators() external view returns (address[] memory) { return _evaluators.values(); }
    function isEvaluator(address account) external view returns (bool) { return _evaluators.contains(account); }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            if (deliverable == bytes32(0)) revert ZeroCertHash();
            bytes32 theoremHash;
            if (optParams.length >= 32) theoremHash = abi.decode(optParams, (bytes32));
            _pendingJobs[jobId] = PendingJob({ certHash: deliverable, theoremHash: theoremHash, evaluationCount: 0, passCount: 0, failCount: 0, finalized: false, exists: true });
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override onlyACP nonReentrant {
        if (selector == COMPLETE_SELECTOR) {
            bytes32 certHash = registry.certHashForJob(jobId);
            if (certHash == bytes32(0)) return;
            ISigilXCertificateRegistry.CertMetadata memory meta = registry.getCertMetadata(certHash);
            if (reputationRegistry != address(0)) {
                try SimpleReputationRegistryV1(reputationRegistry).giveFeedback(jobId, int128(100), 2, "sigilx:quorum-verified", "formal-proof", "", string(abi.encodePacked("cert:", certHash)), certHash) {} catch {}
            }
            emit SigilXAttestation(jobId, certHash, meta.theoremHash, meta.verdict, block.timestamp);
        }
    }

    function submitEvaluation(uint256 jobId, bool verdict, bytes32 certHash) external onlyRegisteredEvaluator nonReentrant {
        PendingJob storage job = _pendingJobs[jobId];
        if (!job.exists) revert JobDoesNotExist(jobId);
        if (job.finalized) revert JobAlreadyFinalized(jobId);
        if (hasEvaluated[jobId][msg.sender]) revert AlreadyEvaluated(jobId, msg.sender);
        hasEvaluated[jobId][msg.sender] = true;
        job.evaluationCount++;
        if (verdict) job.passCount++; else job.failCount++;
        jobEvaluations[jobId].push(Evaluation({ evaluator: msg.sender, verdict: verdict, certHash: certHash, timestamp: block.timestamp }));
        emit EvaluationSubmitted(jobId, msg.sender, verdict);
        _checkQuorum(jobId);
    }

    function _checkQuorum(uint256 jobId) internal {
        PendingJob storage job = _pendingJobs[jobId];
        uint256 totalEvaluators = _evaluators.length();
        if (job.passCount >= quorumThreshold) { job.finalized = true; ISigilXCertificateRegistry(address(registry)).registerCertificate(jobId, job.certHash, job.theoremHash, true); emit QuorumReached(jobId, true, job.passCount, job.failCount); return; }
        uint256 remainingVotes = totalEvaluators - job.evaluationCount;
        if (job.passCount + remainingVotes < quorumThreshold) { job.finalized = true; emit QuorumReached(jobId, false, job.passCount, job.failCount); return; }
        if (job.evaluationCount == totalEvaluators && !job.finalized) { job.finalized = true; emit Divergence(jobId, job.passCount, job.failCount); }
    }

    function getPendingJob(uint256 jobId) external view returns (bytes32, bytes32, uint256, uint256, uint256, bool, bool) { PendingJob storage j = _pendingJobs[jobId]; return (j.certHash, j.theoremHash, j.evaluationCount, j.passCount, j.failCount, j.finalized, j.exists); }
    function getJobEvaluations(uint256 jobId) external view returns (Evaluation[] memory) { return jobEvaluations[jobId]; }
    function setACPContract(address _acp) external onlyOwner { emit ACPContractUpdated(acpContract, _acp); acpContract = _acp; }
    function setRegistry(address _registry) external onlyOwner { registry = ISigilXCertificateRegistry(_registry); }
    function setReputationRegistry(address _rep) external onlyOwner { reputationRegistry = _rep; }
}

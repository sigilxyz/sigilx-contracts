// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IVRFCoordinatorV2Plus.sol";
import "./interfaces/IEvaluatorRegistry.sol";
import "./interfaces/ISigilXEvaluatorV2.sol";

/// @title VRFCommitteeSelector
/// @notice Integrates Chainlink VRF v2.5 to randomly assign evaluator committees
///         for BFT job evaluation. On VRF callback, selects a committee from the
///         EvaluatorRegistry and initializes an evaluation on SigilXEvaluatorV2.
/// @dev Uses a local IVRFCoordinatorV2Plus interface. When @chainlink/contracts
///      is available, swap to the canonical VRFConsumerBaseV2Plus base contract.
///      Deployed behind an ERC1967 UUPS proxy for upgradeability.
contract VRFCommitteeSelector is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // =========================================================================
    // Types
    // =========================================================================

    struct PendingRequest {
        uint256 jobId;
        uint256 jobValue;
        bool fulfilled;
    }

    /// @dev Type tag for replacement requests vs committee requests
    struct ReplacementRequest {
        uint256 jobId;
        address inactiveMember;
        bool fulfilled;
    }

    // =========================================================================
    // State
    // =========================================================================

    /// @notice Chainlink VRF v2.5 coordinator
    IVRFCoordinatorV2Plus public vrfCoordinator;

    /// @notice Registry of evaluators for committee selection
    address public evaluatorRegistry;

    /// @notice SigilXEvaluatorV2 contract for initializing evaluations
    address public evaluatorContract;

    /// @notice Chainlink VRF subscription ID
    uint256 public subscriptionId;

    /// @notice Chainlink VRF key hash
    bytes32 public keyHash;

    /// @notice Number of block confirmations before VRF fulfillment
    uint16 public requestConfirmations;

    /// @notice Gas limit for VRF callback
    uint32 public callbackGasLimit;

    /// @notice requestId => PendingRequest
    mapping(uint256 => PendingRequest) public pendingRequests;

    /// @notice requestId => ReplacementRequest
    mapping(uint256 => ReplacementRequest) public replacementRequests;

    /// @notice jobId => whether a committee request is already pending/fulfilled
    mapping(uint256 => bool) public jobRequested;

    // =========================================================================
    // Events
    // =========================================================================

    event CommitteeRequested(uint256 indexed jobId, uint256 indexed requestId, uint256 jobValue);
    event CommitteeAssigned(uint256 indexed jobId, address[] committee, uint256 randomSeed);
    event ReplacementRequested(uint256 indexed jobId, address indexed inactiveMember, uint256 indexed requestId);
    event ReplacementAssigned(uint256 indexed jobId, address indexed replacement, address indexed replaced);
    event EvaluatorContractSet(address indexed evaluatorContract);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error EvaluatorContractNotSet();
    error DuplicateRequest();
    error RequestNotFound();
    error RequestAlreadyFulfilled();
    error OnlyVRFCoordinator();

    // =========================================================================
    // Constructor (disabled for proxy) & Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _vrfCoordinator Address of the Chainlink VRF v2.5 coordinator
    /// @param _evaluatorRegistry Address of the EvaluatorRegistry contract
    /// @param _subscriptionId Chainlink VRF subscription ID
    /// @param _keyHash Chainlink VRF key hash for the gas lane
    /// @param _owner The initial owner address
    function initialize(
        address _vrfCoordinator,
        address _evaluatorRegistry,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        address _owner
    ) external initializer {
        if (_vrfCoordinator == address(0)) revert ZeroAddress();
        if (_evaluatorRegistry == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        // __UUPSUpgradeable_init(); // Not available in this OZ version (no-op anyway)

        vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        evaluatorRegistry = _evaluatorRegistry;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        requestConfirmations = 3;
        callbackGasLimit = 500_000;
    }

    /// @notice UUPS authorization — only owner can upgrade
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Committee Request
    // =========================================================================

    /// @notice Request a random committee for a job. Called by OptimisticEscrow or ACP contract.
    /// @param jobId The job ID that needs evaluation
    /// @param jobValue The value of the job (determines committee size)
    /// @return requestId The VRF request ID
    function requestCommittee(uint256 jobId, uint256 jobValue) external nonReentrant returns (uint256 requestId) {
        if (evaluatorContract == address(0)) revert EvaluatorContractNotSet();
        if (jobRequested[jobId]) revert DuplicateRequest();

        jobRequested[jobId] = true;

        // Encode VRF request parameters
        bytes memory extraArgs = abi.encode(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            uint32(1) // numWords — we only need one random word
        );

        requestId = vrfCoordinator.requestRandomWords(extraArgs);

        pendingRequests[requestId] = PendingRequest({
            jobId: jobId,
            jobValue: jobValue,
            fulfilled: false
        });

        emit CommitteeRequested(jobId, requestId, jobValue);
    }

    /// @notice Request a single replacement for an inactive committee member.
    /// @param jobId The job ID
    /// @param inactiveMember Address of the member being replaced
    /// @return requestId The VRF request ID
    function requestReplacement(uint256 jobId, address inactiveMember) external nonReentrant returns (uint256 requestId) {
        if (evaluatorContract == address(0)) revert EvaluatorContractNotSet();

        bytes memory extraArgs = abi.encode(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            uint32(1)
        );

        requestId = vrfCoordinator.requestRandomWords(extraArgs);

        replacementRequests[requestId] = ReplacementRequest({
            jobId: jobId,
            inactiveMember: inactiveMember,
            fulfilled: false
        });

        emit ReplacementRequested(jobId, inactiveMember, requestId);
    }

    // =========================================================================
    // VRF Callback
    // =========================================================================

    /// @notice VRF callback — called by the VRF coordinator with random words.
    /// @dev In production with the real Chainlink base contract, this would be
    ///      an internal override. With our local interface, the coordinator
    ///      calls this directly.
    /// @param requestId The VRF request ID
    /// @param randomWords Array of random words (we use index 0)
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert OnlyVRFCoordinator();
        _fulfillRandomWords(requestId, randomWords);
    }

    function _fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal {
        // Check if this is a committee request
        PendingRequest storage req = pendingRequests[requestId];
        if (req.jobValue != 0 || req.jobId != 0) {
            _fulfillCommitteeRequest(requestId, req, randomWords);
            return;
        }

        // Check if this is a replacement request
        ReplacementRequest storage repReq = replacementRequests[requestId];
        if (repReq.inactiveMember != address(0)) {
            _fulfillReplacementRequest(requestId, repReq, randomWords);
            return;
        }

        revert RequestNotFound();
    }

    function _fulfillCommitteeRequest(
        uint256,
        PendingRequest storage req,
        uint256[] calldata randomWords
    ) internal {
        if (req.fulfilled) revert RequestAlreadyFulfilled();
        req.fulfilled = true;

        uint256 seed = randomWords[0];
        uint8 committeeSize = IEvaluatorRegistry(evaluatorRegistry).committeeSizeForValue(req.jobValue);
        address[] memory _committee = IEvaluatorRegistry(evaluatorRegistry).selectCommittee(seed, committeeSize);

        ISigilXEvaluatorV2(evaluatorContract).initializeEvaluation(req.jobId, _committee, req.jobValue);

        emit CommitteeAssigned(req.jobId, _committee, seed);
    }

    function _fulfillReplacementRequest(
        uint256,
        ReplacementRequest storage repReq,
        uint256[] calldata randomWords
    ) internal {
        if (repReq.fulfilled) revert RequestAlreadyFulfilled();
        repReq.fulfilled = true;

        uint256 seed = randomWords[0];
        // Select a single replacement
        address[] memory replacement = IEvaluatorRegistry(evaluatorRegistry).selectCommittee(seed, uint8(1));

        // Look up the evalId for this jobId and propagate the replacement
        uint256 evalId = ISigilXEvaluatorV2(evaluatorContract).vrfJobEvaluation(repReq.jobId);
        if (evalId != 0) {
            ISigilXEvaluatorV2(evaluatorContract).replaceCommitteeMember(evalId, repReq.inactiveMember, replacement[0]);
        }

        emit ReplacementAssigned(repReq.jobId, replacement[0], repReq.inactiveMember);
    }

    // =========================================================================
    // Governance (owner only)
    // =========================================================================

    /// @notice Set the evaluator contract (SigilXEvaluatorV2) — owner only
    /// @param _evaluator Address of the SigilXEvaluatorV2 contract
    function setEvaluatorContract(address _evaluator) external onlyOwner {
        if (_evaluator == address(0)) revert ZeroAddress();
        evaluatorContract = _evaluator;
        emit EvaluatorContractSet(_evaluator);
    }

    /// @notice Update VRF request confirmations — owner only
    function setRequestConfirmations(uint16 _confirmations) external onlyOwner {
        requestConfirmations = _confirmations;
    }

    /// @notice Update VRF callback gas limit — owner only
    function setCallbackGasLimit(uint32 _gasLimit) external onlyOwner {
        callbackGasLimit = _gasLimit;
    }

    // =========================================================================
    // Storage Gap (H-2 audit fix: reserve slots for future upgrades)
    // =========================================================================

    uint256[50] private __gap;
}

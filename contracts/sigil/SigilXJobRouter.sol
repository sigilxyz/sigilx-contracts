// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../utils/ReentrancyGuardUpgradeable.sol";
import "../interfaces/IERC8183.sol";
import "../sigil/ISigilXCertificateRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title SigilXJobRouter
/// @notice Atomic settlement router for SigilX verification jobs.
///         Wraps ERC-8183 job lifecycle and ensures that completion + certificate
///         minting happen in a single transaction — both succeed or both revert.
///         Separates service fee, platform fee, and gas reserve in the quote.
/// @dev Deployed behind an ERC1967 UUPS proxy for upgradeability.
contract SigilXJobRouter is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    struct JobInfo {
        address client;
        uint256 serviceFee;      // USDC for verification work → provider
        uint256 gasFee;          // USDC equivalent reserved for cert minting gas → refunded to client
        uint256 platformFee;     // USDC for protocol treasury
        bytes32 inputHash;       // hash of the proof/contract being verified
        uint256 acpJobId;        // job ID on the underlying ERC-8183 contract
        uint256 createdAt;
        uint256 expiredAt;
        bool settled;            // true once completed, rejected, or refunded
    }

    // =========================================================================
    // State
    // =========================================================================

    /// @notice ERC-20 token used for payments (USDC)
    IERC20 public paymentToken;

    /// @notice The underlying ERC-8183 contract
    IERC8183 public acpContract;

    /// @notice The certificate registry for atomic cert minting
    ISigilXCertificateRegistry public certRegistry;

    /// @notice Address that receives service fees (verification provider)
    address public provider;

    /// @notice Address that receives platform fees (protocol treasury)
    address public treasury;

    /// @notice Address authorized to call completeAndCertify / rejectJob
    address public evaluator;

    /// @notice Default job expiry duration in seconds (24 hours)
    uint256 public defaultExpiry;

    /// @notice Auto-incrementing internal job counter
    uint256 public nextJobId;

    /// @notice jobId => JobInfo
    mapping(uint256 => JobInfo) public jobs;

    // =========================================================================
    // Storage Gap (H-2 audit fix: reserve slots for future upgrades)
    // =========================================================================

    uint256[50] private __gap;

    // =========================================================================
    // Events
    // =========================================================================

    event JobCreatedAndFunded(
        uint256 indexed jobId,
        address indexed client,
        uint256 serviceFee,
        uint256 gasFee,
        uint256 platformFee,
        bytes32 inputHash,
        uint256 acpJobId
    );

    event JobCompletedAndCertified(
        uint256 indexed jobId,
        bytes32 deliverableHash,
        bytes32 certHash,
        bytes32 theoremHash,
        address indexed client
    );

    event JobRejected(uint256 indexed jobId, bytes32 reasonHash, address indexed client, uint256 refundTotal);

    event JobRefundClaimed(uint256 indexed jobId, address indexed client, uint256 refundTotal);

    event EvaluatorUpdated(address indexed oldEvaluator, address indexed newEvaluator);
    event ProviderUpdated(address indexed oldProvider, address indexed newProvider);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DefaultExpiryUpdated(uint256 oldExpiry, uint256 newExpiry);
    event CertRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error ZeroAmount();
    error JobNotFound();
    error JobAlreadySettled();
    error JobNotExpired();
    error OnlyEvaluator();
    error OnlyClientOrEvaluator();
    error InsufficientAllowance();
    error InvalidExpiry();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyEvaluator() {
        if (msg.sender != evaluator && msg.sender != owner()) revert OnlyEvaluator();
        _;
    }

    // =========================================================================
    // Constructor (disabled for proxy) & Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _paymentToken  ERC-20 token for payments (USDC)
    /// @param _acpContract   The ERC-8183 contract to interact with
    /// @param _certRegistry  The SigilXCertificateRegistryV1 for cert minting
    /// @param _provider      Address receiving service fees
    /// @param _treasury      Address receiving platform fees
    /// @param _evaluator     Address authorized to complete/reject jobs
    /// @param _owner         The initial owner address
    function initialize(
        address _paymentToken,
        address _acpContract,
        address _certRegistry,
        address _provider,
        address _treasury,
        address _evaluator,
        address _owner
    ) external initializer {
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_acpContract == address(0)) revert ZeroAddress();
        if (_certRegistry == address(0)) revert ZeroAddress();
        if (_provider == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_evaluator == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init();

        paymentToken = IERC20(_paymentToken);
        acpContract = IERC8183(_acpContract);
        certRegistry = ISigilXCertificateRegistry(_certRegistry);
        provider = _provider;
        treasury = _treasury;
        evaluator = _evaluator;
        defaultExpiry = 24 hours;
        nextJobId = 1;
    }

    /// @notice UUPS authorization — only owner can upgrade
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Job Creation
    // =========================================================================

    /// @notice Create and fund a verification job. Transfers total payment from
    ///         client into this contract and creates an ERC-8183 job on-chain.
    /// @param client      Who is paying
    /// @param serviceFee  USDC for verification work
    /// @param gasFee      USDC equivalent reserved for cert minting gas
    /// @param platformFee USDC for protocol treasury
    /// @param inputHash   Hash of the proof/contract being verified
    /// @return jobId      Internal job ID
    function createAndFundJob(
        address client,
        uint256 serviceFee,
        uint256 gasFee,
        uint256 platformFee,
        bytes32 inputHash
    ) external nonReentrant returns (uint256 jobId) {
        uint256 total = serviceFee + gasFee + platformFee;
        if (total == 0) revert ZeroAmount();
        if (client == address(0)) revert ZeroAddress();

        // Pull total payment from the caller (gateway) into this contract
        paymentToken.safeTransferFrom(msg.sender, address(this), total);

        // Create ERC-8183 job on the ACP contract
        uint256 expiredAt = block.timestamp + defaultExpiry;
        uint256 acpJobId = acpContract.createJob(
            provider,          // provider
            address(this),     // evaluator = this contract (we call complete)
            expiredAt,
            "SigilX verification job",
            address(0)         // no hook
        );

        // Set budget and fund the ACP job
        acpContract.setBudget(acpJobId, serviceFee, "");

        // Approve the ACP contract to pull payment for funding
        // H-1 fix: use forceApprove instead of approve to handle non-standard
        // tokens like USDT that require approve(0) before approve(amount)
        if (serviceFee > 0) {
            paymentToken.forceApprove(address(acpContract), serviceFee);
            acpContract.fund(acpJobId, serviceFee, "");
        }

        jobId = nextJobId++;
        jobs[jobId] = JobInfo({
            client: client,
            serviceFee: serviceFee,
            gasFee: gasFee,
            platformFee: platformFee,
            inputHash: inputHash,
            acpJobId: acpJobId,
            createdAt: block.timestamp,
            expiredAt: expiredAt,
            settled: false
        });

        emit JobCreatedAndFunded(jobId, client, serviceFee, gasFee, platformFee, inputHash, acpJobId);
    }

    // =========================================================================
    // Atomic Completion + Certification
    // =========================================================================

    /// @notice Complete a verification job AND mint a certificate atomically.
    ///         In ONE transaction: complete ERC-8183 job, release service fee to
    ///         provider, send platform fee to treasury, register certificate,
    ///         and refund unused gas fee to client.
    ///         If ANY step fails, entire tx reverts — no partial state.
    /// @param jobId           Internal job ID
    /// @param deliverableHash Hash of verification result (for ERC-8183)
    /// @param certHash        Certificate hash for the registry
    /// @param theoremHash     Theorem hash for the certificate
    function completeAndCertify(
        uint256 jobId,
        bytes32 deliverableHash,
        bytes32 certHash,
        bytes32 theoremHash
    ) external onlyEvaluator nonReentrant {
        JobInfo storage job = jobs[jobId];
        if (job.client == address(0)) revert JobNotFound();
        if (job.settled) revert JobAlreadySettled();

        job.settled = true;

        // Step 1: Submit deliverable on the ACP contract
        acpContract.submit(job.acpJobId, deliverableHash, "");

        // Step 2: Complete the ERC-8183 job (releases escrowed funds per ACP rules)
        acpContract.complete(job.acpJobId, deliverableHash, "");

        // Step 3: Release platform fee to treasury
        if (job.platformFee > 0) {
            paymentToken.safeTransfer(treasury, job.platformFee);
        }

        // Step 4: Register certificate on-chain (ATOMIC — reverts if it fails)
        // Use the ACP job ID as the certificate's jobId for on-chain correlation
        certRegistry.registerCertificate(
            job.acpJobId,
            certHash,
            theoremHash,
            true // verdict = PASS (only called on successful verification)
        );

        // Step 5: Refund unused gas fee to client
        if (job.gasFee > 0) {
            paymentToken.safeTransfer(job.client, job.gasFee);
        }

        emit JobCompletedAndCertified(jobId, deliverableHash, certHash, theoremHash, job.client);
    }

    // =========================================================================
    // Rejection (Full Refund)
    // =========================================================================

    /// @notice Reject a job when verification fails. Refunds ALL fees to client.
    /// @param jobId      Internal job ID
    /// @param reasonHash Hash of rejection reason
    function rejectJob(uint256 jobId, bytes32 reasonHash) external onlyEvaluator nonReentrant {
        JobInfo storage job = jobs[jobId];
        if (job.client == address(0)) revert JobNotFound();
        if (job.settled) revert JobAlreadySettled();

        job.settled = true;

        // Reject on the ACP contract
        acpContract.reject(job.acpJobId, reasonHash, "");

        // Refund everything to client (service + gas + platform)
        uint256 refundTotal = job.serviceFee + job.gasFee + job.platformFee;
        if (refundTotal > 0) {
            paymentToken.safeTransfer(job.client, refundTotal);
        }

        emit JobRejected(jobId, reasonHash, job.client, refundTotal);
    }

    // =========================================================================
    // Timeout / Expiry Refund
    // =========================================================================

    /// @notice Claim a refund for an expired job. Non-hookable, always works.
    ///         Can be called by anyone after expiry, but refund goes to client.
    /// @param jobId Internal job ID
    function claimRefund(uint256 jobId) external nonReentrant {
        JobInfo storage job = jobs[jobId];
        if (job.client == address(0)) revert JobNotFound();
        if (job.settled) revert JobAlreadySettled();
        if (block.timestamp < job.expiredAt) revert JobNotExpired();

        job.settled = true;

        // Claim refund on the ACP contract (may or may not succeed depending on ACP state)
        try acpContract.claimRefund(job.acpJobId) {} catch {}

        // Refund local fees to client regardless of ACP outcome
        uint256 refundTotal = job.gasFee + job.platformFee;
        // serviceFee may have been escrowed in ACP — the claimRefund above handles that
        // But if ACP refund failed, we still refund what we hold
        if (refundTotal > 0) {
            paymentToken.safeTransfer(job.client, refundTotal);
        }

        emit JobRefundClaimed(jobId, job.client, refundTotal);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Get full job info
    function getJob(uint256 jobId) external view returns (JobInfo memory) {
        return jobs[jobId];
    }

    /// @notice Get total cost for a job (service + gas + platform)
    function getJobTotal(uint256 jobId) external view returns (uint256) {
        JobInfo storage job = jobs[jobId];
        return job.serviceFee + job.gasFee + job.platformFee;
    }

    // =========================================================================
    // Governance
    // =========================================================================

    function setEvaluator(address _evaluator) external onlyOwner {
        if (_evaluator == address(0)) revert ZeroAddress();
        emit EvaluatorUpdated(evaluator, _evaluator);
        evaluator = _evaluator;
    }

    function setProvider(address _provider) external onlyOwner {
        if (_provider == address(0)) revert ZeroAddress();
        emit ProviderUpdated(provider, _provider);
        provider = _provider;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setDefaultExpiry(uint256 _expiry) external onlyOwner {
        if (_expiry < 1 hours) revert InvalidExpiry();
        emit DefaultExpiryUpdated(defaultExpiry, _expiry);
        defaultExpiry = _expiry;
    }

    function setCertRegistry(address _certRegistry) external onlyOwner {
        if (_certRegistry == address(0)) revert ZeroAddress();
        emit CertRegistryUpdated(address(certRegistry), _certRegistry);
        certRegistry = ISigilXCertificateRegistry(_certRegistry);
    }
}

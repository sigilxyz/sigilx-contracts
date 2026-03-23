// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IVRFCoordinatorV2Plus.sol";
import "../utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title DisputeKernel
 * @author SigilX Formal Verification Team
 * @notice Unified escrow-dispute protocol hardened against 5 game-theoretic attack vectors:
 *         1. Deadline Sniping  2. Evidence Flooding  3. Partial-Completion Hostage
 *         4. Cross-Escrow Insolvency  5. Appeal Griefing
 * @dev Each guard is enforced via on-chain Certificate verification. Certificates are
 *      typed structs that carry the proof-of-compliance data for each guard.
 *
 *      Guard 5 uses Chainlink VRF v2.5 for verifiable randomness in panel selection.
 *      The appeal flow is split into two phases:
 *        Phase 1 (AppealRequest): Party appeals, VRF randomness is requested, pool snapshot frozen.
 *        Phase 2 (PanelAssignment): VRF callback delivers randomness, panel is deterministically derived.
 *
 *      Deployed behind an ERC1967 UUPS proxy for upgradeability.
 */
contract DisputeKernel is OwnableUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable {
    // ─── State (formerly immutable, now set in initialize for proxy compatibility) ──

    /// @notice Minimum number of blocks an adversary must be given to respond.
    uint256 public minResponseBlocks;

    /// @notice Maximum Merkle leaves allowed in a single evidence bundle.
    uint256 public maxLeaves;

    /// @notice Maximum bytes allowed in a single evidence bundle.
    uint256 public maxBytes;

    /// @notice Fee charged per byte of evidence submitted (in wei).
    uint256 public feePerByte;

    /// @notice Hard cap on appeal rounds to prevent infinite recursion.
    uint256 public maxRounds;

    /// @notice Base bond for the first appeal round (in wei). Legacy — use baseBondUsdc for stable value.
    uint256 public baseBond;

    /// @notice Base bond for the first appeal round denominated in USDC (6 decimals).
    ///         When nonzero, this takes priority over baseBond for appeal bond calculations.
    ///         Prevents bonds from becoming worthless at low native token prices.
    uint256 public baseBondUsdc;

    /// @notice VRFCommitteeSelector contract for requesting verifiable randomness.
    address public vrfCommitteeSelector;

    /// @notice VRF Coordinator address (for callback authentication).
    address public vrfCoordinator;

    // ─── Enums ───────────────────────────────────────────────────────────────────

    /// @notice Certificate type discriminator.
    enum CertType {
        DeadlineExtension,   // Guard 1: deadline sniping
        EvidenceSubmission,  // Guard 2: evidence flooding
        TrancheDispute,      // Guard 3: partial-completion hostage
        CollateralCheck,     // Guard 4: cross-escrow insolvency
        AppealStep,          // Guard 5: appeal griefing (legacy, kept for ABI compat)
        AppealRequest,       // Guard 5a: appeal request (VRF randomness requested)
        PanelAssignment      // Guard 5b: panel assignment (VRF callback fulfilled)
    }

    /// @notice Appeal state machine.
    enum AppealStatus {
        None,               // No appeal pending
        RandomnessRequested, // VRF request sent, awaiting callback
        PanelAssigned       // VRF fulfilled, panel derived
    }

    // ─── Structs ─────────────────────────────────────────────────────────────────

    /// @notice Unified certificate envelope carrying guard-specific payloads.
    struct Certificate {
        CertType certType;
        uint256 escrowId;
        address issuer;
        uint256 timestamp;
        bytes payload;
    }

    struct DeadlinePayload {
        uint256 oldDeadline;
        uint256 newDeadline;
        uint256 actionBlock;
    }

    struct EvidencePayload {
        uint8 side;
        uint256 round;
        uint256 leafCount;
        uint256 byteCount;
        uint256 bondPaid;
    }

    struct TranchePayload {
        uint256 trancheIndex;
        uint256 trancheAmount;
        uint256 prefixReleased;
        uint256 totalEscrow;
        uint256 lockedAmount;
    }

    struct CollateralPayload {
        address agent;
        uint256 postedCollateral;
        uint256 reservedBefore;
        uint256 delta;
    }

    /// @notice Guard 5 payload (legacy): proves an appeal step is valid.
    struct AppealPayload {
        uint256 currentRound;
        uint256 bondAmount;
        uint256 panelSeed;
    }

    /// @notice Guard 5a payload: appeal request with VRF randomness.
    struct AppealRequestPayload {
        bytes32 disputeId;
        uint8 roundBefore;
        bytes32 poolRoot;
        uint256 bondPaid;
    }

    /// @notice Guard 5b payload: panel assignment after VRF fulfillment.
    struct PanelAssignmentPayload {
        uint256 requestId;
        bytes32 disputeId;
        bytes32 poolRoot;
        uint256 vrfWord;
    }

    /// @notice Pending appeal data stored between VRF request and fulfillment.
    struct PendingAppeal {
        bytes32 disputeId;
        uint8 round;
        bytes32 poolRoot;
        uint256 bondPaid;
        uint256 escrowId;
        bool fulfilled;
    }

    /// @notice Appeal request certificate (emitted on successful request).
    struct AppealRequestCert {
        bytes32 disputeId;
        uint8 roundBefore;
        uint256 requestId;
        bytes32 poolRoot;
        uint256 requiredBond;
        uint256 bondPaid;
    }

    /// @notice Panel assignment certificate (emitted on VRF fulfillment).
    struct PanelAssignmentCert {
        uint256 requestId;
        bytes32 disputeId;
        uint8 round;
        bytes32 poolRoot;
        uint256 vrfWord;
        bytes32 panelRoot;
        uint8 roundAfter;
    }

    // ─── State ───────────────────────────────────────────────────────────────────

    /// @notice Per-escrow deadline (block number).
    mapping(uint256 => uint256) public escrowDeadline;

    /// @notice Per-escrow, per-side, per-round evidence submission flag.
    mapping(uint256 => mapping(uint8 => mapping(uint256 => bool))) public evidenceSubmitted;

    /// @notice Highest accepted (released) tranche index per escrow.
    mapping(uint256 => uint256) public acceptedTrancheIndex;

    /// @notice Currently disputed tranche index per escrow (type(uint256).max = none).
    mapping(uint256 => uint256) public disputedTrancheIndex;

    /// @notice Per-agent global reserved collateral.
    mapping(address => uint256) public reservedCollateral;

    /// @notice Per-agent global posted collateral.
    mapping(address => uint256) public postedCollateral;

    /// @notice Current appeal round per escrow.
    mapping(uint256 => uint256) public currentRound;

    /// @notice VRF requestId => PendingAppeal data.
    mapping(uint256 => PendingAppeal) public pendingAppeals;

    /// @notice (disputeId, round) => requestId. Prevents duplicate VRF requests for same round.
    mapping(bytes32 => mapping(uint8 => uint256)) public appealRequestIds;

    /// @notice Appeal status per escrow.
    mapping(uint256 => AppealStatus) public appealStatus;

    /// @notice VRF requestId => fulfilled vrfWord (stored on callback).
    mapping(uint256 => uint256) public vrfResults;

    /// @notice VRF requestId => whether the VRF callback has been received.
    mapping(uint256 => bool) public vrfFulfilled;

    /// @notice Authorized certificate issuers (only these addresses may call verifyCertificate).
    mapping(address => bool) public authorizedIssuers;

    // ─── Storage Gap (H-2 audit fix: reserve slots for future upgrades) ─────────

    uint256[50] private __gap;

    // ─── Events ──────────────────────────────────────────────────────────────────

    event DeadlineExtended(uint256 indexed escrowId, uint256 oldDeadline, uint256 newDeadline);
    event EvidenceRecorded(uint256 indexed escrowId, uint8 side, uint256 round, uint256 leafCount, uint256 byteCount);
    event TrancheDisputeOpened(uint256 indexed escrowId, uint256 trancheIndex, uint256 lockedAmount);
    event CollateralReserved(address indexed agent, uint256 delta, uint256 totalReserved);
    event AppealFiled(uint256 indexed escrowId, uint256 round, uint256 bondAmount, uint256 panelSeed);
    event CertificateVerified(uint256 indexed escrowId, CertType certType, address issuer);

    event AppealRandomnessRequested(
        uint256 indexed escrowId,
        bytes32 indexed disputeId,
        uint256 requestId,
        uint8 round,
        bytes32 poolRoot,
        uint256 bondPaid
    );

    event PanelAssigned(
        uint256 indexed escrowId,
        bytes32 indexed disputeId,
        uint256 requestId,
        uint8 roundAfter,
        bytes32 panelRoot,
        uint256 vrfWord
    );

    event VRFCallbackReceived(uint256 indexed requestId, uint256 vrfWord);

    // ─── Custom Errors ───────────────────────────────────────────────────────────

    error DeadlineNotExtended(uint256 newDeadline, uint256 requiredMinimum);
    error DeadlineReducedBelowOld(uint256 newDeadline, uint256 oldDeadline);
    error EvidenceTooManyLeaves(uint256 leafCount, uint256 maxAllowed);
    error EvidenceTooLarge(uint256 byteCount, uint256 maxAllowed);
    error EvidenceBondInsufficient(uint256 bondPaid, uint256 requiredBond);
    error EvidenceAlreadySubmitted(uint8 side, uint256 round);
    error LockExceedsDisputedTranche(uint256 lockedAmount, uint256 trancheAmount);
    error TrancheOutOfOrder(uint256 requested, uint256 nextExpected);
    error AnotherTrancheDisputed(uint256 alreadyDisputed);
    error InsufficientCollateral(uint256 reservedAfter, uint256 posted);
    error MaxRoundsExceeded(uint256 round, uint256 maxAllowed);
    error AppealBondTooLow(uint256 bondAmount, uint256 requiredBond);
    error AppealRoundMismatch(uint256 certRound, uint256 expectedRound);
    error DuplicateAppealRequest(bytes32 disputeId, uint8 round);
    error InvalidAppealState(uint256 escrowId, AppealStatus current, AppealStatus expected);
    error VRFNotFulfilled(uint256 requestId);
    error PoolRootMismatch(bytes32 expected, bytes32 actual);
    error DisputeIdMismatch(bytes32 expected, bytes32 actual);
    error VRFWordMismatch(uint256 expected, uint256 actual);
    error AppealAlreadyFulfilled(uint256 requestId);
    error OnlyVRFCoordinator();
    error InvalidCertType(CertType certType);
    error NotAuthorizedIssuer();

    // ─── Constructor (disabled for proxy) & Initializer ─────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract (called once via proxy)
    /// @param _minResponseBlocks Minimum blocks for adversarial response window.
    /// @param _maxLeaves Maximum Merkle leaves per evidence bundle.
    /// @param _maxBytes Maximum bytes per evidence bundle.
    /// @param _feePerByte Wei charged per evidence byte.
    /// @param _maxRounds Hard cap on appeal rounds.
    /// @param _baseBond Base bond for first appeal (doubles each round).
    /// @param _vrfCommitteeSelector Address of the VRFCommitteeSelector contract.
    /// @param _vrfCoordinator Address of the Chainlink VRF v2.5 coordinator.
    /// @param _owner The initial owner address.
    function initialize(
        uint256 _minResponseBlocks,
        uint256 _maxLeaves,
        uint256 _maxBytes,
        uint256 _feePerByte,
        uint256 _maxRounds,
        uint256 _baseBond,
        address _vrfCommitteeSelector,
        address _vrfCoordinator,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        // __UUPSUpgradeable_init(); // Not available in this OZ version (no-op anyway)
        minResponseBlocks = _minResponseBlocks;
        maxLeaves = _maxLeaves;
        maxBytes = _maxBytes;
        feePerByte = _feePerByte;
        maxRounds = _maxRounds;
        baseBond = _baseBond;
        vrfCommitteeSelector = _vrfCommitteeSelector;
        vrfCoordinator = _vrfCoordinator;
    }

    /// @notice UUPS authorization — only owner can upgrade
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ─── External API ────────────────────────────────────────────────────────────

    /// @notice Verify and apply a certificate. Reverts if any guard invariant is violated.
    /// @dev Only authorized issuers may call this function.
    function verifyCertificate(Certificate calldata cert) external nonReentrant {
        if (!authorizedIssuers[msg.sender]) revert NotAuthorizedIssuer();

        if (cert.certType == CertType.DeadlineExtension) {
            _verifyDeadlineExtension(cert);
        } else if (cert.certType == CertType.EvidenceSubmission) {
            _verifyEvidenceSubmission(cert);
        } else if (cert.certType == CertType.TrancheDispute) {
            _verifyTrancheDispute(cert);
        } else if (cert.certType == CertType.CollateralCheck) {
            _verifyCollateralCheck(cert);
        } else if (cert.certType == CertType.AppealStep) {
            _verifyAppealStep(cert);
        } else if (cert.certType == CertType.AppealRequest) {
            _verifyAppealRequest(cert);
        } else if (cert.certType == CertType.PanelAssignment) {
            _verifyPanelAssignment(cert);
        } else {
            revert InvalidCertType(cert.certType);
        }

        emit CertificateVerified(cert.escrowId, cert.certType, cert.issuer);
    }

    /// @notice VRF callback — called by the VRF coordinator with random words.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external nonReentrant {
        if (msg.sender != vrfCoordinator) revert OnlyVRFCoordinator();

        vrfResults[requestId] = randomWords[0];
        vrfFulfilled[requestId] = true;

        emit VRFCallbackReceived(requestId, randomWords[0]);
    }

    // ─── Admin helpers (for test setup) ──────────────────────────────────────────

    function setDeadline(uint256 escrowId, uint256 deadline) external onlyOwner {
        escrowDeadline[escrowId] = deadline;
    }

    function postCollateral(address agent, uint256 amount) external onlyOwner {
        postedCollateral[agent] += amount;
    }

    function setAcceptedTranche(uint256 escrowId, uint256 index) external onlyOwner {
        acceptedTrancheIndex[escrowId] = index;
    }

    function clearDisputedTranche(uint256 escrowId) external onlyOwner {
        disputedTrancheIndex[escrowId] = type(uint256).max;
    }

    function addAuthorizedIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = true;
    }

    function removeAuthorizedIssuer(address issuer) external onlyOwner {
        authorizedIssuers[issuer] = false;
    }

    /// @notice Set the USDC-denominated base bond for appeals.
    ///         When nonzero, USDC bond takes priority over ETH-denominated baseBond.
    /// @param _baseBondUsdc Base bond in USDC (6 decimals). E.g. 100e6 = $100.
    function setBaseBondUsdc(uint256 _baseBondUsdc) external onlyOwner {
        baseBondUsdc = _baseBondUsdc;
    }

    // ─── Guard 1: Deadline Sniping ───────────────────────────────────────────────

    function _verifyDeadlineExtension(Certificate calldata cert) internal {
        DeadlinePayload memory p = abi.decode(cert.payload, (DeadlinePayload));

        if (p.newDeadline < p.oldDeadline) {
            revert DeadlineReducedBelowOld(p.newDeadline, p.oldDeadline);
        }

        uint256 requiredMin = p.actionBlock + minResponseBlocks;
        if (p.newDeadline < requiredMin) {
            revert DeadlineNotExtended(p.newDeadline, requiredMin);
        }

        escrowDeadline[cert.escrowId] = p.newDeadline;

        emit DeadlineExtended(cert.escrowId, p.oldDeadline, p.newDeadline);
    }

    // ─── Guard 2: Evidence Flooding ──────────────────────────────────────────────

    function _verifyEvidenceSubmission(Certificate calldata cert) internal {
        EvidencePayload memory p = abi.decode(cert.payload, (EvidencePayload));

        if (evidenceSubmitted[cert.escrowId][p.side][p.round]) {
            revert EvidenceAlreadySubmitted(p.side, p.round);
        }

        if (p.leafCount > maxLeaves) {
            revert EvidenceTooManyLeaves(p.leafCount, maxLeaves);
        }

        if (p.byteCount > maxBytes) {
            revert EvidenceTooLarge(p.byteCount, maxBytes);
        }

        uint256 requiredBond = p.byteCount * feePerByte;
        if (p.bondPaid < requiredBond) {
            revert EvidenceBondInsufficient(p.bondPaid, requiredBond);
        }

        evidenceSubmitted[cert.escrowId][p.side][p.round] = true;

        emit EvidenceRecorded(cert.escrowId, p.side, p.round, p.leafCount, p.byteCount);
    }

    // ─── Guard 3: Partial-Completion Hostage ─────────────────────────────────────

    function _verifyTrancheDispute(Certificate calldata cert) internal {
        TranchePayload memory p = abi.decode(cert.payload, (TranchePayload));

        uint256 nextExpected = acceptedTrancheIndex[cert.escrowId];
        if (p.trancheIndex != nextExpected) {
            revert TrancheOutOfOrder(p.trancheIndex, nextExpected);
        }

        if (p.lockedAmount > p.trancheAmount) {
            revert LockExceedsDisputedTranche(p.lockedAmount, p.trancheAmount);
        }

        uint256 currentDisputed = disputedTrancheIndex[cert.escrowId];
        if (currentDisputed != type(uint256).max && currentDisputed != p.trancheIndex) {
            revert AnotherTrancheDisputed(currentDisputed);
        }

        disputedTrancheIndex[cert.escrowId] = p.trancheIndex;

        emit TrancheDisputeOpened(cert.escrowId, p.trancheIndex, p.lockedAmount);
    }

    // ─── Guard 4: Cross-Escrow Insolvency ────────────────────────────────────────

    function _verifyCollateralCheck(Certificate calldata cert) internal {
        CollateralPayload memory p = abi.decode(cert.payload, (CollateralPayload));

        uint256 reservedAfter = p.reservedBefore + p.delta;

        // Read collateral from on-chain mapping, not from the certificate payload
        uint256 onChainCollateral = postedCollateral[p.agent];
        if (reservedAfter > onChainCollateral) {
            revert InsufficientCollateral(reservedAfter, onChainCollateral);
        }

        reservedCollateral[p.agent] = reservedAfter;

        emit CollateralReserved(p.agent, p.delta, reservedAfter);
    }

    // ─── Guard 5: Appeal Griefing (Legacy) ──────────────────────────────────────

    function _verifyAppealStep(Certificate calldata cert) internal {
        AppealPayload memory p = abi.decode(cert.payload, (AppealPayload));

        uint256 expected = currentRound[cert.escrowId];
        if (p.currentRound != expected) {
            revert AppealRoundMismatch(p.currentRound, expected);
        }

        uint256 nextRound = p.currentRound + 1;
        if (nextRound > maxRounds) {
            revert MaxRoundsExceeded(nextRound, maxRounds);
        }

        uint256 effectiveBond = baseBondUsdc > 0 ? baseBondUsdc : baseBond;
        uint256 requiredBond = effectiveBond * (2 ** p.currentRound);
        if (p.bondAmount < requiredBond) {
            revert AppealBondTooLow(p.bondAmount, requiredBond);
        }

        currentRound[cert.escrowId] = nextRound;

        emit AppealFiled(cert.escrowId, nextRound, p.bondAmount, p.panelSeed);
    }

    // ─── Guard 5a: Appeal Request (VRF) ─────────────────────────────────────────

    function _verifyAppealRequest(Certificate calldata cert) internal {
        AppealRequestPayload memory p = abi.decode(cert.payload, (AppealRequestPayload));

        uint256 expected = currentRound[cert.escrowId];
        if (uint256(p.roundBefore) != expected) {
            revert AppealRoundMismatch(uint256(p.roundBefore), expected);
        }

        uint256 nextRound = uint256(p.roundBefore) + 1;
        if (nextRound > maxRounds) {
            revert MaxRoundsExceeded(nextRound, maxRounds);
        }

        uint256 effectiveBond = baseBondUsdc > 0 ? baseBondUsdc : baseBond;
        uint256 requiredBond = effectiveBond * (2 ** uint256(p.roundBefore));
        if (p.bondPaid < requiredBond) {
            revert AppealBondTooLow(p.bondPaid, requiredBond);
        }

        if (appealRequestIds[p.disputeId][p.roundBefore] != 0) {
            revert DuplicateAppealRequest(p.disputeId, p.roundBefore);
        }

        if (appealStatus[cert.escrowId] == AppealStatus.RandomnessRequested) {
            revert InvalidAppealState(cert.escrowId, appealStatus[cert.escrowId], AppealStatus.None);
        }

        // H-3 fix: write state BEFORE the external VRF call (checks-effects-interactions)
        appealStatus[cert.escrowId] = AppealStatus.RandomnessRequested;

        bytes memory extraArgs = abi.encode(p.disputeId, p.roundBefore);
        uint256 requestId = IVRFCoordinatorV2Plus(vrfCoordinator).requestRandomWords(extraArgs);

        pendingAppeals[requestId] = PendingAppeal({
            disputeId: p.disputeId,
            round: p.roundBefore,
            poolRoot: p.poolRoot,
            bondPaid: p.bondPaid,
            escrowId: cert.escrowId,
            fulfilled: false
        });

        appealRequestIds[p.disputeId][p.roundBefore] = requestId;

        emit AppealRandomnessRequested(
            cert.escrowId,
            p.disputeId,
            requestId,
            p.roundBefore,
            p.poolRoot,
            p.bondPaid
        );
    }

    // ─── Guard 5b: Panel Assignment (VRF Fulfillment) ───────────────────────────

    function _verifyPanelAssignment(Certificate calldata cert) internal {
        PanelAssignmentPayload memory p = abi.decode(cert.payload, (PanelAssignmentPayload));

        if (!vrfFulfilled[p.requestId]) {
            revert VRFNotFulfilled(p.requestId);
        }

        PendingAppeal storage pending = pendingAppeals[p.requestId];

        if (pending.fulfilled) {
            revert AppealAlreadyFulfilled(p.requestId);
        }

        if (pending.disputeId != p.disputeId) {
            revert DisputeIdMismatch(pending.disputeId, p.disputeId);
        }

        if (pending.poolRoot != p.poolRoot) {
            revert PoolRootMismatch(pending.poolRoot, p.poolRoot);
        }

        uint256 storedVrfWord = vrfResults[p.requestId];
        if (storedVrfWord != p.vrfWord) {
            revert VRFWordMismatch(storedVrfWord, p.vrfWord);
        }

        uint8 roundAfter = pending.round + 1;
        bytes32 panelRoot = keccak256(abi.encodePacked(
            p.disputeId,
            p.poolRoot,
            pending.round,
            p.vrfWord
        ));

        pending.fulfilled = true;
        currentRound[pending.escrowId] = uint256(roundAfter);
        appealStatus[pending.escrowId] = AppealStatus.PanelAssigned;

        emit PanelAssigned(
            pending.escrowId,
            p.disputeId,
            p.requestId,
            roundAfter,
            panelRoot,
            p.vrfWord
        );
    }

    // ─── View Helpers ────────────────────────────────────────────────────────────

    function requiredAppealBond(uint256 round) external view returns (uint256) {
        uint256 effectiveBond = baseBondUsdc > 0 ? baseBondUsdc : baseBond;
        return effectiveBond * (2 ** round);
    }

    function hasEvidence(uint256 escrowId, uint8 side, uint256 round) external view returns (bool) {
        return evidenceSubmitted[escrowId][side][round];
    }

    function derivePanel(uint256 seed, uint256 panelSize) external pure returns (address[] memory panel) {
        panel = new address[](panelSize);
        for (uint256 i = 0; i < panelSize; i++) {
            panel[i] = address(uint160(uint256(keccak256(abi.encodePacked(seed, i)))));
        }
    }

    function computePanelRoot(
        bytes32 disputeId,
        bytes32 poolRoot,
        uint8 round,
        uint256 vrfWord
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(disputeId, poolRoot, round, vrfWord));
    }

    function getPendingAppeal(uint256 requestId) external view returns (PendingAppeal memory) {
        return pendingAppeals[requestId];
    }
}

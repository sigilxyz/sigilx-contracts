// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IACPHook.sol";
import "./SigilXCertificateRegistry.sol";
import "./SimpleReputationRegistry.sol";

/// @title SigilXHook
/// @notice ERC-8183 hook for the SigilX formal verification agent.
///
///         Hook routing:
///           beforeAction(submit)  -> validate certHash non-zero, stage metadata
///           afterAction(submit)   -> persist certificate to registry
///           afterAction(complete) -> write ERC-8004 reputation + emit attestation
contract SigilXHook is IACPHook, Ownable, ReentrancyGuard {

    struct PendingCert {
        bytes32 certHash;
        bytes32 theoremHash;
        bool    verdict;
    }

    bytes4 public constant SUBMIT_SELECTOR =
        bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR =
        bytes4(keccak256("complete(uint256,bytes32,bytes)"));

    address public acpContract;
    SigilXCertificateRegistry public registry;
    address public reputationRegistry;

    mapping(uint256 => PendingCert) public pendingCerts;

    event SigilXAttestation(
        uint256 indexed jobId,
        bytes32 indexed certHash,
        bytes32 theoremHash,
        bool    verdict,
        uint256 timestamp
    );

    event ACPContractUpdated(address indexed oldACP, address indexed newACP);

    error OnlyACPContract();
    error ZeroCertHash();
    error NoPendingCert(uint256 jobId);

    modifier onlyACP() {
        if (msg.sender != acpContract) revert OnlyACPContract();
        _;
    }

    constructor(
        address _acpContract,
        address _registry,
        address _reputationRegistry,
        address _owner
    ) Ownable(_owner) {
        acpContract        = _acpContract;
        registry           = SigilXCertificateRegistry(_registry);
        reputationRegistry = _reputationRegistry;
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            if (deliverable == bytes32(0)) revert ZeroCertHash();

            bytes32 theoremHash;
            bool verdict = true;
            if (optParams.length >= 64) {
                (theoremHash, verdict) = abi.decode(optParams, (bytes32, bool));
            } else if (optParams.length >= 32) {
                theoremHash = abi.decode(optParams, (bytes32));
            }

            pendingCerts[jobId] = PendingCert(deliverable, theoremHash, verdict);
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            PendingCert memory pc = pendingCerts[jobId];
            if (pc.certHash == bytes32(0)) revert NoPendingCert(jobId);
            delete pendingCerts[jobId];
            registry.registerCertificate(jobId, pc.certHash, pc.theoremHash, pc.verdict);
        } else if (selector == COMPLETE_SELECTOR) {
            bytes32 certHash = registry.certHashForJob(jobId);
            ISigilXCertificateRegistry.CertMetadata memory meta = registry.getCertMetadata(certHash);

            if (reputationRegistry != address(0)) {
                try SimpleReputationRegistry(reputationRegistry).giveFeedback(
                    jobId,       // agentId
                    int128(100), // value (positive)
                    2,           // valueDecimals
                    "sigilx:verified",   // tag1
                    "formal-proof",      // tag2
                    "",                  // endpoint (unused)
                    string(abi.encodePacked("cert:", certHash)), // feedbackURI
                    certHash             // feedbackHash
                ) {} catch {
                    // Best-effort: don't block completion on reputation failure
                }
            }

            emit SigilXAttestation(jobId, certHash, meta.theoremHash, meta.verdict, block.timestamp);
        }
    }

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

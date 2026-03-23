// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IACPHook.sol";
import "./ISigilXCertificateRegistry.sol";
import "./SimpleReputationRegistryV1.sol";

contract SigilXHookV1 is IACPHook, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    struct PendingCert { bytes32 certHash; bytes32 theoremHash; bool verdict; }

    bytes4 public constant SUBMIT_SELECTOR = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SELECTOR = bytes4(keccak256("complete(uint256,bytes32,bytes)"));

    address public acpContract;
    ISigilXCertificateRegistry public registry;
    address public reputationRegistry;
    mapping(uint256 => PendingCert) public pendingCerts;

    event SigilXAttestation(uint256 indexed jobId, bytes32 indexed certHash, bytes32 theoremHash, bool verdict, uint256 timestamp);
    event ACPContractUpdated(address indexed oldACP, address indexed newACP);
    error OnlyACPContract();
    error ZeroCertHash();
    error NoPendingCert(uint256 jobId);

    modifier onlyACP() { if (msg.sender != acpContract) revert OnlyACPContract(); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _acpContract, address _registry, address _reputationRegistry, address _owner) public initializer {
        __Ownable_init(_owner);
        acpContract = _acpContract;
        registry = ISigilXCertificateRegistry(_registry);
        reputationRegistry = _reputationRegistry;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
            if (deliverable == bytes32(0)) revert ZeroCertHash();
            bytes32 theoremHash; bool verdict = true;
            if (optParams.length >= 64) { (theoremHash, verdict) = abi.decode(optParams, (bytes32, bool)); }
            else if (optParams.length >= 32) { theoremHash = abi.decode(optParams, (bytes32)); }
            pendingCerts[jobId] = PendingCert(deliverable, theoremHash, verdict);
        }
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override onlyACP nonReentrant {
        if (selector == SUBMIT_SELECTOR) {
            PendingCert memory pc = pendingCerts[jobId];
            if (pc.certHash == bytes32(0)) revert NoPendingCert(jobId);
            delete pendingCerts[jobId];
            ISigilXCertificateRegistry(address(registry)).registerCertificate(jobId, pc.certHash, pc.theoremHash, pc.verdict);
        } else if (selector == COMPLETE_SELECTOR) {
            bytes32 certHash = registry.certHashForJob(jobId);
            ISigilXCertificateRegistry.CertMetadata memory meta = registry.getCertMetadata(certHash);
            if (reputationRegistry != address(0)) {
                try SimpleReputationRegistryV1(reputationRegistry).giveFeedback(jobId, int128(100), 2, "sigilx:verified", "formal-proof", "", string(abi.encodePacked("cert:", certHash)), certHash) {} catch {}
            }
            emit SigilXAttestation(jobId, certHash, meta.theoremHash, meta.verdict, block.timestamp);
        }
    }

    function setACPContract(address _acp) external onlyOwner { emit ACPContractUpdated(acpContract, _acp); acpContract = _acp; }
    function setRegistry(address _registry) external onlyOwner { registry = ISigilXCertificateRegistry(_registry); }
    function setReputationRegistry(address _rep) external onlyOwner { reputationRegistry = _rep; }
}

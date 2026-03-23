// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./ISigilXCertificateRegistry.sol";

contract SigilXCertificateRegistryV1 is ISigilXCertificateRegistry, UUPSUpgradeable, OwnableUpgradeable {
    address public authorisedRegistrant;
    mapping(bytes32 => CertMetadata) private _metadata;
    mapping(bytes32 => bool) private _registered;
    mapping(uint256 => bytes32) private _jobToCert;

    event CertificateRegistered(uint256 indexed jobId, bytes32 indexed certHash, bytes32 theoremHash, bool verdict, address registrant);
    event AuthorisedRegistrantUpdated(address indexed oldRegistrant, address indexed newRegistrant);
    error NotAuthorisedRegistrant();
    error CertHashAlreadyRegistered(bytes32 certHash);
    error JobAlreadyHasCertificate(uint256 jobId);
    error ZeroCertHash();

    modifier onlyRegistrant() { if (msg.sender != authorisedRegistrant) revert NotAuthorisedRegistrant(); _; }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _authorisedRegistrant, address _owner) public initializer {
        __Ownable_init(_owner);
        authorisedRegistrant = _authorisedRegistrant;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setAuthorisedRegistrant(address registrant) external onlyOwner {
        emit AuthorisedRegistrantUpdated(authorisedRegistrant, registrant);
        authorisedRegistrant = registrant;
    }

    function registerCertificate(uint256 jobId, bytes32 certHash, bytes32 theoremHash, bool verdict) external onlyRegistrant {
        if (certHash == bytes32(0)) revert ZeroCertHash();
        if (_registered[certHash]) revert CertHashAlreadyRegistered(certHash);
        if (_jobToCert[jobId] != bytes32(0)) revert JobAlreadyHasCertificate(jobId);
        _registered[certHash] = true;
        _jobToCert[jobId] = certHash;
        _metadata[certHash] = CertMetadata({ theoremHash: theoremHash, verdict: verdict, timestamp: block.timestamp, registrant: msg.sender, jobId: jobId });
        emit CertificateRegistered(jobId, certHash, theoremHash, verdict, msg.sender);
    }

    function isVerified(bytes32 certHash) external view returns (bool) { return _registered[certHash] && _metadata[certHash].verdict; }
    function getCertMetadata(bytes32 certHash) external view returns (CertMetadata memory) { return _metadata[certHash]; }
    function certHashForJob(uint256 jobId) external view returns (bytes32) { return _jobToCert[jobId]; }
    function exists(bytes32 certHash) external view returns (bool) { return _registered[certHash]; }

    // Storage Gap (H-2 audit fix: reserve slots for future upgrades)
    uint256[50] private __gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ISigilXCertificateRegistry.sol";

/// @title SigilXCertificateRegistry
/// @notice Immutable on-chain ledger for Lean 4 verification certificates.
///         Write-once: a certHash or jobId can only be mapped once.
///         Only the authorised registrant (SigilXHook) may write.
contract SigilXCertificateRegistry is ISigilXCertificateRegistry, Ownable {

    address public authorisedRegistrant;

    mapping(bytes32 => CertMetadata) private _metadata;
    mapping(bytes32 => bool) private _registered;
    mapping(uint256 => bytes32) private _jobToCert;

    event CertificateRegistered(
        uint256 indexed jobId,
        bytes32 indexed certHash,
        bytes32 theoremHash,
        bool    verdict,
        address registrant
    );

    event AuthorisedRegistrantUpdated(address indexed oldRegistrant, address indexed newRegistrant);

    error NotAuthorisedRegistrant();
    error CertHashAlreadyRegistered(bytes32 certHash);
    error JobAlreadyHasCertificate(uint256 jobId);
    error ZeroCertHash();

    modifier onlyRegistrant() {
        if (msg.sender != authorisedRegistrant) revert NotAuthorisedRegistrant();
        _;
    }

    constructor(address _authorisedRegistrant, address _owner) Ownable(_owner) {
        authorisedRegistrant = _authorisedRegistrant;
    }

    function setAuthorisedRegistrant(address registrant) external onlyOwner {
        emit AuthorisedRegistrantUpdated(authorisedRegistrant, registrant);
        authorisedRegistrant = registrant;
    }

    /// @notice Record a certificate. Immutable once written. CEI pattern.
    function registerCertificate(
        uint256 jobId,
        bytes32 certHash,
        bytes32 theoremHash,
        bool    verdict
    ) external onlyRegistrant {
        if (certHash == bytes32(0)) revert ZeroCertHash();
        if (_registered[certHash]) revert CertHashAlreadyRegistered(certHash);
        if (_jobToCert[jobId] != bytes32(0)) revert JobAlreadyHasCertificate(jobId);

        _registered[certHash] = true;
        _jobToCert[jobId]     = certHash;
        _metadata[certHash]   = CertMetadata({
            theoremHash: theoremHash,
            verdict:     verdict,
            timestamp:   block.timestamp,
            registrant:  msg.sender,
            jobId:       jobId
        });

        emit CertificateRegistered(jobId, certHash, theoremHash, verdict, msg.sender);
    }

    function isVerified(bytes32 certHash) external view returns (bool) {
        return _registered[certHash] && _metadata[certHash].verdict;
    }

    function getCertMetadata(bytes32 certHash) external view returns (CertMetadata memory) {
        return _metadata[certHash];
    }

    function certHashForJob(uint256 jobId) external view returns (bytes32) {
        return _jobToCert[jobId];
    }

    function exists(bytes32 certHash) external view returns (bool) {
        return _registered[certHash];
    }
}

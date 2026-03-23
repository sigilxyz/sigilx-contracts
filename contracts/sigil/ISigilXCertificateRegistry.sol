// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISigilXCertificateRegistry
/// @notice Read interface for composable on-chain verification queries.
interface ISigilXCertificateRegistry {
    struct CertMetadata {
        bytes32 theoremHash;
        bool    verdict;
        uint256 timestamp;
        address registrant;
        uint256 jobId;
    }

    function registerCertificate(uint256 jobId, bytes32 certHash, bytes32 theoremHash, bool verdict) external;
    function isVerified(bytes32 certHash) external view returns (bool);
    function getCertMetadata(bytes32 certHash) external view returns (CertMetadata memory);
    function certHashForJob(uint256 jobId) external view returns (bytes32);
    function exists(bytes32 certHash) external view returns (bool);
}

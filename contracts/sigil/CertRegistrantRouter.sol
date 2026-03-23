// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./ISigilXCertificateRegistry.sol";

/// @title CertRegistrantRouter
/// @notice Routes certificate registration calls from multiple authorized hooks
///         to the single-registrant CertificateRegistry.
///
///         The CertificateRegistry only accepts calls from one `authorisedRegistrant`.
///         This router sits in that slot and allows multiple hooks (SigilXHook,
///         QuorumHook, etc.) to register certificates through it.
///
///         TESTNET ONLY: For mainnet, upgrade CertificateRegistry to support
///         a mapping of authorized registrants directly.
contract CertRegistrantRouter is Ownable {

    ISigilXCertificateRegistry public registry;

    mapping(address => bool) public authorizedCallers;

    event CallerAuthorized(address indexed caller);
    event CallerRevoked(address indexed caller);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);

    error NotAuthorizedCaller();
    error ZeroAddress();

    modifier onlyAuthorized() {
        if (!authorizedCallers[msg.sender]) revert NotAuthorizedCaller();
        _;
    }

    /// @param _registry The SigilXCertificateRegistry address
    /// @param _owner    Contract owner (Timelock in prod)
    constructor(address _registry, address _owner) Ownable(_owner) {
        if (_registry == address(0)) revert ZeroAddress();
        registry = ISigilXCertificateRegistry(_registry);
    }

    /// @notice Forward a certificate registration to the registry.
    ///         Only callable by authorized hooks.
    function registerCertificate(
        uint256 jobId,
        bytes32 certHash,
        bytes32 theoremHash,
        bool    verdict
    ) external onlyAuthorized {
        registry.registerCertificate(jobId, certHash, theoremHash, verdict);
    }

    /// @notice Add an authorized caller (hook).
    function authorizeCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = true;
        emit CallerAuthorized(caller);
    }

    /// @notice Remove an authorized caller.
    function revokeCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit CallerRevoked(caller);
    }

    /// @notice Update the registry address (in case of migration).
    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        emit RegistryUpdated(address(registry), _registry);
        registry = ISigilXCertificateRegistry(_registry);
    }
}

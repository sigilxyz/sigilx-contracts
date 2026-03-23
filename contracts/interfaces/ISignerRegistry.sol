/*
                         ██████████████████████
                     ████████████████████████████████
                   ████████████████████████████████████
                 ████████████████████████████████████████
                ██████████████████████████████████████████
                ██████████  ██████████████████  ██████████
                ██████████  ██████████████████  ██████████
                ██████████  ████████            ██████████
                ██████████  ██████████████      ██████████
                ██████████  ██████████████      ██████████
                ██████████  ████████            ██████████
                ██████████  ██████████          ██████████
                ██████████                      ██████████
                 ████████████████████████████████████████
                  ██████████████████████████████████████
                    ██████████████████████████████████
                      ██████████████████████████████
                         ████████████████████████
                            ██████████████████
                               ████████████
                                  ██████
                                    ██

                                 PLEDGE
                              usepledge.xyz
*/
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISignerRegistry
 * @notice Interface for the Agent Pulse PoD Signer Registry.
 * @dev Manages signer registration, key rotation, revocation, and unstaking.
 */
interface ISignerRegistry {
    // ============ Types ============

    /**
     * @notice Status of a registered signer.
     */
    enum SignerStatus {
        ACTIVE,
        SLASHED,
        UNSTAKING
    }

    /**
     * @notice Status of a signer key.
     */
    enum KeyStatus {
        PENDING,
        ACTIVE,
        ROTATED,
        REVOKED,
        RETIRED
    }

    /**
     * @notice Signer registration record.
     * @param signerId Protocol-level signer identifier.
     * @param owner Owner address controlling key management and unstake.
     * @param stakeAmount ETH stake posted at registration.
     * @param status Current signer status.
     * @param registeredAt Timestamp when signer was registered.
     * @param slashedAt Timestamp when signer was slashed (0 if never).
     * @param unstakeRequestedAt Timestamp when unstake was requested (0 if never).
     */
    struct Signer {
        bytes32 signerId;
        address owner;
        uint256 stakeAmount;
        SignerStatus status;
        uint256 registeredAt;
        uint256 slashedAt;
        uint256 unstakeRequestedAt;
    }

    /**
     * @notice Key record associated with a signer.
     * @param kid Key identifier.
     * @param signerId The signer this key belongs to.
     * @param publicKey Ed25519 public key (32 bytes).
     * @param status Current key status.
     * @param activatedAt Timestamp when the key became active.
     * @param revokedAt Timestamp when the key was revoked (0 if never).
     * @param gracePeriodEnds Timestamp when rotation grace period ends (0 if not rotated).
     */
    struct SignerKey {
        bytes32 kid;
        bytes32 signerId;
        bytes32 publicKey;
        KeyStatus status;
        uint256 activatedAt;
        uint256 revokedAt;
        uint256 gracePeriodEnds;
    }

    // ============ Events ============

    /**
     * @notice Emitted when a signer is registered.
     * @param signerId The signer identifier.
     * @param kid The initial key id.
     * @param publicKey The initial Ed25519 public key.
     * @param stakeAmount Amount of ETH staked.
     */
    event SignerRegistered(bytes32 indexed signerId, bytes32 indexed kid, bytes32 publicKey, uint256 stakeAmount);

    /**
     * @notice Emitted when a key is rotated.
     * @param signerId The signer identifier.
     * @param oldKid The rotated-out key id.
     * @param newKid The newly activated key id.
     * @param gracePeriodEnds Timestamp when the old key's grace period ends.
     */
    event KeyRotated(bytes32 indexed signerId, bytes32 indexed oldKid, bytes32 indexed newKid, uint256 gracePeriodEnds);

    /**
     * @notice Emitted when a key is revoked.
     * @param signerId The signer identifier.
     * @param kid The key id that was revoked.
     * @param reason Human-readable reason.
     */
    event KeyRevoked(bytes32 indexed signerId, bytes32 indexed kid, string reason);

    /**
     * @notice Emitted when an unstake request is created.
     * @param signerId The signer identifier.
     * @param cooldownEnds Timestamp when the unstake cooldown ends.
     */
    event UnstakeRequested(bytes32 indexed signerId, uint256 cooldownEnds);

    // ============ Core Functions ============

    /**
     * @notice Register a new signer with an initial active key.
     * @dev Requires `msg.value >= MINIMUM_STAKE`.
     * @param signerId Protocol-level signer identifier.
     * @param publicKey Initial Ed25519 public key.
     * @param kid Key identifier for the provided public key.
     */
    function registerSigner(bytes32 signerId, bytes32 publicKey, bytes32 kid) external payable;

    /**
     * @notice Rotate the active key for a signer.
     * @dev Callable only by the signer owner and only while the signer is ACTIVE.
     *      The previous active key is marked ROTATED and remains valid for a grace period.
     * @param signerId Signer identifier.
     * @param newPublicKey New Ed25519 public key.
     * @param newKid New key identifier.
     */
    function rotateKey(bytes32 signerId, bytes32 newPublicKey, bytes32 newKid) external;

    /**
     * @notice Revoke a key.
     * @dev Callable by the signer owner or an account with SLASHER_ROLE.
     * @param signerId Signer identifier.
     * @param kid Key id to revoke.
     * @param reason Human-readable reason.
     */
    function revokeKey(bytes32 signerId, bytes32 kid, string calldata reason) external;

    /**
     * @notice Begin the unstake process.
     * @dev Callable only by the signer owner.
     *      Requires that the signer has no currently-active keys.
     * @param signerId Signer identifier.
     */
    function requestUnstake(bytes32 signerId) external;

    /**
     * @notice Complete the unstake process after the cooldown has elapsed.
     * @dev Returns the stake to the signer owner and removes the signer.
     * @param signerId Signer identifier.
     */
    function completeUnstake(bytes32 signerId) external;

    // ============ Queries ============

    /**
     * @notice Returns whether a signer is currently active.
     * @param signerId Signer identifier.
     */
    function isSignerActive(bytes32 signerId) external view returns (bool);

    /**
     * @notice Returns whether a key is currently active.
     * @param kid Key identifier.
     */
    function isKeyActive(bytes32 kid) external view returns (bool);

    /**
     * @notice Returns the public key for a given key id.
     * @param kid Key identifier.
     */
    function getPublicKey(bytes32 kid) external view returns (bytes32);

    /**
     * @notice Historical query: returns whether a key was active at a given timestamp.
     * @param kid Key identifier.
     * @param timestamp Unix timestamp to query.
     */
    function wasKeyActiveAt(bytes32 kid, uint256 timestamp) external view returns (bool);
}

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
 * @title IPodAnchor
 * @notice Interface for anchoring batches of Proof-of-Data (PoD) receipts via Merkle roots.
 * @dev The Agent Pulse indexer periodically computes a Merkle tree of newly issued PoDs and
 *      anchors its root on-chain.
 */
interface IPodAnchor {
    /**
     * @notice Emitted when a new batch Merkle root is anchored.
     * @param merkleRoot The Merkle root of the batch.
     * @param podCount The number of PoDs included in the batch.
     * @param batchTimestamp The timestamp associated with the batch (provided by the indexer).
     * @param blockNumber The L1/L2 block number in which the batch was anchored.
     */
    event BatchAnchored(
        bytes32 indexed merkleRoot,
        uint256 podCount,
        uint256 batchTimestamp,
        uint256 blockNumber
    );

    /**
     * @notice Anchor a Merkle root representing a batch of PoDs.
     * @dev MUST be restricted to callers with the INDEXER_ROLE.
     * @param merkleRoot The Merkle root of the batch.
     * @param podCount The number of PoDs in the batch.
     * @param batchTimestamp The timestamp associated with the batch.
     */
    function anchorBatch(bytes32 merkleRoot, uint256 podCount, uint256 batchTimestamp) external;

    /**
     * @notice Verify that a leaf is included in a Merkle tree with the given root.
     * @dev Uses OpenZeppelin's MerkleProof verification (sorted-pair hashing).
     *      This function is pure and does not require the root to be previously anchored.
     * @param merkleRoot The Merkle root.
     * @param leaf The leaf to prove.
     * @param proof The Merkle proof (sibling hashes from leaf to root).
     * @return True if the proof is valid.
     */
    function verifyInclusion(bytes32 merkleRoot, bytes32 leaf, bytes32[] calldata proof) external pure returns (bool);

    /**
     * @notice Return batch data for a given Merkle root.
     * @param merkleRoot The batch Merkle root.
     * @return podCount The number of PoDs anchored in this batch.
     * @return batchTimestamp The timestamp associated with the batch.
     * @return blockNumber The block in which the batch was anchored.
     */
    function getBatch(bytes32 merkleRoot)
        external
        view
        returns (uint256 podCount, uint256 batchTimestamp, uint256 blockNumber);

    /**
     * @notice Return the most recently anchored batch.
     * @return merkleRoot The latest batch Merkle root.
     * @return podCount The number of PoDs anchored in the latest batch.
     * @return batchTimestamp The timestamp associated with the latest batch.
     * @return blockNumber The block in which the latest batch was anchored.
     */
    function getLatestBatch()
        external
        view
        returns (bytes32 merkleRoot, uint256 podCount, uint256 batchTimestamp, uint256 blockNumber);

    /**
     * @notice Returns true if a batch with the given root has been anchored.
     * @param merkleRoot The batch Merkle root.
     */
    function batchExists(bytes32 merkleRoot) external view returns (bool);
}

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
pragma solidity ^0.8.20;

/**
 * @title IAgentVerifiable
 * @notice Interface for DeFi protocols to verify agent reliability
 * @dev Used by external contracts to gate access based on agent reliability scores
 */
interface IAgentVerifiable {
    /**
     * @notice Reverts if agent is dead or below minimum score threshold
     * @param agent The agent address to verify
     * @param minScore Minimum reliability score required (0-100)
     */
    function requireReliability(address agent, uint256 minScore) external view;

    /**
     * @notice Returns true if agent is in "Good Standing" (Alive + Streak > 7)
     * @param agent The agent address to check
     * @return True if agent is verified
     */
    function isVerifiedAgent(address agent) external view returns (bool);
}

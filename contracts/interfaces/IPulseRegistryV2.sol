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
 * @title IPulseRegistryV2
 * @notice Interface for PulseRegistryV2 with staking and reliability scoring
 */
interface IPulseRegistryV2 {
    // --- Core V1 Parity ---
    function pulse(uint256 amount) external;
    function isAlive(address agent) external view returns (bool);
    function getAgentStatus(address agent) external view returns (
        bool alive,
        uint256 lastPulseAt,
        uint256 streak,
        uint256 totalBurned
    );

    // --- V2 Extensions ---
    
    /**
     * @notice Stakes PULSE to increase Agent Tier.
     * @param amount Amount to lock.
     */
    function stake(uint256 amount) external;
    
    /**
     * @notice Unstakes PULSE after lockup period.
     * @dev NOT gated by pause — users can always withdraw their own funds.
     */
    function unstake(uint256 amount) external;
    
    /**
     * @notice Returns the calculated 0-100 reliability score.
     * @dev Pure on-chain calculation, ~5k gas.
     * @param agent The agent address.
     * @return score The calculated score (0-100).
     */
    function getReliabilityScore(address agent) external view returns (uint256 score);
    
    /**
     * @notice Returns current Tier for API gating.
     * @return 0=Basic, 1=Pro, 2=Partner
     */
    function getAgentTier(address agent) external view returns (uint8);
    
    /**
     * @notice Returns staked amount for an agent
     * @param agent The agent address
     * @return Amount of PULSE staked
     */
    function stakedAmount(address agent) external view returns (uint256);
    
    /**
     * @notice Returns stake unlock time for an agent
     * @param agent The agent address
     * @return Timestamp when stake can be unlocked
     */
    function stakeUnlockTime(address agent) external view returns (uint256);
    
    // --- Events ---
    event ReliabilityUpdate(address indexed agent, uint256 newScore, uint8 newTier);
    event Staked(address indexed agent, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed agent, uint256 amount);
    event PulseV2(address indexed agent, uint256 amount, uint256 timestamp, uint256 streak, uint256 totalBurned);
}

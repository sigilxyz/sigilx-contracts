// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";

/// @title SigilXGovernor
/// @notice Phase 2 governance contract for SigilX — token-weighted voting that
///         replaces the multisig as the Timelock's proposer.
///
///         Governance transition flow:
///           1. Deploy SigilXGovernor with the existing SigilXTimelock
///           2. Grant PROPOSER_ROLE to Governor on the Timelock
///           3. Revoke PROPOSER_ROLE from multisig (only after Governor is proven working)
///           4. Token holders propose → vote → execute through Timelock → protocol changes
///
///         Parameters:
///           - Voting delay:      1 day   (time before voting starts)
///           - Voting period:     1 week  (time to cast votes)
///           - Proposal threshold: 100K tokens (minimum to submit a proposal)
///           - Quorum:            1M tokens   (minimum participation for validity)
contract SigilXGovernor is
    Governor,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorTimelockControl,
    GovernorSettings
{
    /// @dev Fixed quorum: 1 million tokens (with 18 decimals)
    uint256 private constant QUORUM_TOKENS = 1_000_000e18;

    /// @notice Guardian address that can veto proposals during timelock delay.
    ///         Initially the multisig; can be renounced by setting to address(0).
    address public guardian;

    /// @notice Emitted when a proposal is vetoed by the guardian.
    event ProposalVetoed(uint256 proposalId);

    /// @notice Emitted when the guardian address changes.
    event GuardianUpdated(address oldGuardian, address newGuardian);

    error OnlyGuardian();
    error GuardianZeroAddress();

    constructor(
        IVotes _token,
        TimelockController _timelock,
        address _guardian
    )
        Governor("SigilX Governor")
        GovernorVotes(_token)
        GovernorTimelockControl(_timelock)
        GovernorSettings(
            1 days,      // votingDelay: 1 day before voting starts
            1 weeks,     // votingPeriod: 1 week to vote
            100_000e18   // proposalThreshold: 100K tokens to propose
        )
    {
        if (_guardian == address(0)) revert GuardianZeroAddress();
        guardian = _guardian;
    }

    /// @notice Guardian veto — cancel a proposal during any cancellable state.
    ///         The guardian (initially multisig) can block malicious governance
    ///         capture at low token prices. Renounce by calling setGuardian(address(0))
    ///         once governance is sufficiently decentralized.
    /// @param targets     Proposal targets
    /// @param values      Proposal values
    /// @param calldatas   Proposal calldatas
    /// @param descriptionHash keccak256 of proposal description
    function veto(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) external returns (uint256) {
        if (msg.sender != guardian) revert OnlyGuardian();
        uint256 proposalId = _cancel(targets, values, calldatas, descriptionHash);
        emit ProposalVetoed(proposalId);
        return proposalId;
    }

    /// @notice Update the guardian address. Only callable by current guardian.
    ///         Set to address(0) to permanently renounce veto power.
    function setGuardian(address _newGuardian) external {
        if (msg.sender != guardian) revert OnlyGuardian();
        emit GuardianUpdated(guardian, _newGuardian);
        guardian = _newGuardian;
    }

    /// @notice Fixed quorum of 1M tokens required for a proposal to pass.
    function quorum(uint256 /* timepoint */) public pure override returns (uint256) {
        return QUORUM_TOKENS;
    }

    // ═══════════════════════════════════════════════════
    //  Required overrides for Solidity multiple inheritance
    // ═══════════════════════════════════════════════════

    function votingDelay()
        public view override(Governor, GovernorSettings) returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public view override(Governor, GovernorSettings) returns (uint256)
    {
        return super.votingPeriod();
    }

    function proposalThreshold()
        public view override(Governor, GovernorSettings) returns (uint256)
    {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal view override(Governor, GovernorTimelockControl) returns (address)
    {
        return super._executor();
    }
}

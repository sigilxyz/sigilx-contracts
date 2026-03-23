// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title SigilXTimelock
/// @notice Governance timelock for all SigilX on-chain contracts.
///         Wraps OZ TimelockController with a simpler constructor.
///
///         Roles granted at deploy:
///           - multisig  → PROPOSER_ROLE + CANCELLER_ROLE + EXECUTOR_ROLE
///           - tempAdmin → DEFAULT_ADMIN_ROLE (for testnet iteration;
///                         renounce before mainnet)
///           - self      → DEFAULT_ADMIN_ROLE (standard OZ self-admin)
contract SigilXTimelock is TimelockController {
    /// @param _minDelay  Seconds before a queued tx becomes executable
    ///                   (300 for testnet, 172800 for mainnet)
    /// @param _multisig  Address that can propose, cancel, and execute
    /// @param _tempAdmin Address granted DEFAULT_ADMIN_ROLE for testnet ops
    constructor(
        uint256 _minDelay,
        address _multisig,
        address _tempAdmin
    )
        TimelockController(
            _minDelay,
            _toArray(_multisig), // proposers (also gets CANCELLER)
            _toArray(_multisig), // executors
            _tempAdmin           // admin
        )
    {}

    /// @dev Helper to create a single-element address array for the parent ctor.
    function _toArray(address a) private pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}

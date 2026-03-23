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

/// @title IACPHook - ERC-8183 Hook Interface
/// @notice Standard hook interface for extending ERC-8183 job lifecycle
/// @dev Hooks receive callbacks before and after each hookable core function.
///      The selector identifies which function is being called.
///      The data contains function-specific parameters encoded as bytes.
interface IACPHook {
    /// @notice Called before a core function executes
    /// @param jobId The job being acted on
    /// @param selector The function selector of the core function
    /// @param data Encoded parameters specific to the function
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @notice Called after a core function completes (including state changes)
    /// @param jobId The job being acted on
    /// @param selector The function selector of the core function
    /// @param data Encoded parameters specific to the function
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}

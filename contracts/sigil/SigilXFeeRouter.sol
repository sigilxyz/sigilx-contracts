// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SigilXFeeRouter
/// @notice Collects verification fees and routes to TreasuryManager.
///         Can be set as the x402/MPP payment recipient address.
contract SigilXFeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public treasuryManager;

    // Track fees by type
    uint256 public totalFeesRouted;

    event FeesRouted(uint256 amount, address indexed from);
    event TreasuryManagerUpdated(address oldManager, address newManager);

    error ZeroAddress();
    error NoFeesToRoute();

    constructor(
        address _usdc,
        address _treasuryManager,
        address _owner
    ) Ownable(_owner) {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasuryManager == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        treasuryManager = _treasuryManager;
    }

    /// @notice Forward all accumulated USDC to the TreasuryManager.
    /// @dev Anyone can call -- permissionless routing.
    function routeFees() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert NoFeesToRoute();

        usdc.safeTransfer(treasuryManager, balance);
        totalFeesRouted += balance;

        emit FeesRouted(balance, msg.sender);
    }

    /// @notice Receive USDC and auto-forward if above threshold.
    /// @dev Can be called by x402 settlement or manual transfer.
    function depositAndRoute(uint256 amount) external nonReentrant {
        usdc.safeTransferFrom(msg.sender, treasuryManager, amount);
        totalFeesRouted += amount;
        emit FeesRouted(amount, msg.sender);
    }

    /// @notice Update the treasury manager address.
    /// @param _manager New treasury manager address.
    function setTreasuryManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert ZeroAddress();
        emit TreasuryManagerUpdated(treasuryManager, _manager);
        treasuryManager = _manager;
    }
}

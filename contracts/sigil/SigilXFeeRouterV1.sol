// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SigilXFeeRouterV1 is UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public usdc;
    address public treasuryManager;
    uint256 public totalFeesRouted;
    event FeesRouted(uint256 amount, address indexed from);
    event TreasuryManagerUpdated(address oldManager, address newManager);
    error ZeroAddress();
    error NoFeesToRoute();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address _usdc, address _treasuryManager, address _owner) public initializer {
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasuryManager == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        usdc = IERC20(_usdc);
        treasuryManager = _treasuryManager;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function routeFees() external nonReentrant {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance == 0) revert NoFeesToRoute();
        usdc.safeTransfer(treasuryManager, balance);
        totalFeesRouted += balance;
        emit FeesRouted(balance, msg.sender);
    }

    function depositAndRoute(uint256 amount) external nonReentrant {
        usdc.safeTransferFrom(msg.sender, treasuryManager, amount);
        totalFeesRouted += amount;
        emit FeesRouted(amount, msg.sender);
    }

    function setTreasuryManager(address _manager) external onlyOwner {
        if (_manager == address(0)) revert ZeroAddress();
        emit TreasuryManagerUpdated(treasuryManager, _manager);
        treasuryManager = _manager;
    }
}

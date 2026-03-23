// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title SigilXToken
/// @notice Production SIGILX ERC20 with ERC20Votes for governance, ERC20Permit
///         for gasless approvals, and capped supply at 1B tokens.
contract SigilXToken is ERC20, ERC20Permit, ERC20Votes, Ownable {
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18; // 1B SIGILX

    constructor(address initialOwner)
        ERC20("SigilX", "SIGILX")
        ERC20Permit("SigilX")
        Ownable(initialOwner)
    {
        // Initial mint for liquidity seeding + treasury
        _mint(initialOwner, 100_000_000e18); // 100M to deployer
    }

    /// @notice Owner-gated mint with hard supply cap.
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _mint(to, amount);
    }

    // ── Required overrides for ERC20 + ERC20Votes ──────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}

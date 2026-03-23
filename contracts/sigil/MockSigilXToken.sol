// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

/// @title MockSigilXToken
/// @notice ERC20Votes token for testnet governance testing.
///         On mainnet, the real SIGILX token is deployed via Pegasus/Clanker
///         and this mock is NOT used.
///
///         Features:
///           - ERC20Votes for Governor compatibility (delegation + checkpoints)
///           - ERC20Permit for gasless approvals
///           - Open mint for testnet fauceting
///           - 18 decimals (standard)
contract MockSigilXToken is ERC20, ERC20Permit, ERC20Votes {

    /// @param _initialHolder Address to receive the initial supply
    /// @param _initialSupply Total initial supply (with 18 decimals)
    constructor(
        address _initialHolder,
        uint256 _initialSupply
    )
        ERC20("SigilX Token", "SIGILX")
        ERC20Permit("SigilX Token")
    {
        _mint(_initialHolder, _initialSupply);
    }

    /// @notice Open mint for testnet fauceting. No access control.
    /// @dev Remove or gate this on mainnet.
    function mint(address to, uint256 amount) external {
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

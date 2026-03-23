// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title ReentrancyGuardUpgradeable
/// @notice Proxy-safe reentrancy guard for UUPS/ERC1967 upgradeable contracts.
/// @dev    OZ v5 removed the dedicated ReentrancyGuardUpgradeable. The non-upgradeable
///         ReentrancyGuard sets `_status` in its constructor, which runs on the
///         implementation — not the proxy — leaving the proxy's `_status` at 0 (uninitialized).
///         This contract replaces constructor initialization with an `__ReentrancyGuard_init()`
///         call inside the proxy's `initialize()` function, ensuring correct storage.
///         Storage layout: `_status` occupies one slot, followed by a 49-slot gap.
abstract contract ReentrancyGuardUpgradeable is Initializable {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    error ReentrancyGuardReentrantCall();

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _nonReentrantBefore() private {
        if (_status == _ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = _NOT_ENTERED;
    }

    function _reentrancyGuardEntered() internal view returns (bool) {
        return _status == _ENTERED;
    }

    uint256[49] private __gap;
}

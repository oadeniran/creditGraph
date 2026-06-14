// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessController} from "../interfaces/IAccessController.sol";

/// @title ProtocolBase
/// @notice Shared base that wires a contract to the central AccessController for
///         role checks and global pause enforcement.
/// @dev Inherit this in any contract that needs protocol roles. Keeps access
///      logic uniform and in one place.
abstract contract ProtocolBase {
    /// @notice The central access controller.
    IAccessController public immutable access;

    error Unauthorized(bytes32 role, address account);
    error ProtocolPaused();
    error ZeroAddress();

    constructor(address accessController) {
        if (accessController == address(0)) revert ZeroAddress();
        access = IAccessController(accessController);
    }

    /// @dev Reverts unless `msg.sender` holds `role` in the AccessController.
    modifier onlyRole(bytes32 role) {
        if (!access.hasRole(role, msg.sender)) revert Unauthorized(role, msg.sender);
        _;
    }

    /// @dev Reverts when the protocol is globally paused.
    modifier whenNotPaused() {
        if (access.isPaused()) revert ProtocolPaused();
        _;
    }

    /// @dev Helper for internal authorization checks of arbitrary accounts.
    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        return access.hasRole(role, account);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "../libraries/Roles.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";

/// @title AccessController
/// @notice Central registry of protocol roles plus a global pause flag.
/// @dev Every other contract holds a reference to this and gates sensitive
///      functions through it, so roles are managed in exactly one place.
contract AccessController is AccessControl, IAccessController {
    /// @notice Global emergency pause. When true, ProtocolBase-derived contracts
    ///         should block state-changing user actions.
    bool private _paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error AlreadyInState();

    /// @param admin The address granted DEFAULT_ADMIN_ROLE (should be a multisig).
    constructor(address admin) {
        require(admin != address(0), "AccessController: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.PAUSER_ROLE, admin);
        _grantRole(Roles.CONFIG_ROLE, admin);
    }

    /// @inheritdoc IAccessController
    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessController)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @inheritdoc IAccessController
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /// @notice Pause the protocol. Restricted to PAUSER_ROLE.
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        if (_paused) revert AlreadyInState();
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the protocol. Restricted to PAUSER_ROLE.
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        if (!_paused) revert AlreadyInState();
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Convenience batch grant for wiring up the protocol after deploy.
    /// @dev Restricted to DEFAULT_ADMIN_ROLE.
    function grantRoles(bytes32[] calldata roles, address[] calldata accounts)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(roles.length == accounts.length, "AccessController: length mismatch");
        for (uint256 i; i < roles.length; ++i) {
            _grantRole(roles[i], accounts[i]);
        }
    }
}

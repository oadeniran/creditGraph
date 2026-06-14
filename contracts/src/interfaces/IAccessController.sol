// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccessController
/// @notice Minimal interface to the central role registry. Other contracts call
///         `hasRole` to gate functions against protocol-wide roles.
interface IAccessController {
    function hasRole(bytes32 role, address account) external view returns (bool);

    function isPaused() external view returns (bool);
}

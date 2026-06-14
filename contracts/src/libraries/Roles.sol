// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Roles
/// @notice Canonical role identifiers shared across the protocol.
/// @dev DEFAULT_ADMIN_ROLE is 0x00 and lives in OpenZeppelin's AccessControl.
library Roles {
    /// @notice Can pause/unpause all pausable contracts in an emergency.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Held by ScoringOracle; allowed to write into ScoreRegistry.
    bytes32 internal constant SCORE_UPDATER_ROLE = keccak256("SCORE_UPDATER_ROLE");

    /// @notice Held by CreditSlasher; allowed to reduce scores and slash bonds.
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /// @notice Held by LoanManager; allowed to draw/return funds from LendingPool
    ///         and to record repayment/graduation events.
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    /// @notice Held by addresses allowed to mint CreditIdentity tokens
    ///         (the onboarding backend / agent).
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Held by the ScoringOracle finalizer flow; allowed to record claims
    ///         on behalf of users in ZKAttestationVerifier (if backend-relayed).
    bytes32 internal constant CLAIM_RECORDER_ROLE = keccak256("CLAIM_RECORDER_ROLE");

    /// @notice Held by CreditSlasher; allowed to spend the InsuranceFund.
    bytes32 internal constant INSURANCE_SPENDER_ROLE = keccak256("INSURANCE_SPENDER_ROLE");

    /// @notice Held by the cross-chain bridge endpoint that writes mirrored scores.
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Held by governance/multisig for proxy upgrades and param changes.
    bytes32 internal constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DataTypes
/// @notice Shared structs and enums used across the CreditGraph protocol.
/// @dev Centralizing these prevents type drift between contracts that must agree
///      on layouts (e.g. LoanManager <-> CreditSlasher).
library DataTypes {
    // ----------------------------------------------------------------
    // Scoring
    // ----------------------------------------------------------------

    /// @notice A credit score snapshot for an identity.
    /// @param value   Score in the range [300, 1000].
    /// @param timestamp When the score was written.
    /// @param tier    Derived credit tier [1, 5].
    /// @param reasonHash IPFS CID (as bytes32) pointing to a human-readable breakdown.
    struct Score {
        uint16 value;
        uint64 timestamp;
        uint8 tier;
        bytes32 reasonHash;
    }

    // ----------------------------------------------------------------
    // Lending
    // ----------------------------------------------------------------

    enum LoanState {
        None, // 0 - default value, loan does not exist
        Active, // 1
        Repaid, // 2
        Late, // 3
        Defaulted // 4
    }

    /// @notice A single loan position.
    /// @param tokenId      Borrower's CreditIdentity token id.
    /// @param principal    Original borrowed amount (USDC, 6 decimals).
    /// @param outstanding  Remaining principal owed (interest computed separately).
    /// @param interestPaid Cumulative interest paid to date.
    /// @param originatedAt Origination timestamp.
    /// @param dueAt        Repayment deadline.
    /// @param lastAccrual  Last time interest was accrued for this loan.
    /// @param aprBps       Fixed APR for the life of this loan, in basis points.
    /// @param state        Current loan lifecycle state.
    struct Loan {
        uint256 tokenId;
        uint256 principal;
        uint256 outstanding;
        uint256 interestPaid;
        uint64 originatedAt;
        uint64 dueAt;
        uint64 lastAccrual;
        uint16 aprBps;
        LoanState state;
    }

    // ----------------------------------------------------------------
    // Social Attestation
    // ----------------------------------------------------------------

    /// @notice An on-chain vouch from one identity for another, backed by a bond.
    /// @param attesterTokenId Identity making the attestation.
    /// @param subjectTokenId  Identity being vouched for.
    /// @param bondAmount      USDC staked behind the vouch.
    /// @param createdAt       Creation timestamp.
    /// @param expiresAt       Expiry timestamp; weight decays as this approaches.
    /// @param active          Whether the attestation is currently live.
    /// @param relationshipType Categorical tag (e.g. keccak256("AJO")).
    struct Attestation {
        uint256 attesterTokenId;
        uint256 subjectTokenId;
        uint256 bondAmount;
        uint64 createdAt;
        uint64 expiresAt;
        bool active;
        bytes32 relationshipType;
    }

    // ----------------------------------------------------------------
    // Agents
    // ----------------------------------------------------------------

    enum AgentRole {
        None, // 0
        DataCollector, // 1
        Underwriter, // 2
        PoolManager, // 3
        Recovery // 4
    }
}

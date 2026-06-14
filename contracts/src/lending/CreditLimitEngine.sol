// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {ICreditLimitEngine, ILoanManager, IRepaymentGraduation} from "../interfaces/ILending.sol";
import {ISocialAttestation} from "../interfaces/IProtocol.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";

/// @title CreditLimitEngine
/// @notice Computes a borrower's maximum credit line from their tier base limit
///         plus a capped social-attestation bonus, then subtracts active loan
///         exposure to yield available headroom.
/// @dev View-only aggregator. Holds no funds and no per-user state beyond config.
contract CreditLimitEngine is ProtocolBase, ICreditLimitEngine {
    IScoreRegistry public immutable scoreRegistry;
    IRepaymentGraduation public immutable graduation;
    ISocialAttestation public immutable attestation;

    /// @notice LoanManager is set post-deploy to break the circular dependency
    ///         (LoanManager also needs the engine).
    ILoanManager public loanManager;

    /// @notice Base credit limit per tier (USDC, 6 decimals). Index tier-1.
    ///         Defaults: $20, $50, $150, $500, $2000.
    uint256[5] public tierBaseLimit;

    /// @notice Attestation bonus is capped at this multiple of the base limit
    ///         (bps). 20000 = 2x base limit.
    uint16 public attestationCapBps;

    /// @notice Minimum score required to borrow at all.
    uint16 public minBorrowScore;

    event LoanManagerSet(address loanManager);
    event TierBaseLimitsSet(uint256[5] limits);
    event AttestationCapSet(uint16 bps);
    event MinBorrowScoreSet(uint16 score);

    constructor(
        address accessController,
        address scoreRegistry_,
        address graduation_,
        address attestation_
    ) ProtocolBase(accessController) {
        if (scoreRegistry_ == address(0) || graduation_ == address(0) || attestation_ == address(0)) {
            revert ZeroAddress();
        }
        scoreRegistry = IScoreRegistry(scoreRegistry_);
        graduation = IRepaymentGraduation(graduation_);
        attestation = ISocialAttestation(attestation_);

        tierBaseLimit = [20e6, 50e6, 150e6, 500e6, 2000e6];
        attestationCapBps = 20000; // 2x
        minBorrowScore = 300; // any scored user; tighten in config if needed
    }

    /// @notice Wire the LoanManager after deployment. CONFIG_ROLE only.
    function setLoanManager(address loanManager_) external onlyRole(Roles.CONFIG_ROLE) {
        if (loanManager_ == address(0)) revert ZeroAddress();
        loanManager = ILoanManager(loanManager_);
        emit LoanManagerSet(loanManager_);
    }

    // ----------------------------------------------------------------
    // Limit math
    // ----------------------------------------------------------------

    /// @inheritdoc ICreditLimitEngine
    function maxLimit(uint256 tokenId) public view returns (uint256) {
        // No score => no credit.
        if (!scoreRegistry.hasScore(tokenId)) return 0;
        (uint16 value,,) = scoreRegistry.getScore(tokenId);
        if (value < minBorrowScore) return 0;

        uint8 tier = graduation.currentTier(tokenId);
        if (tier < 1) tier = 1;
        if (tier > 5) tier = 5;

        uint256 base = tierBaseLimit[tier - 1];

        uint256 bonus = attestation.totalWeight(tokenId);
        uint256 bonusCap = (base * attestationCapBps) / 1e4;
        if (bonus > bonusCap) bonus = bonusCap;

        return base + bonus;
    }

    /// @inheritdoc ICreditLimitEngine
    function availableCredit(uint256 tokenId)
        external
        view
        returns (uint256 limit, uint256 currentExposure, uint256 headroom)
    {
        limit = maxLimit(tokenId);
        currentExposure = address(loanManager) == address(0)
            ? 0
            : loanManager.totalActiveExposure(tokenId);
        headroom = limit > currentExposure ? limit - currentExposure : 0;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setTierBaseLimits(uint256[5] calldata limits) external onlyRole(Roles.CONFIG_ROLE) {
        tierBaseLimit = limits;
        emit TierBaseLimitsSet(limits);
    }

    function setAttestationCap(uint16 bps) external onlyRole(Roles.CONFIG_ROLE) {
        attestationCapBps = bps;
        emit AttestationCapSet(bps);
    }

    function setMinBorrowScore(uint16 score) external onlyRole(Roles.CONFIG_ROLE) {
        minBorrowScore = score;
        emit MinBorrowScoreSet(score);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {IRepaymentGraduation} from "../interfaces/ILending.sol";

/// @title RepaymentGraduation
/// @notice Tracks each borrower's repayment streak and derives a credit tier.
///         On-time repayments advance the streak and can promote a tier; defaults
///         reset progress and demote. This is the on-chain "graduation path" that
///         lets a reliable borrower climb from micro-loans to the full stack.
/// @dev `recordRepayment` / `recordDefault` are gated to POOL_MANAGER_ROLE (the
///      LoanManager). Tier is a pure function of the streak against thresholds.
contract RepaymentGraduation is ProtocolBase, IRepaymentGraduation {
    /// @notice tokenId => current consecutive on-time repayment count.
    mapping(uint256 => uint16) private _consecutiveOnTime;

    /// @notice tokenId => lifetime on-time repayments (never decreases).
    mapping(uint256 => uint32) public lifetimeOnTime;

    /// @notice tokenId => lifetime defaults.
    mapping(uint256 => uint32) public lifetimeDefaults;

    /// @notice Streak required to reach each tier index.
    ///         promotionThresholds[t] is the minimum streak for tier (t+1).
    ///         Default: tier1=0, tier2=2, tier3=5, tier4=12, tier5=24.
    uint16[5] public promotionThresholds;

    /// @notice How many tiers a default drops you (clamped at tier 1).
    uint8 public demotionTiers;

    /// @notice Floor tier after a demotion (defaulters can't go below this).
    uint8 public constant MIN_TIER = 1;
    uint8 public constant MAX_TIER = 5;

    /// @notice Explicit tier override after demotion. 0 means "derive from streak".
    mapping(uint256 => uint8) private _tierFloorOverride;

    event RepaymentRecorded(uint256 indexed tokenId, bool onTime, uint16 streak, uint8 tier);
    event DefaultRecorded(uint256 indexed tokenId, uint8 newTier);
    event TierPromoted(uint256 indexed tokenId, uint8 oldTier, uint8 newTier);
    event ThresholdsSet(uint16[5] thresholds);

    constructor(address accessController) ProtocolBase(accessController) {
        promotionThresholds = [0, 2, 5, 12, 24];
        demotionTiers = 2;
    }

    // ----------------------------------------------------------------
    // Recording (LoanManager only)
    // ----------------------------------------------------------------

    /// @inheritdoc IRepaymentGraduation
    function recordRepayment(uint256 tokenId, bool onTime)
        external
        whenNotPaused
        onlyRole(Roles.POOL_MANAGER_ROLE)
    {
        uint8 oldTier = currentTier(tokenId);

        if (onTime) {
            _consecutiveOnTime[tokenId] += 1;
            lifetimeOnTime[tokenId] += 1;
            // A clean repayment lifts any demotion floor once the streak recovers.
            if (_tierFloorOverride[tokenId] != 0) {
                uint8 derived = _deriveTierFromStreak(_consecutiveOnTime[tokenId]);
                if (derived >= _tierFloorOverride[tokenId]) {
                    _tierFloorOverride[tokenId] = 0;
                }
            }
        } else {
            // Late-but-not-defaulted: streak resets, no demotion floor.
            _consecutiveOnTime[tokenId] = 0;
        }

        uint8 newTier = currentTier(tokenId);
        emit RepaymentRecorded(tokenId, onTime, _consecutiveOnTime[tokenId], newTier);
        if (newTier > oldTier) emit TierPromoted(tokenId, oldTier, newTier);
    }

    /// @inheritdoc IRepaymentGraduation
    function recordDefault(uint256 tokenId)
        external
        whenNotPaused
        onlyRole(Roles.POOL_MANAGER_ROLE)
    {
        lifetimeDefaults[tokenId] += 1;

        uint8 tierNow = currentTier(tokenId);
        uint8 demoted = tierNow > demotionTiers ? tierNow - demotionTiers : MIN_TIER;
        if (demoted < MIN_TIER) demoted = MIN_TIER;

        _consecutiveOnTime[tokenId] = 0;
        _tierFloorOverride[tokenId] = demoted;

        emit DefaultRecorded(tokenId, demoted);
    }

    // ----------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------

    /// @inheritdoc IRepaymentGraduation
    function currentTier(uint256 tokenId) public view returns (uint8) {
        uint8 floorTier = _tierFloorOverride[tokenId];
        uint8 derived = _deriveTierFromStreak(_consecutiveOnTime[tokenId]);
        // After a default the borrower is capped at the demotion floor until the
        // streak rebuilds past it (handled in recordRepayment).
        if (floorTier != 0 && derived > floorTier) return floorTier;
        return derived;
    }

    /// @inheritdoc IRepaymentGraduation
    function consecutiveOnTime(uint256 tokenId) external view returns (uint16) {
        return _consecutiveOnTime[tokenId];
    }

    function _deriveTierFromStreak(uint16 streak) internal view returns (uint8) {
        uint8 tier = MIN_TIER;
        // Highest tier whose threshold the streak meets.
        for (uint8 t = MAX_TIER; t >= 1; --t) {
            if (streak >= promotionThresholds[t - 1]) {
                tier = t;
                break;
            }
            if (t == 1) break; // prevent uint8 underflow
        }
        return tier;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setThresholds(uint16[5] calldata thresholds) external onlyRole(Roles.CONFIG_ROLE) {
        promotionThresholds = thresholds;
        emit ThresholdsSet(thresholds);
    }

    function setDemotionTiers(uint8 tiers) external onlyRole(Roles.CONFIG_ROLE) {
        demotionTiers = tiers;
    }
}

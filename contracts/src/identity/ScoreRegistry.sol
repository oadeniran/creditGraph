// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";

/// @title ScoreRegistry
/// @notice The single source of truth for each identity's credit score.
/// @dev Read freely by anyone (composability is the point). Written only by an
///      address holding SCORE_UPDATER_ROLE (the ScoringOracle) or SLASHER_ROLE
///      (the CreditSlasher reducing a score on default).
contract ScoreRegistry is ProtocolBase, IScoreRegistry {
    uint16 public constant MIN_SCORE = 300;
    uint16 public constant MAX_SCORE = 1000;

    ICreditIdentity public immutable identity;

    /// @notice tokenId => current score.
    mapping(uint256 => DataTypes.Score) private _currentScore;

    /// @notice tokenId => full history of scores (append-only).
    mapping(uint256 => DataTypes.Score[]) private _scoreHistory;

    /// @notice Seconds after which a score is considered stale and should refresh.
    uint64 public stalenessThreshold;

    event ScoreUpdated(uint256 indexed tokenId, uint16 oldValue, uint16 newValue, uint8 tier);
    event StalenessThresholdSet(uint64 newThreshold);

    error InvalidScore(uint16 value);
    error InvalidTier(uint8 tier);
    error UnknownIdentity(uint256 tokenId);

    constructor(address accessController, address identity_, uint64 stalenessThreshold_)
        ProtocolBase(accessController)
    {
        if (identity_ == address(0)) revert ZeroAddress();
        identity = ICreditIdentity(identity_);
        stalenessThreshold = stalenessThreshold_;
    }

    // ----------------------------------------------------------------
    // Writes
    // ----------------------------------------------------------------

    /// @inheritdoc IScoreRegistry
    /// @dev Callable by SCORE_UPDATER_ROLE (oracle) or SLASHER_ROLE (slasher).
    function updateScore(uint256 tokenId, uint16 value, uint8 tier, bytes32 reasonHash)
        external
        whenNotPaused
    {
        if (
            !_hasRole(Roles.SCORE_UPDATER_ROLE, msg.sender)
                && !_hasRole(Roles.SLASHER_ROLE, msg.sender)
        ) {
            revert Unauthorized(Roles.SCORE_UPDATER_ROLE, msg.sender);
        }
        if (!identity.exists(tokenId)) revert UnknownIdentity(tokenId);
        if (value < MIN_SCORE || value > MAX_SCORE) revert InvalidScore(value);
        if (tier < 1 || tier > 5) revert InvalidTier(tier);

        uint16 oldValue = _currentScore[tokenId].value;

        DataTypes.Score memory s = DataTypes.Score({
            value: value,
            timestamp: uint64(block.timestamp),
            tier: tier,
            reasonHash: reasonHash
        });

        _currentScore[tokenId] = s;
        _scoreHistory[tokenId].push(s);

        emit ScoreUpdated(tokenId, oldValue, value, tier);
    }

    /// @notice Update the staleness threshold. CONFIG_ROLE only.
    function setStalenessThreshold(uint64 newThreshold) external onlyRole(Roles.CONFIG_ROLE) {
        stalenessThreshold = newThreshold;
        emit StalenessThresholdSet(newThreshold);
    }

    // ----------------------------------------------------------------
    // Reads
    // ----------------------------------------------------------------

    /// @inheritdoc IScoreRegistry
    function getScore(uint256 tokenId)
        external
        view
        returns (uint16 value, uint8 tier, bool isStale)
    {
        DataTypes.Score memory s = _currentScore[tokenId];
        value = s.value;
        tier = s.tier;
        isStale = s.timestamp == 0
            || (stalenessThreshold != 0 && block.timestamp > s.timestamp + stalenessThreshold);
    }

    /// @inheritdoc IScoreRegistry
    function getScoreStruct(uint256 tokenId) external view returns (DataTypes.Score memory) {
        return _currentScore[tokenId];
    }

    /// @inheritdoc IScoreRegistry
    /// @dev Returns the score that was current at-or-before `timestamp`.
    function getScoreAt(uint256 tokenId, uint64 timestamp) external view returns (uint16) {
        DataTypes.Score[] storage hist = _scoreHistory[tokenId];
        uint256 len = hist.length;
        if (len == 0) return 0;
        // Walk backwards; histories are short in practice.
        for (uint256 i = len; i > 0; --i) {
            if (hist[i - 1].timestamp <= timestamp) {
                return hist[i - 1].value;
            }
        }
        return 0;
    }

    /// @inheritdoc IScoreRegistry
    function isEligible(uint256 tokenId, uint16 minScore) external view returns (bool) {
        return _currentScore[tokenId].value >= minScore;
    }

    /// @inheritdoc IScoreRegistry
    function hasScore(uint256 tokenId) external view returns (bool) {
        return _currentScore[tokenId].timestamp != 0;
    }

    /// @notice Number of historical score entries for an identity.
    function scoreHistoryLength(uint256 tokenId) external view returns (uint256) {
        return _scoreHistory[tokenId].length;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title RobinhoodScoreMirror
/// @notice Deployed on Robinhood Chain. Holds a read-only mirror of CreditGraph
///         scores so institutional lenders building tokenized credit products on
///         Robinhood Chain can read a borrower's score natively, without making a
///         cross-chain query per read.
/// @dev Updates flow one-way: Arbitrum One (canonical ScoreRegistry) -> bridge ->
///      this contract. The bridge endpoint (LayerZero/CCIP receiver) holds
///      BRIDGE_ROLE and is the only writer. This contract is intentionally minimal
///      and never originates loans; it is a data sink for composability.
contract RobinhoodScoreMirror is ProtocolBase {
    struct MirroredScore {
        uint16 value;
        uint8 tier;
        uint64 sourceTimestamp; // timestamp from the source chain
        uint64 mirroredAt; // when this chain recorded it
    }

    /// @notice tokenId => latest mirrored score.
    mapping(uint256 => MirroredScore) private _scores;

    /// @notice Chain id of the canonical source (Arbitrum One = 42161).
    uint256 public sourceChainId;

    event ScoreMirrored(uint256 indexed tokenId, uint16 value, uint8 tier, uint64 sourceTimestamp);
    event SourceChainSet(uint256 chainId);

    error StaleUpdate(uint64 incoming, uint64 existing);

    constructor(address accessController, uint256 sourceChainId_) ProtocolBase(accessController) {
        sourceChainId = sourceChainId_;
    }

    // ----------------------------------------------------------------
    // Bridge-only write
    // ----------------------------------------------------------------

    /// @notice Receive a mirrored score update from the bridge.
    /// @dev Restricted to BRIDGE_ROLE. Rejects out-of-order updates by comparing
    ///      the source-chain timestamp, so a delayed message can't overwrite a
    ///      newer score.
    function receiveScoreUpdate(uint256 tokenId, uint16 value, uint8 tier, uint64 sourceTimestamp)
        external
        whenNotPaused
        onlyRole(Roles.BRIDGE_ROLE)
    {
        MirroredScore storage existing = _scores[tokenId];
        if (existing.sourceTimestamp != 0 && sourceTimestamp < existing.sourceTimestamp) {
            revert StaleUpdate(sourceTimestamp, existing.sourceTimestamp);
        }

        _scores[tokenId] = MirroredScore({
            value: value,
            tier: tier,
            sourceTimestamp: sourceTimestamp,
            mirroredAt: uint64(block.timestamp)
        });

        emit ScoreMirrored(tokenId, value, tier, sourceTimestamp);
    }

    /// @notice Batch variant for efficient bridging of multiple identities.
    function receiveScoreUpdateBatch(
        uint256[] calldata tokenIds,
        uint16[] calldata values,
        uint8[] calldata tiers,
        uint64[] calldata sourceTimestamps
    ) external whenNotPaused onlyRole(Roles.BRIDGE_ROLE) {
        uint256 n = tokenIds.length;
        require(
            values.length == n && tiers.length == n && sourceTimestamps.length == n,
            "Mirror: length mismatch"
        );
        for (uint256 i; i < n; ++i) {
            MirroredScore storage existing = _scores[tokenIds[i]];
            if (existing.sourceTimestamp != 0 && sourceTimestamps[i] < existing.sourceTimestamp) {
                continue; // skip stale entries in a batch rather than reverting all
            }
            _scores[tokenIds[i]] = MirroredScore({
                value: values[i],
                tier: tiers[i],
                sourceTimestamp: sourceTimestamps[i],
                mirroredAt: uint64(block.timestamp)
            });
            emit ScoreMirrored(tokenIds[i], values[i], tiers[i], sourceTimestamps[i]);
        }
    }

    // ----------------------------------------------------------------
    // Public reads (the whole point)
    // ----------------------------------------------------------------

    /// @notice Read a mirrored score.
    function getScore(uint256 tokenId) external view returns (uint16 value, uint8 tier, uint64 sourceTimestamp) {
        MirroredScore memory s = _scores[tokenId];
        return (s.value, s.tier, s.sourceTimestamp);
    }

    function getScoreStruct(uint256 tokenId) external view returns (MirroredScore memory) {
        return _scores[tokenId];
    }

    function hasScore(uint256 tokenId) external view returns (bool) {
        return _scores[tokenId].sourceTimestamp != 0;
    }

    function isEligible(uint256 tokenId, uint16 minScore) external view returns (bool) {
        return _scores[tokenId].value >= minScore;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setSourceChain(uint256 chainId) external onlyRole(Roles.CONFIG_ROLE) {
        sourceChainId = chainId;
        emit SourceChainSet(chainId);
    }
}

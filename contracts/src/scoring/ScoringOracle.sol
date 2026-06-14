// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";
import {IAgentRegistry} from "../interfaces/IProtocol.sol";

/// @title ScoringOracle
/// @notice Bridge between the off-chain Underwriting Agent quorum and the on-chain
///         ScoreRegistry. Verifies a quorum of EIP-712 signatures from authorized
///         agents, opens a challenge window, then finalizes the score on-chain.
/// @dev Holds SCORE_UPDATER_ROLE so it (and only it) can write to ScoreRegistry.
contract ScoringOracle is ProtocolBase, EIP712 {
    using ECDSA for bytes32;

    /// @dev EIP-712 typed-data struct hash for a score submission.
    bytes32 public constant SCORE_TYPEHASH = keccak256(
        "ScoreSubmission(uint256 tokenId,uint16 score,uint8 tier,bytes32 reasonHash,bytes32 nonce)"
    );

    IScoreRegistry public immutable scoreRegistry;
    IAgentRegistry public immutable agentRegistry;

    /// @notice Number of distinct authorized-agent signatures required.
    uint8 public quorumThreshold;

    /// @notice Seconds a submission must wait before it can be finalized.
    uint64 public challengePeriod;

    struct PendingScore {
        uint16 score;
        uint8 tier;
        bytes32 reasonHash;
        uint64 submittedAt;
        bool finalized;
        bool challenged;
    }

    /// @notice tokenId => the latest pending submission.
    mapping(uint256 => PendingScore) public pending;

    /// @notice Per-submission replay guard.
    mapping(bytes32 => bool) public usedNonces;

    event ScoreSubmitted(uint256 indexed tokenId, uint16 score, uint8 tier, uint64 finalizeAfter);
    event ScoreFinalized(uint256 indexed tokenId, uint16 score, uint8 tier);
    event ScoreChallenged(uint256 indexed tokenId, address indexed challenger);
    event QuorumThresholdSet(uint8 threshold);
    event ChallengePeriodSet(uint64 period);

    error NonceUsed(bytes32 nonce);
    error QuorumNotMet(uint256 valid, uint8 required);
    error NotEnoughSignatures();
    error SignaturesNotSorted();
    error NothingPending(uint256 tokenId);
    error ChallengeWindowOpen(uint64 finalizeAfter);
    error AlreadyFinalized();
    error WasChallenged();
    error InvalidConfig();

    constructor(
        address accessController,
        address scoreRegistry_,
        address agentRegistry_,
        uint8 quorumThreshold_,
        uint64 challengePeriod_
    ) ProtocolBase(accessController) EIP712("CreditGraph ScoringOracle", "1") {
        if (scoreRegistry_ == address(0) || agentRegistry_ == address(0)) revert ZeroAddress();
        if (quorumThreshold_ == 0) revert InvalidConfig();
        scoreRegistry = IScoreRegistry(scoreRegistry_);
        agentRegistry = IAgentRegistry(agentRegistry_);
        quorumThreshold = quorumThreshold_;
        challengePeriod = challengePeriod_;
    }

    // ----------------------------------------------------------------
    // Submission
    // ----------------------------------------------------------------

    /// @notice Submit a score backed by a quorum of agent signatures.
    /// @param tokenId   Identity being scored.
    /// @param score     Proposed score [300, 1000].
    /// @param tier      Proposed tier [1, 5].
    /// @param reasonHash IPFS CID of the score breakdown.
    /// @param signatures Array of EIP-712 signatures from authorized agents.
    ///                   MUST be sorted by ascending signer address (dedup guard).
    /// @param nonce     Unique submission nonce (replay guard).
    function submitScore(
        uint256 tokenId,
        uint16 score,
        uint8 tier,
        bytes32 reasonHash,
        bytes[] calldata signatures,
        bytes32 nonce
    ) external whenNotPaused {
        if (usedNonces[nonce]) revert NonceUsed(nonce);
        if (signatures.length < quorumThreshold) revert NotEnoughSignatures();

        bytes32 structHash =
            keccak256(abi.encode(SCORE_TYPEHASH, tokenId, score, tier, reasonHash, nonce));
        bytes32 digest = _hashTypedDataV4(structHash);

        // Verify each signature comes from a distinct, authorized Underwriter agent.
        // Enforcing strictly-ascending signer order both dedupes and bounds gas.
        uint256 validCount;
        address lastSigner = address(0);
        for (uint256 i; i < signatures.length; ++i) {
            address signer = digest.recover(signatures[i]);
            if (signer <= lastSigner) revert SignaturesNotSorted();
            lastSigner = signer;
            if (agentRegistry.isAuthorized(signer, DataTypes.AgentRole.Underwriter)) {
                unchecked {
                    ++validCount;
                }
            }
        }
        if (validCount < quorumThreshold) revert QuorumNotMet(validCount, quorumThreshold);

        usedNonces[nonce] = true;

        uint64 nowTs = uint64(block.timestamp);
        pending[tokenId] = PendingScore({
            score: score,
            tier: tier,
            reasonHash: reasonHash,
            submittedAt: nowTs,
            finalized: false,
            challenged: false
        });

        emit ScoreSubmitted(tokenId, score, tier, nowTs + challengePeriod);
    }

    // ----------------------------------------------------------------
    // Challenge & finalize
    // ----------------------------------------------------------------

    /// @notice Flag a pending submission as challenged, blocking finalization.
    /// @dev Open to anyone during the window. Off-chain dispute resolution (and
    ///      potential agent slashing via AgentRegistry) happens out of band; a
    ///      challenged score must be re-submitted with a fresh nonce.
    function challengeScore(uint256 tokenId) external whenNotPaused {
        PendingScore storage p = pending[tokenId];
        if (p.submittedAt == 0) revert NothingPending(tokenId);
        if (p.finalized) revert AlreadyFinalized();
        p.challenged = true;
        emit ScoreChallenged(tokenId, msg.sender);
    }

    /// @notice Finalize a pending, unchallenged submission after the window closes.
    /// @dev Permissionless: anyone can poke. Writes through to ScoreRegistry.
    function finalizeScore(uint256 tokenId) external whenNotPaused {
        PendingScore storage p = pending[tokenId];
        if (p.submittedAt == 0) revert NothingPending(tokenId);
        if (p.finalized) revert AlreadyFinalized();
        if (p.challenged) revert WasChallenged();

        uint64 finalizeAfter = p.submittedAt + challengePeriod;
        if (block.timestamp < finalizeAfter) revert ChallengeWindowOpen(finalizeAfter);

        p.finalized = true;
        scoreRegistry.updateScore(tokenId, p.score, p.tier, p.reasonHash);

        emit ScoreFinalized(tokenId, p.score, p.tier);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setQuorumThreshold(uint8 threshold) external onlyRole(Roles.CONFIG_ROLE) {
        if (threshold == 0) revert InvalidConfig();
        quorumThreshold = threshold;
        emit QuorumThresholdSet(threshold);
    }

    function setChallengePeriod(uint64 period) external onlyRole(Roles.CONFIG_ROLE) {
        challengePeriod = period;
        emit ChallengePeriodSet(period);
    }

    /// @notice Expose the EIP-712 domain separator for off-chain signers.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}

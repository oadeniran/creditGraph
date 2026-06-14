// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {ISocialAttestation} from "../interfaces/IProtocol.sol";
import {IRepaymentGraduation} from "../interfaces/ILending.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";

/// @title SocialAttestation
/// @notice Encodes Ajo/Esusu/Chama-style social trust as an on-chain credit
///         signal. An attester stakes a USDC bond vouching for a subject. The
///         bond increases the subject's credit weight (consumed by the
///         CreditLimitEngine) and is slashed if the subject defaults.
/// @dev Weight = bond * attesterTierMultiplier * timeDecayFactor. Higher-tier
///      attesters carry more weight; weight decays as the attestation nears
///      expiry. Bonds are escrowed here; slashed bonds are forwarded to the
///      InsuranceFund by the CreditSlasher flow.
contract SocialAttestation is ProtocolBase, ISocialAttestation, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bondToken; // USDC
    ICreditIdentity public immutable identity;
    IRepaymentGraduation public immutable graduation;

    /// @notice Destination for slashed bonds (InsuranceFund).
    address public insuranceFund;

    /// @dev Basis-points multiplier applied to bond by attester tier (index t-1).
    ///      tier1=100% ... tier5=200%.
    uint16[5] public tierMultiplierBps;

    /// @notice Cooldown after revocation request before a bond can be reclaimed,
    ///         protecting against revoke-just-before-default games.
    uint64 public revokeCooldown;

    /// @notice Global cap (bps of bond) on how much attestation weight can be
    ///         attributed; the engine separately caps relative to base limit.
    uint16 public constant DECAY_FLOOR_BPS = 5000; // weight never below 50% pre-expiry

    DataTypes.Attestation[] private _attestations;

    /// @notice subjectTokenId => attestation ids vouching for them.
    mapping(uint256 => uint256[]) private _bySubject;
    /// @notice attesterTokenId => attestation ids they created.
    mapping(uint256 => uint256[]) private _byAttester;
    /// @notice attestationId => pending-revoke unlock timestamp (0 = not revoking).
    mapping(uint256 => uint64) public revokeUnlockAt;

    event Attested(
        uint256 indexed attestationId,
        uint256 indexed attesterTokenId,
        uint256 indexed subjectTokenId,
        uint256 bondAmount,
        bytes32 relationshipType
    );
    event RevokeRequested(uint256 indexed attestationId, uint64 unlockAt);
    event Revoked(uint256 indexed attestationId, uint256 returned);
    event AttestationsSlashed(uint256 indexed subjectTokenId, uint256 lossAmount, uint256 recovered);
    event InsuranceFundSet(address fund);

    error NotIdentityOwner();
    error CannotAttestSelf();
    error UnknownIdentity(uint256 tokenId);
    error ZeroBond();
    error NotAttester();
    error AttestationInactive();
    error RevokeNotRequested();
    error RevokeOnCooldown(uint64 unlockAt);
    error SubjectHasNoFund();

    constructor(
        address accessController,
        address bondToken_,
        address identity_,
        address graduation_
    ) ProtocolBase(accessController) {
        if (bondToken_ == address(0) || identity_ == address(0) || graduation_ == address(0)) {
            revert ZeroAddress();
        }
        bondToken = IERC20(bondToken_);
        identity = ICreditIdentity(identity_);
        graduation = IRepaymentGraduation(graduation_);
        tierMultiplierBps = [10000, 12500, 15000, 17500, 20000];
        revokeCooldown = 3 days;
    }

    // ----------------------------------------------------------------
    // Create / revoke
    // ----------------------------------------------------------------

    /// @inheritdoc ISocialAttestation
    function attest(uint256 subjectTokenId, uint256 bondAmount, uint64 duration, bytes32 relType)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 attestationId)
    {
        if (bondAmount == 0) revert ZeroBond();
        uint256 attesterTokenId = identity.tokenIdOf(msg.sender);
        if (attesterTokenId == 0) revert NotIdentityOwner();
        if (!identity.exists(subjectTokenId)) revert UnknownIdentity(subjectTokenId);
        if (attesterTokenId == subjectTokenId) revert CannotAttestSelf();

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        attestationId = _attestations.length;
        _attestations.push(
            DataTypes.Attestation({
                attesterTokenId: attesterTokenId,
                subjectTokenId: subjectTokenId,
                bondAmount: bondAmount,
                createdAt: uint64(block.timestamp),
                expiresAt: uint64(block.timestamp) + duration,
                active: true,
                relationshipType: relType
            })
        );
        _bySubject[subjectTokenId].push(attestationId);
        _byAttester[attesterTokenId].push(attestationId);

        emit Attested(attestationId, attesterTokenId, subjectTokenId, bondAmount, relType);
    }

    /// @notice Begin revoking an attestation; starts the cooldown.
    function requestRevoke(uint256 attestationId) external whenNotPaused {
        DataTypes.Attestation storage at = _attestations[attestationId];
        if (!at.active) revert AttestationInactive();
        if (identity.tokenIdOf(msg.sender) != at.attesterTokenId) revert NotAttester();
        uint64 unlock = uint64(block.timestamp) + revokeCooldown;
        revokeUnlockAt[attestationId] = unlock;
        emit RevokeRequested(attestationId, unlock);
    }

    /// @inheritdoc ISocialAttestation
    /// @dev Reclaims the bond after the cooldown. Weight stops counting the moment
    ///      revoke is requested (see `_isCounted`).
    function revoke(uint256 attestationId) external nonReentrant whenNotPaused {
        DataTypes.Attestation storage at = _attestations[attestationId];
        if (!at.active) revert AttestationInactive();
        if (identity.tokenIdOf(msg.sender) != at.attesterTokenId) revert NotAttester();

        uint64 unlock = revokeUnlockAt[attestationId];
        if (unlock == 0) revert RevokeNotRequested();
        if (block.timestamp < unlock) revert RevokeOnCooldown(unlock);

        uint256 amount = at.bondAmount;
        at.active = false;
        at.bondAmount = 0;

        if (amount > 0) bondToken.safeTransfer(msg.sender, amount);
        emit Revoked(attestationId, amount);
    }

    // ----------------------------------------------------------------
    // Weight (read by CreditLimitEngine)
    // ----------------------------------------------------------------

    /// @inheritdoc ISocialAttestation
    /// @notice Total tier-scaled, decay-adjusted attestation weight backing a
    ///         subject. Denominated in USDC-equivalent units.
    function totalWeight(uint256 subjectTokenId) external view returns (uint256 weight) {
        uint256[] storage ids = _bySubject[subjectTokenId];
        uint256 len = ids.length;
        for (uint256 i; i < len; ++i) {
            uint256 id = ids[i];
            DataTypes.Attestation storage at = _attestations[id];
            if (!_isCounted(id, at)) continue;
            weight += _weightOf(at);
        }
    }

    /// @inheritdoc ISocialAttestation
    function attestationsFor(uint256 subjectTokenId)
        external
        view
        returns (DataTypes.Attestation[] memory out)
    {
        uint256[] storage ids = _bySubject[subjectTokenId];
        out = new DataTypes.Attestation[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = _attestations[ids[i]];
        }
    }

    // ----------------------------------------------------------------
    // Slashing (CreditSlasher only)
    // ----------------------------------------------------------------

    /// @inheritdoc ISocialAttestation
    /// @notice Slash active attestations on a defaulted subject, pro-rata across
    ///         bonds, up to `lossAmount`. Recovered USDC is sent to the insurance
    ///         fund. Returns the amount actually recovered.
    function slashAttestations(uint256 subjectTokenId, uint256 lossAmount)
        external
        nonReentrant
        returns (uint256 recovered)
    {
        if (!_hasRole(Roles.SLASHER_ROLE, msg.sender)) revert Unauthorized(Roles.SLASHER_ROLE, msg.sender);
        if (insuranceFund == address(0)) revert SubjectHasNoFund();

        uint256[] storage ids = _bySubject[subjectTokenId];
        uint256 len = ids.length;

        // First pass: total slashable bond among active attestations.
        uint256 totalBond;
        for (uint256 i; i < len; ++i) {
            DataTypes.Attestation storage at = _attestations[ids[i]];
            if (at.active && at.bondAmount > 0) totalBond += at.bondAmount;
        }
        if (totalBond == 0) return 0;

        uint256 target = lossAmount > totalBond ? totalBond : lossAmount;

        // Second pass: pro-rata slash.
        for (uint256 i; i < len; ++i) {
            DataTypes.Attestation storage at = _attestations[ids[i]];
            if (!at.active || at.bondAmount == 0) continue;
            uint256 share = (target * at.bondAmount) / totalBond;
            if (share > at.bondAmount) share = at.bondAmount;
            at.bondAmount -= share;
            recovered += share;
            if (at.bondAmount == 0) at.active = false;
        }

        if (recovered > 0) bondToken.safeTransfer(insuranceFund, recovered);
        emit AttestationsSlashed(subjectTokenId, lossAmount, recovered);
    }

    // ----------------------------------------------------------------
    // Internal weight math
    // ----------------------------------------------------------------

    /// @dev An attestation counts toward weight only if active, not expired, and
    ///      not in the process of being revoked.
    function _isCounted(uint256 id, DataTypes.Attestation storage at) internal view returns (bool) {
        if (!at.active) return false;
        if (block.timestamp >= at.expiresAt) return false;
        if (revokeUnlockAt[id] != 0) return false;
        return true;
    }

    /// @dev weight = bond * tierMultiplier * decay. Decay ramps linearly from
    ///      100% down to DECAY_FLOOR_BPS as the attestation approaches expiry.
    function _weightOf(DataTypes.Attestation storage at) internal view returns (uint256) {
        uint8 attesterTier = graduation.currentTier(at.attesterTokenId);
        if (attesterTier < 1) attesterTier = 1;
        if (attesterTier > 5) attesterTier = 5;
        uint256 mult = tierMultiplierBps[attesterTier - 1];

        uint256 decayBps = _decayBps(at.createdAt, at.expiresAt);

        // bond * mult/1e4 * decay/1e4
        return (at.bondAmount * mult * decayBps) / (1e4 * 1e4);
    }

    /// @dev Linear decay from 100% at creation to DECAY_FLOOR_BPS at expiry.
    function _decayBps(uint64 createdAt, uint64 expiresAt) internal view returns (uint256) {
        if (block.timestamp <= createdAt) return 1e4;
        if (expiresAt <= createdAt) return DECAY_FLOOR_BPS;
        uint256 elapsed = block.timestamp - createdAt;
        uint256 total = expiresAt - createdAt;
        if (elapsed >= total) return DECAY_FLOOR_BPS;
        // 10000 - (10000 - floor) * elapsed/total
        uint256 drop = ((1e4 - DECAY_FLOOR_BPS) * elapsed) / total;
        return 1e4 - drop;
    }

    // ----------------------------------------------------------------
    // Config / views
    // ----------------------------------------------------------------

    function setInsuranceFund(address fund) external onlyRole(Roles.CONFIG_ROLE) {
        if (fund == address(0)) revert ZeroAddress();
        insuranceFund = fund;
        emit InsuranceFundSet(fund);
    }

    function setTierMultipliers(uint16[5] calldata multipliers) external onlyRole(Roles.CONFIG_ROLE) {
        tierMultiplierBps = multipliers;
    }

    function setRevokeCooldown(uint64 cooldown) external onlyRole(Roles.CONFIG_ROLE) {
        revokeCooldown = cooldown;
    }

    function getAttestation(uint256 attestationId)
        external
        view
        returns (DataTypes.Attestation memory)
    {
        return _attestations[attestationId];
    }

    function totalAttestations() external view returns (uint256) {
        return _attestations.length;
    }

    function attestationsByAttester(uint256 attesterTokenId)
        external
        view
        returns (uint256[] memory)
    {
        return _byAttester[attesterTokenId];
    }
}

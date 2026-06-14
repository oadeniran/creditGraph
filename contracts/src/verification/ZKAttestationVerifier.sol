// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {IZKAttestationVerifier} from "../interfaces/IProtocol.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";

/// @dev Interface implemented by circom/snarkjs-generated Groth16 verifier
///      contracts. One verifier is deployed per proof circuit; we register its
///      address per claim type. The public-signal layout is circuit-specific.
interface IGroth16Verifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) external view returns (bool);
}

/// @title ZKAttestationVerifier
/// @notice Verifies zero-knowledge proofs about off-chain financial behavior and
///         records the resulting claims on-chain, without ever seeing raw data.
/// @dev Each claim type (e.g. MOBILE_MONEY_INFLOW_THRESHOLD) maps to a deployed
///      Groth16 verifier contract. Proofs are bound to an identity via a public
///      signal and protected against replay via per-proof nullifiers.
contract ZKAttestationVerifier is ProtocolBase, IZKAttestationVerifier {
    // Canonical claim type identifiers.
    bytes32 public constant MOBILE_MONEY_INFLOW_THRESHOLD = keccak256("MOBILE_MONEY_INFLOW_THRESHOLD");
    bytes32 public constant TRANSACTION_DIVERSITY = keccak256("TRANSACTION_DIVERSITY");
    bytes32 public constant ACCOUNT_AGE = keccak256("ACCOUNT_AGE");
    bytes32 public constant AJO_PARTICIPATION = keccak256("AJO_PARTICIPATION");

    ICreditIdentity public immutable identity;

    /// @notice claimType => deployed Groth16 verifier contract.
    mapping(bytes32 => address) public verifierFor;

    /// @notice Spent nullifiers (one proof can be used once).
    mapping(bytes32 => bool) public usedNullifiers;

    /// @notice tokenId => claimType => timestamp the claim was last verified.
    mapping(uint256 => mapping(bytes32 => uint64)) private _claimTimestamp;

    event VerifierRegistered(bytes32 indexed claimType, address verifier);
    event ClaimRecorded(uint256 indexed tokenId, bytes32 indexed claimType, uint64 timestamp);

    error NoVerifier(bytes32 claimType);
    error NullifierUsed(bytes32 nullifier);
    error ProofInvalid();
    error IdentityMismatch();
    error UnknownIdentity(uint256 tokenId);

    constructor(address accessController, address identity_) ProtocolBase(accessController) {
        if (identity_ == address(0)) revert ZeroAddress();
        identity = ICreditIdentity(identity_);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    /// @notice Register (or replace) the Groth16 verifier for a claim type.
    function registerVerifier(bytes32 claimType, address verifier)
        external
        onlyRole(Roles.CONFIG_ROLE)
    {
        if (verifier == address(0)) revert ZeroAddress();
        verifierFor[claimType] = verifier;
        emit VerifierRegistered(claimType, verifier);
    }

    // ----------------------------------------------------------------
    // Proof submission
    // ----------------------------------------------------------------

    /// @notice Verify a ZK proof and record the claim for an identity.
    /// @dev By convention the circuit exposes public signals as:
    ///        input[0] = tokenId (binds the proof to the identity)
    ///        input[1] = nullifier (replay guard)
    ///        input[2..] = circuit-specific public outputs (e.g. threshold met = 1)
    ///      The caller is whoever relays the proof; binding is via input[0], so a
    ///      relayer cannot record a claim for an identity they didn't prove for.
    function recordClaim(
        uint256 tokenId,
        bytes32 claimType,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) external whenNotPaused {
        address verifier = verifierFor[claimType];
        if (verifier == address(0)) revert NoVerifier(claimType);
        if (!identity.exists(tokenId)) revert UnknownIdentity(tokenId);

        // Bind proof to the identity: the first public signal must equal tokenId.
        if (input.length < 2 || input[0] != tokenId) revert IdentityMismatch();

        bytes32 nullifier = bytes32(input[1]);
        if (usedNullifiers[nullifier]) revert NullifierUsed(nullifier);

        bool ok = IGroth16Verifier(verifier).verifyProof(a, b, c, input);
        if (!ok) revert ProofInvalid();

        usedNullifiers[nullifier] = true;
        uint64 nowTs = uint64(block.timestamp);
        _claimTimestamp[tokenId][claimType] = nowTs;

        emit ClaimRecorded(tokenId, claimType, nowTs);
    }

    // ----------------------------------------------------------------
    // Views (IZKAttestationVerifier)
    // ----------------------------------------------------------------

    /// @inheritdoc IZKAttestationVerifier
    function hasValidClaim(uint256 tokenId, bytes32 claimType, uint64 maxAge)
        external
        view
        returns (bool)
    {
        uint64 ts = _claimTimestamp[tokenId][claimType];
        if (ts == 0) return false;
        if (maxAge == 0) return true; // 0 == no expiry check
        return block.timestamp <= ts + maxAge;
    }

    /// @inheritdoc IZKAttestationVerifier
    function claimTimestamp(uint256 tokenId, bytes32 claimType) external view returns (uint64) {
        return _claimTimestamp[tokenId][claimType];
    }
}

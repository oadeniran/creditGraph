// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

/// @title ISocialAttestation
/// @notice Encodes Ajo/Esusu/Chama-style social vouching as a credit signal.
interface ISocialAttestation {
    function attest(uint256 subjectTokenId, uint256 bondAmount, uint64 duration, bytes32 relType)
        external
        returns (uint256 attestationId);

    function revoke(uint256 attestationId) external;

    function attestationsFor(uint256 tokenId) external view returns (DataTypes.Attestation[] memory);

    function totalWeight(uint256 tokenId) external view returns (uint256);

    function slashAttestations(uint256 subjectTokenId, uint256 lossAmount) external returns (uint256 recovered);
}

/// @title IInsuranceFund
/// @notice Reserve buffer that absorbs defaults before suppliers take losses.
interface IInsuranceFund {
    function fund(uint256 amount) external;

    function cover(uint256 loanId, uint256 amount) external returns (uint256 covered);

    function balance() external view returns (uint256);
}

/// @title ICreditSlasher
/// @notice Executes the consequences of a default.
interface ICreditSlasher {
    function processDefault(uint256 loanId, uint256 tokenId, uint256 loss) external;
}

/// @title IZKAttestationVerifier
/// @notice Verifies ZK proofs about off-chain behavior and records verified claims.
interface IZKAttestationVerifier {
    function hasValidClaim(uint256 tokenId, bytes32 claimType, uint64 maxAge) external view returns (bool);

    function claimTimestamp(uint256 tokenId, bytes32 claimType) external view returns (uint64);
}

/// @title IAgentRegistry
/// @notice Whitelists authorized agents and tracks their stake / reputation.
interface IAgentRegistry {
    function isAuthorized(address agent, DataTypes.AgentRole role) external view returns (bool);

    function stakeOf(address agent) external view returns (uint256);

    function slash(address agent, uint256 amount) external returns (uint256 slashed);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICreditIdentity
/// @notice Interface to the soulbound credit-identity token.
interface ICreditIdentity {
    function mint(address user, bytes32 metadataHash) external returns (uint256 tokenId);

    function tokenIdOf(address user) external view returns (uint256);

    function ownerOfIdentity(uint256 tokenId) external view returns (address);

    function exists(uint256 tokenId) external view returns (bool);

    function createdAt(uint256 tokenId) external view returns (uint64);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

/// @title IScoreRegistry
/// @notice Canonical store of credit scores. Read by anyone, written by the oracle.
interface IScoreRegistry {
    function updateScore(uint256 tokenId, uint16 value, uint8 tier, bytes32 reasonHash) external;

    function getScore(uint256 tokenId) external view returns (uint16 value, uint8 tier, bool isStale);

    function getScoreStruct(uint256 tokenId) external view returns (DataTypes.Score memory);

    function getScoreAt(uint256 tokenId, uint64 timestamp) external view returns (uint16);

    function isEligible(uint256 tokenId, uint16 minScore) external view returns (bool);

    function hasScore(uint256 tokenId) external view returns (bool);
}

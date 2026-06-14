// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title DataOracleAdapter
/// @notice Thin adapter for non-ZK external data (e.g. USDC/NGN FX rate) used by
///         agents and the limit/rate logic. Keeps the rest of the protocol
///         decoupled from any specific oracle provider.
/// @dev MVP implementation is a push oracle: an authorized feeder (CONFIG_ROLE,
///      typically the Pool Manager agent or a Chainlink Functions callback) writes
///      prices. Swap in a pull-based Chainlink aggregator later without touching
///      consumers, since they only read `latestPrice`.
contract DataOracleAdapter is ProtocolBase {
    struct Feed {
        uint256 value; // price, scaled by `decimals`
        uint64 updatedAt;
        uint8 decimals;
        bool exists;
    }

    /// @notice pairId (e.g. keccak256("USDC/NGN")) => latest feed data.
    mapping(bytes32 => Feed) private _feeds;

    /// @notice Max age before a feed read is considered stale (seconds).
    uint64 public maxStaleness;

    event FeedUpdated(bytes32 indexed pairId, uint256 value, uint8 decimals);
    event MaxStalenessSet(uint64 maxStaleness);

    error FeedMissing(bytes32 pairId);
    error FeedStale(bytes32 pairId, uint64 updatedAt);

    constructor(address accessController, uint64 maxStaleness_) ProtocolBase(accessController) {
        maxStaleness = maxStaleness_;
    }

    /// @notice Push a new price for a pair. Restricted to CONFIG_ROLE feeders.
    function setPrice(bytes32 pairId, uint256 value, uint8 decimals)
        external
        onlyRole(Roles.CONFIG_ROLE)
    {
        _feeds[pairId] =
            Feed({value: value, updatedAt: uint64(block.timestamp), decimals: decimals, exists: true});
        emit FeedUpdated(pairId, value, decimals);
    }

    function setMaxStaleness(uint64 newMax) external onlyRole(Roles.CONFIG_ROLE) {
        maxStaleness = newMax;
        emit MaxStalenessSet(newMax);
    }

    /// @notice Latest price for a pair, reverting if missing or stale.
    function latestPrice(bytes32 pairId)
        external
        view
        returns (uint256 value, uint64 updatedAt, uint8 decimals)
    {
        Feed memory f = _feeds[pairId];
        if (!f.exists) revert FeedMissing(pairId);
        if (maxStaleness != 0 && block.timestamp > f.updatedAt + maxStaleness) {
            revert FeedStale(pairId, f.updatedAt);
        }
        return (f.value, f.updatedAt, f.decimals);
    }

    /// @notice Non-reverting read for callers that handle staleness themselves.
    function peek(bytes32 pairId)
        external
        view
        returns (uint256 value, uint64 updatedAt, uint8 decimals, bool exists)
    {
        Feed memory f = _feeds[pairId];
        return (f.value, f.updatedAt, f.decimals, f.exists);
    }
}

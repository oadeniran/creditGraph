// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title Treasury
/// @notice Collects protocol fees (in USDC) and routes them by configurable
///         basis-point splits to the insurance fund, an operations multisig, and
///         an agent staking-reward pool.
contract Treasury is ProtocolBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset; // USDC

    address public insuranceFund;
    address public operations;
    address public agentRewards;

    uint16 public insuranceBps; // default 5000 (50%)
    uint16 public operationsBps; // default 3000 (30%)
    uint16 public agentRewardsBps; // default 2000 (20%)

    event Routed(uint256 total, uint256 toInsurance, uint256 toOps, uint256 toAgents);
    event SplitsSet(uint16 insuranceBps, uint16 operationsBps, uint16 agentRewardsBps);
    event DestinationsSet(address insuranceFund, address operations, address agentRewards);

    error BadSplits();
    error DestinationsUnset();

    constructor(
        address accessController,
        address asset_,
        address insuranceFund_,
        address operations_,
        address agentRewards_
    ) ProtocolBase(accessController) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = IERC20(asset_);
        insuranceFund = insuranceFund_;
        operations = operations_;
        agentRewards = agentRewards_;
        insuranceBps = 5000;
        operationsBps = 3000;
        agentRewardsBps = 2000;
    }

    /// @notice Route the contract's entire current USDC balance per the splits.
    /// @dev Permissionless poke; funds only ever move to preset destinations.
    function route() external nonReentrant whenNotPaused {
        if (insuranceFund == address(0) || operations == address(0) || agentRewards == address(0)) {
            revert DestinationsUnset();
        }
        uint256 bal = asset.balanceOf(address(this));
        if (bal == 0) {
            emit Routed(0, 0, 0, 0);
            return;
        }

        uint256 toInsurance = (bal * insuranceBps) / 1e4;
        uint256 toOps = (bal * operationsBps) / 1e4;
        // Remainder to agents avoids dust loss from integer division.
        uint256 toAgents = bal - toInsurance - toOps;

        if (toInsurance > 0) asset.safeTransfer(insuranceFund, toInsurance);
        if (toOps > 0) asset.safeTransfer(operations, toOps);
        if (toAgents > 0) asset.safeTransfer(agentRewards, toAgents);

        emit Routed(bal, toInsurance, toOps, toAgents);
    }

    /// @notice Emergency/manual withdraw. CONFIG_ROLE only.
    function withdraw(address to, uint256 amount) external nonReentrant onlyRole(Roles.CONFIG_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        asset.safeTransfer(to, amount);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setSplits(uint16 insuranceBps_, uint16 operationsBps_, uint16 agentRewardsBps_)
        external
        onlyRole(Roles.CONFIG_ROLE)
    {
        if (uint256(insuranceBps_) + operationsBps_ + agentRewardsBps_ != 1e4) revert BadSplits();
        insuranceBps = insuranceBps_;
        operationsBps = operationsBps_;
        agentRewardsBps = agentRewardsBps_;
        emit SplitsSet(insuranceBps_, operationsBps_, agentRewardsBps_);
    }

    function setDestinations(address insuranceFund_, address operations_, address agentRewards_)
        external
        onlyRole(Roles.CONFIG_ROLE)
    {
        insuranceFund = insuranceFund_;
        operations = operations_;
        agentRewards = agentRewards_;
        emit DestinationsSet(insuranceFund_, operations_, agentRewards_);
    }
}

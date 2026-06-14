// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {IAgentRegistry} from "../interfaces/IProtocol.sol";

/// @title AgentRegistry
/// @notice Whitelists off-chain agents, escrows their USDC stake, and tracks
///         reputation. Agents that publish bad data can be slashed, giving the
///         off-chain layer real skin in the game.
contract AgentRegistry is ProtocolBase, IAgentRegistry, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakeToken; // USDC

    struct Agent {
        DataTypes.AgentRole role;
        uint256 stake;
        int256 reputation;
        uint64 registeredAt;
        uint64 unbondingAt; // 0 unless a withdrawal has been initiated
        bool active;
    }

    mapping(address => Agent) public agents;

    /// @notice Minimum stake required to register, per role.
    mapping(DataTypes.AgentRole => uint256) public minStake;

    /// @notice Cooldown between requesting and completing stake withdrawal.
    uint64 public unbondingPeriod;

    event AgentRegistered(address indexed agent, DataTypes.AgentRole role, uint256 stake);
    event StakeAdded(address indexed agent, uint256 amount, uint256 newTotal);
    event UnbondingStarted(address indexed agent, uint64 withdrawableAt);
    event AgentDeregistered(address indexed agent, uint256 returned);
    event AgentSlashed(address indexed agent, uint256 amount, uint256 remaining);
    event PerformanceRecorded(address indexed agent, int256 delta, int256 newReputation);
    event MinStakeSet(DataTypes.AgentRole role, uint256 minStake);

    error AlreadyRegistered();
    error NotRegistered();
    error RoleRequired();
    error InsufficientStake(uint256 provided, uint256 required);
    error UnbondingNotStarted();
    error UnbondingNotComplete(uint64 withdrawableAt);
    error HasActiveUnbonding();

    constructor(address accessController, address stakeToken_, uint64 unbondingPeriod_)
        ProtocolBase(accessController)
    {
        if (stakeToken_ == address(0)) revert ZeroAddress();
        stakeToken = IERC20(stakeToken_);
        unbondingPeriod = unbondingPeriod_;
    }

    // ----------------------------------------------------------------
    // Registration & staking
    // ----------------------------------------------------------------

    /// @notice Register as an agent for a role, staking `amount` USDC.
    function register(DataTypes.AgentRole role, uint256 amount) external nonReentrant whenNotPaused {
        if (role == DataTypes.AgentRole.None) revert RoleRequired();
        Agent storage a = agents[msg.sender];
        if (a.active) revert AlreadyRegistered();

        uint256 required = minStake[role];
        if (amount < required) revert InsufficientStake(amount, required);

        stakeToken.safeTransferFrom(msg.sender, address(this), amount);

        a.role = role;
        a.stake = amount;
        a.reputation = 0;
        a.registeredAt = uint64(block.timestamp);
        a.unbondingAt = 0;
        a.active = true;

        emit AgentRegistered(msg.sender, role, amount);
    }

    /// @notice Top up stake.
    function addStake(uint256 amount) external nonReentrant whenNotPaused {
        Agent storage a = agents[msg.sender];
        if (!a.active) revert NotRegistered();
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        a.stake += amount;
        emit StakeAdded(msg.sender, amount, a.stake);
    }

    /// @notice Begin the unbonding cooldown before withdrawing stake.
    function startUnbonding() external whenNotPaused {
        Agent storage a = agents[msg.sender];
        if (!a.active) revert NotRegistered();
        a.unbondingAt = uint64(block.timestamp) + unbondingPeriod;
        emit UnbondingStarted(msg.sender, a.unbondingAt);
    }

    /// @notice Complete deregistration after the cooldown and reclaim stake.
    function deregister() external nonReentrant {
        Agent storage a = agents[msg.sender];
        if (!a.active) revert NotRegistered();
        if (a.unbondingAt == 0) revert UnbondingNotStarted();
        if (block.timestamp < a.unbondingAt) revert UnbondingNotComplete(a.unbondingAt);

        uint256 amount = a.stake;
        // Effects before interaction.
        a.active = false;
        a.stake = 0;
        a.role = DataTypes.AgentRole.None;
        a.unbondingAt = 0;

        if (amount > 0) stakeToken.safeTransfer(msg.sender, amount);
        emit AgentDeregistered(msg.sender, amount);
    }

    // ----------------------------------------------------------------
    // Authorization view (IAgentRegistry)
    // ----------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    function isAuthorized(address agent, DataTypes.AgentRole role) external view returns (bool) {
        Agent storage a = agents[agent];
        return a.active && a.role == role && a.unbondingAt == 0;
    }

    /// @inheritdoc IAgentRegistry
    function stakeOf(address agent) external view returns (uint256) {
        return agents[agent].stake;
    }

    // ----------------------------------------------------------------
    // Slashing & reputation
    // ----------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    /// @dev Slashed funds are held by this contract; governance routes them via
    ///      `sweepSlashed`. Restricted to SLASHER_ROLE / CONFIG_ROLE.
    function slash(address agent, uint256 amount) external returns (uint256 slashed) {
        if (!_hasRole(Roles.SLASHER_ROLE, msg.sender) && !_hasRole(Roles.CONFIG_ROLE, msg.sender)) {
            revert Unauthorized(Roles.SLASHER_ROLE, msg.sender);
        }
        Agent storage a = agents[agent];
        if (!a.active) revert NotRegistered();

        slashed = amount > a.stake ? a.stake : amount;
        a.stake -= slashed;
        a.reputation -= int256(slashed);

        emit AgentSlashed(agent, slashed, a.stake);
    }

    /// @notice Adjust an agent's reputation score. CONFIG_ROLE only.
    function recordPerformance(address agent, int256 delta) external onlyRole(Roles.CONFIG_ROLE) {
        Agent storage a = agents[agent];
        if (!a.active) revert NotRegistered();
        a.reputation += delta;
        emit PerformanceRecorded(agent, delta, a.reputation);
    }

    /// @notice Move accumulated slashed funds to a destination. CONFIG_ROLE only.
    function sweepSlashed(address to, uint256 amount) external nonReentrant onlyRole(Roles.CONFIG_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        stakeToken.safeTransfer(to, amount);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setMinStake(DataTypes.AgentRole role, uint256 amount) external onlyRole(Roles.CONFIG_ROLE) {
        minStake[role] = amount;
        emit MinStakeSet(role, amount);
    }

    function setUnbondingPeriod(uint64 period) external onlyRole(Roles.CONFIG_ROLE) {
        unbondingPeriod = period;
    }

    function reputationOf(address agent) external view returns (int256) {
        return agents[agent].reputation;
    }
}

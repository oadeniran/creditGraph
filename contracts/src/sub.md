agents/AgentRegistry.sol
```
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
```


agents/X402PaymentRouter.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";

/// @title X402PaymentRouter
/// @notice On-chain settlement + receipt layer for x402-style agent-to-agent
///         micropayments. A payer opens a funded channel to a payee; the payee
///         redeems signed vouchers off-chain and settles on-chain. Receipts give
///         a verifiable audit trail of agent commerce (e.g. underwriter paying the
///         data-collector for a verified feed).
/// @dev Payment vouchers are cumulative: each voucher authorizes a running total,
///      so only the latest needs to be submitted. Classic unidirectional channel.
contract X402PaymentRouter is ProtocolBase, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    IERC20 public immutable payToken; // USDC

    struct Channel {
        address payer;
        address payee;
        uint256 deposit; // total funded
        uint256 claimed; // cumulative amount already paid out
        uint64 expiresAt; // payer can reclaim remainder after this
        bool open;
    }

    /// @notice channelId => channel.
    mapping(bytes32 => Channel) public channels;

    /// @notice Monotonic salt to make channel ids unique per payer.
    mapping(address => uint256) public channelNonce;

    event ChannelOpened(
        bytes32 indexed channelId, address indexed payer, address indexed payee, uint256 deposit, uint64 expiresAt
    );
    event Settled(bytes32 indexed channelId, uint256 cumulativeAmount, uint256 paidOut);
    event ReceiptRecorded(bytes32 indexed channelId, bytes32 indexed dataHash, uint256 amount);
    event ChannelClosed(bytes32 indexed channelId, uint256 refunded);

    error NotPayer();
    error NotPayee();
    error ChannelNotOpen();
    error ChannelStillActive(uint64 expiresAt);
    error BadCumulativeAmount();
    error InvalidVoucherSignature();
    error ExpiredChannel();

    constructor(address accessController, address payToken_) ProtocolBase(accessController) {
        if (payToken_ == address(0)) revert ZeroAddress();
        payToken = IERC20(payToken_);
    }

    // ----------------------------------------------------------------
    // Channel lifecycle
    // ----------------------------------------------------------------

    /// @notice Open and fund a unidirectional payment channel to `payee`.
    function openChannel(address payee, uint256 deposit, uint64 duration)
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 channelId)
    {
        if (payee == address(0)) revert ZeroAddress();
        channelId = keccak256(abi.encodePacked(msg.sender, payee, channelNonce[msg.sender]++, block.chainid));

        payToken.safeTransferFrom(msg.sender, address(this), deposit);

        uint64 expiresAt = uint64(block.timestamp) + duration;
        channels[channelId] = Channel({
            payer: msg.sender,
            payee: payee,
            deposit: deposit,
            claimed: 0,
            expiresAt: expiresAt,
            open: true
        });

        emit ChannelOpened(channelId, msg.sender, payee, deposit, expiresAt);
    }

    /// @notice Payee settles using the payer's signed cumulative voucher.
    /// @param channelId  Target channel.
    /// @param cumulativeAmount Total authorized to date (>= previously claimed).
    /// @param payerSig   Payer's signature over (channelId, cumulativeAmount).
    function settle(bytes32 channelId, uint256 cumulativeAmount, bytes calldata payerSig)
        external
        nonReentrant
        whenNotPaused
    {
        Channel storage ch = channels[channelId];
        if (!ch.open) revert ChannelNotOpen();
        if (msg.sender != ch.payee) revert NotPayee();
        if (block.timestamp > ch.expiresAt) revert ExpiredChannel();
        if (cumulativeAmount <= ch.claimed || cumulativeAmount > ch.deposit) revert BadCumulativeAmount();

        // Verify the payer authorized this cumulative amount.
        bytes32 voucher = keccak256(abi.encodePacked(address(this), block.chainid, channelId, cumulativeAmount));
        bytes32 ethSigned = MessageHashUtils_toEthSignedMessageHash(voucher);
        address signer = ethSigned.recover(payerSig);
        if (signer != ch.payer) revert InvalidVoucherSignature();

        uint256 payout = cumulativeAmount - ch.claimed;
        ch.claimed = cumulativeAmount;

        payToken.safeTransfer(ch.payee, payout);
        emit Settled(channelId, cumulativeAmount, payout);
    }

    /// @notice Record an off-chain data-delivery receipt for audit/demo purposes.
    /// @dev Either party may record; purely informational, does not move funds.
    function recordReceipt(bytes32 channelId, bytes32 dataHash, uint256 amount) external whenNotPaused {
        Channel storage ch = channels[channelId];
        if (!ch.open) revert ChannelNotOpen();
        if (msg.sender != ch.payer && msg.sender != ch.payee) revert NotPayee();
        emit ReceiptRecorded(channelId, dataHash, amount);
    }

    /// @notice Payer reclaims the unclaimed remainder after the channel expires.
    function closeChannel(bytes32 channelId) external nonReentrant {
        Channel storage ch = channels[channelId];
        if (!ch.open) revert ChannelNotOpen();
        if (msg.sender != ch.payer) revert NotPayer();
        if (block.timestamp <= ch.expiresAt) revert ChannelStillActive(ch.expiresAt);

        uint256 refund = ch.deposit - ch.claimed;
        ch.open = false;

        if (refund > 0) payToken.safeTransfer(ch.payer, refund);
        emit ChannelClosed(channelId, refund);
    }

    // ----------------------------------------------------------------
    // Internal
    // ----------------------------------------------------------------

    /// @dev Local copy of OZ MessageHashUtils.toEthSignedMessageHash to avoid an
    ///      extra import; identical behavior.
    function MessageHashUtils_toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }
}
```


crosschain/RobinhoodScoreMirror.sol
```
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
```


governance/AccessController.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Roles} from "../libraries/Roles.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";

/// @title AccessController
/// @notice Central registry of protocol roles plus a global pause flag.
/// @dev Every other contract holds a reference to this and gates sensitive
///      functions through it, so roles are managed in exactly one place.
contract AccessController is AccessControl, IAccessController {
    /// @notice Global emergency pause. When true, ProtocolBase-derived contracts
    ///         should block state-changing user actions.
    bool private _paused;

    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error AlreadyInState();

    /// @param admin The address granted DEFAULT_ADMIN_ROLE (should be a multisig).
    constructor(address admin) {
        require(admin != address(0), "AccessController: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(Roles.PAUSER_ROLE, admin);
        _grantRole(Roles.CONFIG_ROLE, admin);
    }

    /// @inheritdoc IAccessController
    function hasRole(bytes32 role, address account)
        public
        view
        override(AccessControl, IAccessController)
        returns (bool)
    {
        return super.hasRole(role, account);
    }

    /// @inheritdoc IAccessController
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /// @notice Pause the protocol. Restricted to PAUSER_ROLE.
    function pause() external onlyRole(Roles.PAUSER_ROLE) {
        if (_paused) revert AlreadyInState();
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the protocol. Restricted to PAUSER_ROLE.
    function unpause() external onlyRole(Roles.PAUSER_ROLE) {
        if (!_paused) revert AlreadyInState();
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Convenience batch grant for wiring up the protocol after deploy.
    /// @dev Restricted to DEFAULT_ADMIN_ROLE.
    function grantRoles(bytes32[] calldata roles, address[] calldata accounts)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(roles.length == accounts.length, "AccessController: length mismatch");
        for (uint256 i; i < roles.length; ++i) {
            _grantRole(roles[i], accounts[i]);
        }
    }
}
```


governance/ProtocolBase.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAccessController} from "../interfaces/IAccessController.sol";

/// @title ProtocolBase
/// @notice Shared base that wires a contract to the central AccessController for
///         role checks and global pause enforcement.
/// @dev Inherit this in any contract that needs protocol roles. Keeps access
///      logic uniform and in one place.
abstract contract ProtocolBase {
    /// @notice The central access controller.
    IAccessController public immutable access;

    error Unauthorized(bytes32 role, address account);
    error ProtocolPaused();
    error ZeroAddress();

    constructor(address accessController) {
        if (accessController == address(0)) revert ZeroAddress();
        access = IAccessController(accessController);
    }

    /// @dev Reverts unless `msg.sender` holds `role` in the AccessController.
    modifier onlyRole(bytes32 role) {
        if (!access.hasRole(role, msg.sender)) revert Unauthorized(role, msg.sender);
        _;
    }

    /// @dev Reverts when the protocol is globally paused.
    modifier whenNotPaused() {
        if (access.isPaused()) revert ProtocolPaused();
        _;
    }

    /// @dev Helper for internal authorization checks of arbitrary accounts.
    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        return access.hasRole(role, account);
    }
}
```


governance/Treasury.sol
```
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
```


identity/CreditIdentity.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";

/// @dev Minimal ERC-5192 interface ("Minimal Soulbound NFTs", EIP-5192).
interface IERC5192 {
    /// @notice Emitted when the locking status is set to locked.
    event Locked(uint256 tokenId);
    /// @notice Emitted when the locking status is set to unlocked.
    event Unlocked(uint256 tokenId);

    /// @notice Returns the locking status of a Soulbound Token.
    function locked(uint256 tokenId) external view returns (bool);
}

/// @title CreditIdentity
/// @notice A non-transferable (soulbound) identity token. Exactly one per wallet.
///         It is the primary key that every other contract references via tokenId.
/// @dev Implements ERC-5192. All transfer/approval paths revert. Identity cannot
///      be bought, sold, or moved.
contract CreditIdentity is ERC721, ProtocolBase, ICreditIdentity, IERC5192 {
    /// @notice wallet => identity token id (0 means none).
    mapping(address => uint256) private _addressToTokenId;

    /// @notice tokenId => off-chain profile pointer (IPFS CID as bytes32).
    mapping(uint256 => bytes32) public metadataHash;

    /// @notice tokenId => creation timestamp, used for credit-age weighting.
    mapping(uint256 => uint64) private _createdAt;

    /// @notice Monotonically increasing identity counter. Ids start at 1.
    uint256 public totalIdentities;

    event IdentityMinted(address indexed user, uint256 indexed tokenId, bytes32 metadataHash);
    event MetadataUpdated(uint256 indexed tokenId, bytes32 newHash);

    error AlreadyHasIdentity(address user);
    error IdentityNonTransferable();
    error NotIdentityOwner();
    error DoesNotExist();

    constructor(address accessController)
        ERC721("CreditGraph Identity", "CGID")
        ProtocolBase(accessController)
    {}

    // ----------------------------------------------------------------
    // Minting
    // ----------------------------------------------------------------

    /// @inheritdoc ICreditIdentity
    /// @dev Restricted to MINTER_ROLE (onboarding backend / agent).
    function mint(address user, bytes32 metadataHash_)
        external
        whenNotPaused
        onlyRole(Roles.MINTER_ROLE)
        returns (uint256 tokenId)
    {
        if (user == address(0)) revert ZeroAddress();
        if (_addressToTokenId[user] != 0) revert AlreadyHasIdentity(user);

        tokenId = ++totalIdentities;
        _addressToTokenId[user] = tokenId;
        metadataHash[tokenId] = metadataHash_;
        _createdAt[tokenId] = uint64(block.timestamp);

        _safeMint(user, tokenId);

        emit IdentityMinted(user, tokenId, metadataHash_);
        emit Locked(tokenId); // ERC-5192: emitted at mint, token is permanently locked
    }

    /// @notice Update the off-chain profile pointer. Only the identity owner.
    function updateMetadata(uint256 tokenId, bytes32 newHash) external whenNotPaused {
        if (!_exists(tokenId)) revert DoesNotExist();
        if (ownerOf(tokenId) != msg.sender) revert NotIdentityOwner();
        metadataHash[tokenId] = newHash;
        emit MetadataUpdated(tokenId, newHash);
    }

    // ----------------------------------------------------------------
    // Views (ICreditIdentity)
    // ----------------------------------------------------------------

    /// @inheritdoc ICreditIdentity
    function tokenIdOf(address user) external view returns (uint256) {
        return _addressToTokenId[user];
    }

    /// @inheritdoc ICreditIdentity
    function ownerOfIdentity(uint256 tokenId) external view returns (address) {
        return _ownerOf(tokenId);
    }

    /// @inheritdoc ICreditIdentity
    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }

    /// @inheritdoc ICreditIdentity
    function createdAt(uint256 tokenId) external view returns (uint64) {
        return _createdAt[tokenId];
    }

    // ----------------------------------------------------------------
    // ERC-5192
    // ----------------------------------------------------------------

    /// @inheritdoc IERC5192
    /// @dev All identities are permanently locked.
    function locked(uint256 tokenId) external view returns (bool) {
        if (!_exists(tokenId)) revert DoesNotExist();
        return true;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721)
        returns (bool)
    {
        // 0xb45a3c0e is the ERC-5192 interface id.
        return interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }

    // ----------------------------------------------------------------
    // Soulbound enforcement
    // ----------------------------------------------------------------

    /// @dev OZ v5 routes all mint/transfer/burn through _update. We allow only
    ///      mint (from == address(0)); everything else reverts.
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0)) revert IdentityNonTransferable();
        return super._update(to, tokenId, auth);
    }

    /// @dev Block approvals entirely; a soulbound token has nothing to approve.
    function approve(address, uint256) public pure override {
        revert IdentityNonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert IdentityNonTransferable();
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}
```


identity/ScoreRegistry.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";

/// @title ScoreRegistry
/// @notice The single source of truth for each identity's credit score.
/// @dev Read freely by anyone (composability is the point). Written only by an
///      address holding SCORE_UPDATER_ROLE (the ScoringOracle) or SLASHER_ROLE
///      (the CreditSlasher reducing a score on default).
contract ScoreRegistry is ProtocolBase, IScoreRegistry {
    uint16 public constant MIN_SCORE = 300;
    uint16 public constant MAX_SCORE = 1000;

    ICreditIdentity public immutable identity;

    /// @notice tokenId => current score.
    mapping(uint256 => DataTypes.Score) private _currentScore;

    /// @notice tokenId => full history of scores (append-only).
    mapping(uint256 => DataTypes.Score[]) private _scoreHistory;

    /// @notice Seconds after which a score is considered stale and should refresh.
    uint64 public stalenessThreshold;

    event ScoreUpdated(uint256 indexed tokenId, uint16 oldValue, uint16 newValue, uint8 tier);
    event StalenessThresholdSet(uint64 newThreshold);

    error InvalidScore(uint16 value);
    error InvalidTier(uint8 tier);
    error UnknownIdentity(uint256 tokenId);

    constructor(address accessController, address identity_, uint64 stalenessThreshold_)
        ProtocolBase(accessController)
    {
        if (identity_ == address(0)) revert ZeroAddress();
        identity = ICreditIdentity(identity_);
        stalenessThreshold = stalenessThreshold_;
    }

    // ----------------------------------------------------------------
    // Writes
    // ----------------------------------------------------------------

    /// @inheritdoc IScoreRegistry
    /// @dev Callable by SCORE_UPDATER_ROLE (oracle) or SLASHER_ROLE (slasher).
    function updateScore(uint256 tokenId, uint16 value, uint8 tier, bytes32 reasonHash)
        external
        whenNotPaused
    {
        if (
            !_hasRole(Roles.SCORE_UPDATER_ROLE, msg.sender)
                && !_hasRole(Roles.SLASHER_ROLE, msg.sender)
        ) {
            revert Unauthorized(Roles.SCORE_UPDATER_ROLE, msg.sender);
        }
        if (!identity.exists(tokenId)) revert UnknownIdentity(tokenId);
        if (value < MIN_SCORE || value > MAX_SCORE) revert InvalidScore(value);
        if (tier < 1 || tier > 5) revert InvalidTier(tier);

        uint16 oldValue = _currentScore[tokenId].value;

        DataTypes.Score memory s = DataTypes.Score({
            value: value,
            timestamp: uint64(block.timestamp),
            tier: tier,
            reasonHash: reasonHash
        });

        _currentScore[tokenId] = s;
        _scoreHistory[tokenId].push(s);

        emit ScoreUpdated(tokenId, oldValue, value, tier);
    }

    /// @notice Update the staleness threshold. CONFIG_ROLE only.
    function setStalenessThreshold(uint64 newThreshold) external onlyRole(Roles.CONFIG_ROLE) {
        stalenessThreshold = newThreshold;
        emit StalenessThresholdSet(newThreshold);
    }

    // ----------------------------------------------------------------
    // Reads
    // ----------------------------------------------------------------

    /// @inheritdoc IScoreRegistry
    function getScore(uint256 tokenId)
        external
        view
        returns (uint16 value, uint8 tier, bool isStale)
    {
        DataTypes.Score memory s = _currentScore[tokenId];
        value = s.value;
        tier = s.tier;
        isStale = s.timestamp == 0
            || (stalenessThreshold != 0 && block.timestamp > s.timestamp + stalenessThreshold);
    }

    /// @inheritdoc IScoreRegistry
    function getScoreStruct(uint256 tokenId) external view returns (DataTypes.Score memory) {
        return _currentScore[tokenId];
    }

    /// @inheritdoc IScoreRegistry
    /// @dev Returns the score that was current at-or-before `timestamp`.
    function getScoreAt(uint256 tokenId, uint64 timestamp) external view returns (uint16) {
        DataTypes.Score[] storage hist = _scoreHistory[tokenId];
        uint256 len = hist.length;
        if (len == 0) return 0;
        // Walk backwards; histories are short in practice.
        for (uint256 i = len; i > 0; --i) {
            if (hist[i - 1].timestamp <= timestamp) {
                return hist[i - 1].value;
            }
        }
        return 0;
    }

    /// @inheritdoc IScoreRegistry
    function isEligible(uint256 tokenId, uint16 minScore) external view returns (bool) {
        return _currentScore[tokenId].value >= minScore;
    }

    /// @inheritdoc IScoreRegistry
    function hasScore(uint256 tokenId) external view returns (bool) {
        return _currentScore[tokenId].timestamp != 0;
    }

    /// @notice Number of historical score entries for an identity.
    function scoreHistoryLength(uint256 tokenId) external view returns (uint256) {
        return _scoreHistory[tokenId].length;
    }
}
```


interfaces/IAccessController.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAccessController
/// @notice Minimal interface to the central role registry. Other contracts call
///         `hasRole` to gate functions against protocol-wide roles.
interface IAccessController {
    function hasRole(bytes32 role, address account) external view returns (bool);

    function isPaused() external view returns (bool);
}
```


interfaces/ICreditIdentity.sol
```
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
```


interfaces/ILending.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

/// @title ILendingPool
/// @notice Capital pool that funds loans. Only the LoanManager can draw/return funds.
interface ILendingPool {
    function borrowFor(address borrower, uint256 amount, uint256 loanId) external;

    function repayFor(uint256 loanId, uint256 principal, uint256 interest) external;

    function coverLoss(uint256 loanId, uint256 amount) external;

    function totalSupplied() external view returns (uint256);

    function totalBorrowed() external view returns (uint256);

    function availableLiquidity() external view returns (uint256);

    function utilizationRate() external view returns (uint256);
}

/// @title ILoanManager
/// @notice Originates and tracks loans.
interface ILoanManager {
    function originate(uint256 tokenId, uint256 amount, uint64 termDays) external returns (uint256 loanId);

    function repay(uint256 loanId, uint256 amount) external;

    function markLate(uint256 loanId) external;

    function markDefault(uint256 loanId) external;

    function getLoan(uint256 loanId) external view returns (DataTypes.Loan memory);

    function getBorrowerLoans(uint256 tokenId) external view returns (uint256[] memory);

    function computeOutstanding(uint256 loanId) external view returns (uint256);

    function totalActiveExposure(uint256 tokenId) external view returns (uint256);
}

/// @title ICreditLimitEngine
/// @notice Computes a borrower's maximum credit line.
interface ICreditLimitEngine {
    function availableCredit(uint256 tokenId)
        external
        view
        returns (uint256 limit, uint256 currentExposure, uint256 headroom);

    function maxLimit(uint256 tokenId) external view returns (uint256);
}

/// @title IInterestRateModel
/// @notice Maps risk tier and utilization to interest rates.
interface IInterestRateModel {
    function borrowAPR(uint8 tier, uint256 utilizationBps) external view returns (uint16 bps);

    function supplyAPR(uint256 utilizationBps, uint256 reserveFactorBps) external view returns (uint16 bps);
}

/// @title IRepaymentGraduation
/// @notice Tracks repayment streaks and derives the borrower's tier.
interface IRepaymentGraduation {
    function recordRepayment(uint256 tokenId, bool onTime) external;

    function recordDefault(uint256 tokenId) external;

    function currentTier(uint256 tokenId) external view returns (uint8);

    function consecutiveOnTime(uint256 tokenId) external view returns (uint16);
}
```


interfaces/IProtocol.sol
```
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
```


interfaces/IScoreRegistry.sol
```
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
```


lending/CreditLimitEngine.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {ICreditLimitEngine, ILoanManager, IRepaymentGraduation} from "../interfaces/ILending.sol";
import {ISocialAttestation} from "../interfaces/IProtocol.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";

/// @title CreditLimitEngine
/// @notice Computes a borrower's maximum credit line from their tier base limit
///         plus a capped social-attestation bonus, then subtracts active loan
///         exposure to yield available headroom.
/// @dev View-only aggregator. Holds no funds and no per-user state beyond config.
contract CreditLimitEngine is ProtocolBase, ICreditLimitEngine {
    IScoreRegistry public immutable scoreRegistry;
    IRepaymentGraduation public immutable graduation;
    ISocialAttestation public immutable attestation;

    /// @notice LoanManager is set post-deploy to break the circular dependency
    ///         (LoanManager also needs the engine).
    ILoanManager public loanManager;

    /// @notice Base credit limit per tier (USDC, 6 decimals). Index tier-1.
    ///         Defaults: $20, $50, $150, $500, $2000.
    uint256[5] public tierBaseLimit;

    /// @notice Attestation bonus is capped at this multiple of the base limit
    ///         (bps). 20000 = 2x base limit.
    uint16 public attestationCapBps;

    /// @notice Minimum score required to borrow at all.
    uint16 public minBorrowScore;

    event LoanManagerSet(address loanManager);
    event TierBaseLimitsSet(uint256[5] limits);
    event AttestationCapSet(uint16 bps);
    event MinBorrowScoreSet(uint16 score);

    constructor(
        address accessController,
        address scoreRegistry_,
        address graduation_,
        address attestation_
    ) ProtocolBase(accessController) {
        if (scoreRegistry_ == address(0) || graduation_ == address(0) || attestation_ == address(0)) {
            revert ZeroAddress();
        }
        scoreRegistry = IScoreRegistry(scoreRegistry_);
        graduation = IRepaymentGraduation(graduation_);
        attestation = ISocialAttestation(attestation_);

        tierBaseLimit = [20e6, 50e6, 150e6, 500e6, 2000e6];
        attestationCapBps = 20000; // 2x
        minBorrowScore = 300; // any scored user; tighten in config if needed
    }

    /// @notice Wire the LoanManager after deployment. CONFIG_ROLE only.
    function setLoanManager(address loanManager_) external onlyRole(Roles.CONFIG_ROLE) {
        if (loanManager_ == address(0)) revert ZeroAddress();
        loanManager = ILoanManager(loanManager_);
        emit LoanManagerSet(loanManager_);
    }

    // ----------------------------------------------------------------
    // Limit math
    // ----------------------------------------------------------------

    /// @inheritdoc ICreditLimitEngine
    function maxLimit(uint256 tokenId) public view returns (uint256) {
        // No score => no credit.
        if (!scoreRegistry.hasScore(tokenId)) return 0;
        (uint16 value,,) = scoreRegistry.getScore(tokenId);
        if (value < minBorrowScore) return 0;

        uint8 tier = graduation.currentTier(tokenId);
        if (tier < 1) tier = 1;
        if (tier > 5) tier = 5;

        uint256 base = tierBaseLimit[tier - 1];

        uint256 bonus = attestation.totalWeight(tokenId);
        uint256 bonusCap = (base * attestationCapBps) / 1e4;
        if (bonus > bonusCap) bonus = bonusCap;

        return base + bonus;
    }

    /// @inheritdoc ICreditLimitEngine
    function availableCredit(uint256 tokenId)
        external
        view
        returns (uint256 limit, uint256 currentExposure, uint256 headroom)
    {
        limit = maxLimit(tokenId);
        currentExposure = address(loanManager) == address(0)
            ? 0
            : loanManager.totalActiveExposure(tokenId);
        headroom = limit > currentExposure ? limit - currentExposure : 0;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setTierBaseLimits(uint256[5] calldata limits) external onlyRole(Roles.CONFIG_ROLE) {
        tierBaseLimit = limits;
        emit TierBaseLimitsSet(limits);
    }

    function setAttestationCap(uint16 bps) external onlyRole(Roles.CONFIG_ROLE) {
        attestationCapBps = bps;
        emit AttestationCapSet(bps);
    }

    function setMinBorrowScore(uint16 score) external onlyRole(Roles.CONFIG_ROLE) {
        minBorrowScore = score;
        emit MinBorrowScoreSet(score);
    }
}
```


lending/InterestRateModel.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {IInterestRateModel} from "../interfaces/ILending.sol";

/// @title InterestRateModel
/// @notice Maps borrower risk tier and pool utilization to an APR using an
///         Aave-style two-slope ("kinked") curve. Lower tiers (riskier) pay more.
/// @dev All rates in basis points. Utilization in basis points (10000 = 100%).
contract InterestRateModel is ProtocolBase, IInterestRateModel {
    struct TierCurve {
        uint16 baseRateBps; // APR at 0% utilization
        uint16 slope1Bps; // added APR per 100% util, below the kink
        uint16 slope2Bps; // added APR per 100% util, above the kink
    }

    /// @notice Utilization at which slope2 kicks in (bps). e.g. 8000 = 80%.
    uint16 public kinkBps;

    /// @notice tier (1..5) => curve. Index by tier-1.
    TierCurve[5] public curves;

    event KinkSet(uint16 kinkBps);
    event CurveSet(uint8 tier, uint16 baseRateBps, uint16 slope1Bps, uint16 slope2Bps);

    error InvalidTier(uint8 tier);

    constructor(address accessController) ProtocolBase(accessController) {
        kinkBps = 8000; // 80%
        // tier1 (new/riskiest) ... tier5 (graduate)
        curves[0] = TierCurve({baseRateBps: 4000, slope1Bps: 1000, slope2Bps: 12000});
        curves[1] = TierCurve({baseRateBps: 3000, slope1Bps: 800, slope2Bps: 10000});
        curves[2] = TierCurve({baseRateBps: 2200, slope1Bps: 600, slope2Bps: 8000});
        curves[3] = TierCurve({baseRateBps: 1500, slope1Bps: 500, slope2Bps: 6000});
        curves[4] = TierCurve({baseRateBps: 1000, slope1Bps: 400, slope2Bps: 5000});
    }

    /// @inheritdoc IInterestRateModel
    function borrowAPR(uint8 tier, uint256 utilizationBps) external view returns (uint16 bps) {
        if (tier < 1 || tier > 5) revert InvalidTier(tier);
        TierCurve memory c = curves[tier - 1];

        uint256 util = utilizationBps > 1e4 ? 1e4 : utilizationBps;
        uint256 rate;
        if (util <= kinkBps) {
            // base + slope1 * (util / kink)
            rate = c.baseRateBps + (uint256(c.slope1Bps) * util) / kinkBps;
        } else {
            uint256 excess = util - kinkBps;
            uint256 denom = 1e4 - kinkBps;
            rate = c.baseRateBps + c.slope1Bps + (uint256(c.slope2Bps) * excess) / denom;
        }
        // Cap to uint16 range defensively.
        if (rate > type(uint16).max) rate = type(uint16).max;
        bps = uint16(rate);
    }

    /// @inheritdoc IInterestRateModel
    /// @notice Supply APR = borrow APR (blended) * utilization * (1 - reserveFactor).
    /// @dev For MVP we approximate blended borrow rate using the tier-3 curve as
    ///      a midpoint; the LendingPool tracks the true weighted rate separately
    ///      if it needs precision. This view is informational for suppliers.
    function supplyAPR(uint256 utilizationBps, uint256 reserveFactorBps)
        external
        view
        returns (uint16 bps)
    {
        uint256 util = utilizationBps > 1e4 ? 1e4 : utilizationBps;
        TierCurve memory c = curves[2]; // tier-3 midpoint
        uint256 borrowRate;
        if (util <= kinkBps) {
            borrowRate = c.baseRateBps + (uint256(c.slope1Bps) * util) / kinkBps;
        } else {
            uint256 excess = util - kinkBps;
            uint256 denom = 1e4 - kinkBps;
            borrowRate = c.baseRateBps + c.slope1Bps + (uint256(c.slope2Bps) * excess) / denom;
        }
        uint256 rf = reserveFactorBps > 1e4 ? 1e4 : reserveFactorBps;
        uint256 supply = (borrowRate * util * (1e4 - rf)) / (1e4 * 1e4);
        if (supply > type(uint16).max) supply = type(uint16).max;
        bps = uint16(supply);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setKink(uint16 kinkBps_) external onlyRole(Roles.CONFIG_ROLE) {
        require(kinkBps_ > 0 && kinkBps_ < 1e4, "IRM: bad kink");
        kinkBps = kinkBps_;
        emit KinkSet(kinkBps_);
    }

    function setCurve(uint8 tier, uint16 baseRateBps, uint16 slope1Bps, uint16 slope2Bps)
        external
        onlyRole(Roles.CONFIG_ROLE)
    {
        if (tier < 1 || tier > 5) revert InvalidTier(tier);
        curves[tier - 1] = TierCurve(baseRateBps, slope1Bps, slope2Bps);
        emit CurveSet(tier, baseRateBps, slope1Bps, slope2Bps);
    }
}
```


lending/LendingPool.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {ILendingPool} from "../interfaces/ILending.sol";

/// @title LendingPool
/// @notice ERC-4626 vault of USDC that funds undercollateralized loans. Suppliers
///         deposit USDC and receive cgUSDC shares that appreciate as interest is
///         repaid. Only the LoanManager may draw funds (`borrowFor`) and return
///         them (`repayFor`). Defaults reduce total assets, socializing losses
///         across suppliers after the InsuranceFund is exhausted.
/// @dev totalAssets = idle USDC held + outstanding borrowed principal. Interest
///      paid in flows as idle USDC, raising the share price.
contract LendingPool is ERC4626, ProtocolBase, ILendingPool, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Outstanding borrowed principal currently out on loan.
    uint256 private _totalBorrowed;

    /// @notice Cumulative interest received (informational).
    uint256 public cumulativeInterest;

    /// @notice Cumulative losses realized from defaults (informational).
    uint256 public cumulativeLosses;

    /// @notice Optional cap on total deposits (0 = uncapped). Useful for a
    ///         controlled hackathon demo.
    uint256 public supplyCap;

    event Borrowed(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event Repaid(uint256 indexed loanId, uint256 principal, uint256 interest);
    event LossCovered(uint256 indexed loanId, uint256 amount);
    event SupplyCapSet(uint256 cap);

    error OnlyLoanManager();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error SupplyCapExceeded();

    constructor(address accessController, IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        ProtocolBase(accessController)
    {}

    // ----------------------------------------------------------------
    // ERC-4626 accounting overrides
    // ----------------------------------------------------------------

    /// @inheritdoc ERC4626
    /// @dev Total assets = idle balance + principal out on loan.
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _totalBorrowed;
    }

    /// @dev Enforce optional supply cap on deposit/mint.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        if (supplyCap != 0 && totalAssets() + assets > supplyCap) revert SupplyCapExceeded();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Withdrawals can only draw on idle liquidity, not principal on loan.
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused nonReentrant {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) revert InsufficientLiquidity(assets, idle);
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ----------------------------------------------------------------
    // Lending hooks (LoanManager only)
    // ----------------------------------------------------------------

    modifier onlyLoanManager() {
        if (!_hasRole(Roles.POOL_MANAGER_ROLE, msg.sender)) revert OnlyLoanManager();
        _;
    }

    /// @inheritdoc ILendingPool
    function borrowFor(address borrower, uint256 amount, uint256 loanId)
        external
        onlyLoanManager
        whenNotPaused
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (amount > idle) revert InsufficientLiquidity(amount, idle);

        _totalBorrowed += amount;
        IERC20(asset()).safeTransfer(borrower, amount);

        emit Borrowed(loanId, borrower, amount);
    }

    /// @inheritdoc ILendingPool
    /// @dev LoanManager must have already pulled `principal + interest` from the
    ///      payer into this contract before calling (or it transfers in here).
    ///      We pull from the LoanManager to keep token custody explicit.
    function repayFor(uint256 loanId, uint256 principal, uint256 interest)
        external
        onlyLoanManager
        nonReentrant
    {
        // Move funds in from the LoanManager (which collected from the borrower).
        uint256 total = principal + interest;
        if (total > 0) IERC20(asset()).safeTransferFrom(msg.sender, address(this), total);

        if (principal > _totalBorrowed) {
            _totalBorrowed = 0;
        } else {
            _totalBorrowed -= principal;
        }
        cumulativeInterest += interest;

        emit Repaid(loanId, principal, interest);
    }

    /// @inheritdoc ILendingPool
    /// @notice Realize a loss when a default is not fully covered by insurance.
    ///         Reduces tracked principal; the asset shortfall lowers share price.
    function coverLoss(uint256 loanId, uint256 amount) external onlyLoanManager nonReentrant {
        if (amount > _totalBorrowed) {
            _totalBorrowed = 0;
        } else {
            _totalBorrowed -= amount;
        }
        cumulativeLosses += amount;
        emit LossCovered(loanId, amount);
    }

    // ----------------------------------------------------------------
    // Views (ILendingPool)
    // ----------------------------------------------------------------

    function totalSupplied() external view returns (uint256) {
        return totalAssets();
    }

    function totalBorrowed() external view returns (uint256) {
        return _totalBorrowed;
    }

    function availableLiquidity() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /// @inheritdoc ILendingPool
    /// @notice Utilization in basis points (borrowed / total assets).
    function utilizationRate() external view returns (uint256) {
        uint256 ta = totalAssets();
        if (ta == 0) return 0;
        return (_totalBorrowed * 1e4) / ta;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setSupplyCap(uint256 cap) external onlyRole(Roles.CONFIG_ROLE) {
        supplyCap = cap;
        emit SupplyCapSet(cap);
    }

    /// @dev Resolve decimals ambiguity between ERC4626 and our ERC20 base.
    function decimals() public view override(ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}
```


lending/LoanManager.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {
    ILoanManager,
    ILendingPool,
    ICreditLimitEngine,
    IInterestRateModel,
    IRepaymentGraduation
} from "../interfaces/ILending.sol";
import {ICreditSlasher} from "../interfaces/IProtocol.sol";
import {ICreditIdentity} from "../interfaces/ICreditIdentity.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";

/// @title LoanManager
/// @notice Core loan lifecycle contract. Originates loans against a borrower's
///         available credit, accrues simple interest pro-rata over time, accepts
///         repayments, and routes defaults to the CreditSlasher.
/// @dev Interest is simple (non-compounding) over the loan term, accrued linearly:
///        interest(t) = principal * aprBps/1e4 * elapsed / 365days
///      Token custody: on repay, this contract pulls USDC from the payer, then
///      pushes principal+interest into the LendingPool via repayFor.
contract LoanManager is ProtocolBase, ILoanManager, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant YEAR = 365 days;
    uint256 private constant BPS = 1e4;

    IERC20 public immutable asset; // USDC
    ICreditIdentity public immutable identity;
    IScoreRegistry public immutable scoreRegistry;
    ILendingPool public immutable pool;
    ICreditLimitEngine public immutable limitEngine;
    IInterestRateModel public immutable rateModel;
    IRepaymentGraduation public immutable graduation;

    /// @notice Set post-deploy (slasher needs LoanManager address too).
    ICreditSlasher public slasher;

    /// @notice loanId => loan.
    mapping(uint256 => DataTypes.Loan) private _loans;
    /// @notice tokenId => loanIds.
    mapping(uint256 => uint256[]) private _borrowerLoans;

    uint256 public nextLoanId = 1;

    /// @notice Grace period after due date before a loan can be defaulted.
    uint64 public gracePeriod;

    /// @notice Min and max term in days for new loans.
    uint64 public minTermDays;
    uint64 public maxTermDays;

    event LoanOriginated(
        uint256 indexed loanId, uint256 indexed tokenId, uint256 amount, uint16 aprBps, uint64 dueAt
    );
    event LoanRepaid(uint256 indexed loanId, uint256 principalPaid, uint256 interestPaid, bool fullyRepaid);
    event LoanMarkedLate(uint256 indexed loanId);
    event LoanDefaulted(uint256 indexed loanId, uint256 outstanding);
    event SlasherSet(address slasher);
    event GracePeriodSet(uint64 gracePeriod);
    event TermBoundsSet(uint64 minTermDays, uint64 maxTermDays);

    error NotBorrower();
    error NoIdentity();
    error ScoreStaleOrMissing();
    error ExceedsHeadroom(uint256 requested, uint256 headroom);
    error InvalidTerm(uint64 termDays);
    error LoanNotActive(uint256 loanId);
    error NotYetDue(uint64 dueAt);
    error GraceNotElapsed(uint64 defaultableAt);
    error ZeroAmount();
    error SlasherNotSet();

    constructor(
        address accessController,
        address asset_,
        address identity_,
        address scoreRegistry_,
        address pool_,
        address limitEngine_,
        address rateModel_,
        address graduation_
    ) ProtocolBase(accessController) {
        if (
            asset_ == address(0) || identity_ == address(0) || scoreRegistry_ == address(0)
                || pool_ == address(0) || limitEngine_ == address(0) || rateModel_ == address(0)
                || graduation_ == address(0)
        ) revert ZeroAddress();

        asset = IERC20(asset_);
        identity = ICreditIdentity(identity_);
        scoreRegistry = IScoreRegistry(scoreRegistry_);
        pool = ILendingPool(pool_);
        limitEngine = ICreditLimitEngine(limitEngine_);
        rateModel = IInterestRateModel(rateModel_);
        graduation = IRepaymentGraduation(graduation_);

        gracePeriod = 7 days;
        minTermDays = 1;
        maxTermDays = 365;
    }

    // ----------------------------------------------------------------
    // Origination
    // ----------------------------------------------------------------

    /// @inheritdoc ILoanManager
    function originate(uint256 tokenId, uint256 amount, uint64 termDays)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 loanId)
    {
        if (amount == 0) revert ZeroAmount();
        if (termDays < minTermDays || termDays > maxTermDays) revert InvalidTerm(termDays);

        // Caller must own the identity they're borrowing against.
        if (identity.ownerOfIdentity(tokenId) != msg.sender) revert NotBorrower();

        // Require a fresh, present score.
        (uint16 value,, bool isStale) = scoreRegistry.getScore(tokenId);
        if (value == 0 || isStale) revert ScoreStaleOrMissing();

        // Check available headroom.
        (,, uint256 headroom) = limitEngine.availableCredit(tokenId);
        if (amount > headroom) revert ExceedsHeadroom(amount, headroom);

        // Price the loan against the borrower's current tier and pool utilization.
        uint8 tier = graduation.currentTier(tokenId);
        if (tier < 1) tier = 1;
        if (tier > 5) tier = 5;
        uint256 util = pool.utilizationRate();
        uint16 aprBps = rateModel.borrowAPR(tier, util);

        loanId = nextLoanId++;
        uint64 nowTs = uint64(block.timestamp);
        uint64 dueAt = nowTs + uint64(termDays) * 1 days;

        _loans[loanId] = DataTypes.Loan({
            tokenId: tokenId,
            principal: amount,
            outstanding: amount,
            interestPaid: 0,
            originatedAt: nowTs,
            dueAt: dueAt,
            lastAccrual: nowTs,
            aprBps: aprBps,
            state: DataTypes.LoanState.Active
        });
        _borrowerLoans[tokenId].push(loanId);

        // Pool sends USDC directly to the borrower (msg.sender == identity owner).
        pool.borrowFor(msg.sender, amount, loanId);

        emit LoanOriginated(loanId, tokenId, amount, aprBps, dueAt);
    }

    // ----------------------------------------------------------------
    // Repayment
    // ----------------------------------------------------------------

    /// @inheritdoc ILoanManager
    /// @notice Repay up to the full outstanding + accrued interest. Anyone may pay
    ///         on behalf of a borrower (e.g. a family member or attester).
    /// @dev Interest is paid first, then principal. Token flow: payer -> this ->
    ///      pool. The payer must have approved this contract for `amount`.
    function repay(uint256 loanId, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        DataTypes.Loan storage loan = _loans[loanId];
        if (loan.state != DataTypes.LoanState.Active && loan.state != DataTypes.LoanState.Late) {
            revert LoanNotActive(loanId);
        }

        uint256 accrued = _accruedInterest(loan);
        uint256 owed = loan.outstanding + accrued;
        uint256 pay = amount > owed ? owed : amount;

        // Split payment into interest-first, then principal.
        uint256 interestPortion = pay > accrued ? accrued : pay;
        uint256 principalPortion = pay - interestPortion;

        // Pull funds from payer.
        asset.safeTransferFrom(msg.sender, address(this), pay);
        // Approve & push into the pool.
        asset.forceApprove(address(pool), pay);
        pool.repayFor(loanId, principalPortion, interestPortion);

        // Update loan state.
        loan.outstanding -= principalPortion;
        loan.interestPaid += interestPortion;
        loan.lastAccrual = uint64(block.timestamp);

        bool fullyRepaid = loan.outstanding == 0;
        if (fullyRepaid) {
            bool onTime = block.timestamp <= loan.dueAt;
            loan.state = DataTypes.LoanState.Repaid;
            graduation.recordRepayment(loan.tokenId, onTime);
        }

        emit LoanRepaid(loanId, principalPortion, interestPortion, fullyRepaid);
    }

    // ----------------------------------------------------------------
    // Delinquency
    // ----------------------------------------------------------------

    /// @inheritdoc ILoanManager
    /// @notice Flag a past-due loan as late. Permissionless poke.
    function markLate(uint256 loanId) external whenNotPaused {
        DataTypes.Loan storage loan = _loans[loanId];
        if (loan.state != DataTypes.LoanState.Active) revert LoanNotActive(loanId);
        if (block.timestamp <= loan.dueAt) revert NotYetDue(loan.dueAt);
        loan.state = DataTypes.LoanState.Late;
        emit LoanMarkedLate(loanId);
    }

    /// @inheritdoc ILoanManager
    /// @notice Default a loan past its grace period and trigger slashing.
    function markDefault(uint256 loanId) external whenNotPaused nonReentrant {
        if (address(slasher) == address(0)) revert SlasherNotSet();
        DataTypes.Loan storage loan = _loans[loanId];
        if (loan.state != DataTypes.LoanState.Active && loan.state != DataTypes.LoanState.Late) {
            revert LoanNotActive(loanId);
        }
        uint64 defaultableAt = loan.dueAt + gracePeriod;
        if (block.timestamp < defaultableAt) revert GraceNotElapsed(defaultableAt);

        // The protocol's realized loss is the outstanding principal. Accrued
        // interest was never received, so it is not a real asset shortfall and
        // is excluded from the coverage/slashing target to keep accounting
        // consistent with what coverLoss writes down.
        uint256 lossPrincipal = loan.outstanding;

        loan.state = DataTypes.LoanState.Defaulted;
        loan.lastAccrual = uint64(block.timestamp);

        // Record default in graduation (demotes tier).
        graduation.recordDefault(loan.tokenId);

        // Realize the principal loss in the pool (writes down tracked principal).
        pool.coverLoss(loanId, lossPrincipal);

        // Hand off to the slasher: reduce score, slash attesters, tap insurance
        // to make the pool whole on the principal loss.
        slasher.processDefault(loanId, loan.tokenId, lossPrincipal);

        emit LoanDefaulted(loanId, lossPrincipal);
    }

    // ----------------------------------------------------------------
    // Interest math
    // ----------------------------------------------------------------

    /// @dev Simple interest accrued since lastAccrual on the outstanding principal.
    function _accruedInterest(DataTypes.Loan storage loan) internal view returns (uint256) {
        if (loan.outstanding == 0) return 0;
        uint256 elapsed = block.timestamp - loan.lastAccrual;
        if (elapsed == 0) return 0;
        return (loan.outstanding * loan.aprBps * elapsed) / (BPS * YEAR);
    }

    // ----------------------------------------------------------------
    // Views (ILoanManager)
    // ----------------------------------------------------------------

    function getLoan(uint256 loanId) external view returns (DataTypes.Loan memory) {
        return _loans[loanId];
    }

    function getBorrowerLoans(uint256 tokenId) external view returns (uint256[] memory) {
        return _borrowerLoans[tokenId];
    }

    /// @inheritdoc ILoanManager
    /// @notice Outstanding principal plus accrued (unpaid) interest.
    function computeOutstanding(uint256 loanId) external view returns (uint256) {
        DataTypes.Loan storage loan = _loans[loanId];
        return loan.outstanding + _accruedInterest(loan);
    }

    /// @inheritdoc ILoanManager
    /// @notice Sum of outstanding principal across a borrower's active/late loans.
    /// @dev Exposure is principal-only (matches how the limit is denominated).
    function totalActiveExposure(uint256 tokenId) external view returns (uint256 exposure) {
        uint256[] storage ids = _borrowerLoans[tokenId];
        for (uint256 i; i < ids.length; ++i) {
            DataTypes.Loan storage loan = _loans[ids[i]];
            if (loan.state == DataTypes.LoanState.Active || loan.state == DataTypes.LoanState.Late) {
                exposure += loan.outstanding;
            }
        }
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setSlasher(address slasher_) external onlyRole(Roles.CONFIG_ROLE) {
        if (slasher_ == address(0)) revert ZeroAddress();
        slasher = ICreditSlasher(slasher_);
        emit SlasherSet(slasher_);
    }

    function setGracePeriod(uint64 gracePeriod_) external onlyRole(Roles.CONFIG_ROLE) {
        gracePeriod = gracePeriod_;
        emit GracePeriodSet(gracePeriod_);
    }

    function setTermBounds(uint64 minTermDays_, uint64 maxTermDays_) external onlyRole(Roles.CONFIG_ROLE) {
        require(minTermDays_ > 0 && minTermDays_ <= maxTermDays_, "LM: bad term bounds");
        minTermDays = minTermDays_;
        maxTermDays = maxTermDays_;
        emit TermBoundsSet(minTermDays_, maxTermDays_);
    }
}
```


lending/RepaymentGraduation.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {IRepaymentGraduation} from "../interfaces/ILending.sol";

/// @title RepaymentGraduation
/// @notice Tracks each borrower's repayment streak and derives a credit tier.
///         On-time repayments advance the streak and can promote a tier; defaults
///         reset progress and demote. This is the on-chain "graduation path" that
///         lets a reliable borrower climb from micro-loans to the full stack.
/// @dev `recordRepayment` / `recordDefault` are gated to POOL_MANAGER_ROLE (the
///      LoanManager). Tier is a pure function of the streak against thresholds.
contract RepaymentGraduation is ProtocolBase, IRepaymentGraduation {
    /// @notice tokenId => current consecutive on-time repayment count.
    mapping(uint256 => uint16) private _consecutiveOnTime;

    /// @notice tokenId => lifetime on-time repayments (never decreases).
    mapping(uint256 => uint32) public lifetimeOnTime;

    /// @notice tokenId => lifetime defaults.
    mapping(uint256 => uint32) public lifetimeDefaults;

    /// @notice Streak required to reach each tier index.
    ///         promotionThresholds[t] is the minimum streak for tier (t+1).
    ///         Default: tier1=0, tier2=2, tier3=5, tier4=12, tier5=24.
    uint16[5] public promotionThresholds;

    /// @notice How many tiers a default drops you (clamped at tier 1).
    uint8 public demotionTiers;

    /// @notice Floor tier after a demotion (defaulters can't go below this).
    uint8 public constant MIN_TIER = 1;
    uint8 public constant MAX_TIER = 5;

    /// @notice Explicit tier override after demotion. 0 means "derive from streak".
    mapping(uint256 => uint8) private _tierFloorOverride;

    event RepaymentRecorded(uint256 indexed tokenId, bool onTime, uint16 streak, uint8 tier);
    event DefaultRecorded(uint256 indexed tokenId, uint8 newTier);
    event TierPromoted(uint256 indexed tokenId, uint8 oldTier, uint8 newTier);
    event ThresholdsSet(uint16[5] thresholds);

    constructor(address accessController) ProtocolBase(accessController) {
        promotionThresholds = [0, 2, 5, 12, 24];
        demotionTiers = 2;
    }

    // ----------------------------------------------------------------
    // Recording (LoanManager only)
    // ----------------------------------------------------------------

    /// @inheritdoc IRepaymentGraduation
    function recordRepayment(uint256 tokenId, bool onTime)
        external
        whenNotPaused
        onlyRole(Roles.POOL_MANAGER_ROLE)
    {
        uint8 oldTier = currentTier(tokenId);

        if (onTime) {
            _consecutiveOnTime[tokenId] += 1;
            lifetimeOnTime[tokenId] += 1;
            // A clean repayment lifts any demotion floor once the streak recovers.
            if (_tierFloorOverride[tokenId] != 0) {
                uint8 derived = _deriveTierFromStreak(_consecutiveOnTime[tokenId]);
                if (derived >= _tierFloorOverride[tokenId]) {
                    _tierFloorOverride[tokenId] = 0;
                }
            }
        } else {
            // Late-but-not-defaulted: streak resets, no demotion floor.
            _consecutiveOnTime[tokenId] = 0;
        }

        uint8 newTier = currentTier(tokenId);
        emit RepaymentRecorded(tokenId, onTime, _consecutiveOnTime[tokenId], newTier);
        if (newTier > oldTier) emit TierPromoted(tokenId, oldTier, newTier);
    }

    /// @inheritdoc IRepaymentGraduation
    function recordDefault(uint256 tokenId)
        external
        whenNotPaused
        onlyRole(Roles.POOL_MANAGER_ROLE)
    {
        lifetimeDefaults[tokenId] += 1;

        uint8 tierNow = currentTier(tokenId);
        uint8 demoted = tierNow > demotionTiers ? tierNow - demotionTiers : MIN_TIER;
        if (demoted < MIN_TIER) demoted = MIN_TIER;

        _consecutiveOnTime[tokenId] = 0;
        _tierFloorOverride[tokenId] = demoted;

        emit DefaultRecorded(tokenId, demoted);
    }

    // ----------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------

    /// @inheritdoc IRepaymentGraduation
    function currentTier(uint256 tokenId) public view returns (uint8) {
        uint8 floorTier = _tierFloorOverride[tokenId];
        uint8 derived = _deriveTierFromStreak(_consecutiveOnTime[tokenId]);
        // After a default the borrower is capped at the demotion floor until the
        // streak rebuilds past it (handled in recordRepayment).
        if (floorTier != 0 && derived > floorTier) return floorTier;
        return derived;
    }

    /// @inheritdoc IRepaymentGraduation
    function consecutiveOnTime(uint256 tokenId) external view returns (uint16) {
        return _consecutiveOnTime[tokenId];
    }

    function _deriveTierFromStreak(uint16 streak) internal view returns (uint8) {
        uint8 tier = MIN_TIER;
        // Highest tier whose threshold the streak meets.
        for (uint8 t = MAX_TIER; t >= 1; --t) {
            if (streak >= promotionThresholds[t - 1]) {
                tier = t;
                break;
            }
            if (t == 1) break; // prevent uint8 underflow
        }
        return tier;
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setThresholds(uint16[5] calldata thresholds) external onlyRole(Roles.CONFIG_ROLE) {
        promotionThresholds = thresholds;
        emit ThresholdsSet(thresholds);
    }

    function setDemotionTiers(uint8 tiers) external onlyRole(Roles.CONFIG_ROLE) {
        demotionTiers = tiers;
    }
}
```


libraries/DataTypes.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DataTypes
/// @notice Shared structs and enums used across the CreditGraph protocol.
/// @dev Centralizing these prevents type drift between contracts that must agree
///      on layouts (e.g. LoanManager <-> CreditSlasher).
library DataTypes {
    // ----------------------------------------------------------------
    // Scoring
    // ----------------------------------------------------------------

    /// @notice A credit score snapshot for an identity.
    /// @param value   Score in the range [300, 1000].
    /// @param timestamp When the score was written.
    /// @param tier    Derived credit tier [1, 5].
    /// @param reasonHash IPFS CID (as bytes32) pointing to a human-readable breakdown.
    struct Score {
        uint16 value;
        uint64 timestamp;
        uint8 tier;
        bytes32 reasonHash;
    }

    // ----------------------------------------------------------------
    // Lending
    // ----------------------------------------------------------------

    enum LoanState {
        None, // 0 - default value, loan does not exist
        Active, // 1
        Repaid, // 2
        Late, // 3
        Defaulted // 4
    }

    /// @notice A single loan position.
    /// @param tokenId      Borrower's CreditIdentity token id.
    /// @param principal    Original borrowed amount (USDC, 6 decimals).
    /// @param outstanding  Remaining principal owed (interest computed separately).
    /// @param interestPaid Cumulative interest paid to date.
    /// @param originatedAt Origination timestamp.
    /// @param dueAt        Repayment deadline.
    /// @param lastAccrual  Last time interest was accrued for this loan.
    /// @param aprBps       Fixed APR for the life of this loan, in basis points.
    /// @param state        Current loan lifecycle state.
    struct Loan {
        uint256 tokenId;
        uint256 principal;
        uint256 outstanding;
        uint256 interestPaid;
        uint64 originatedAt;
        uint64 dueAt;
        uint64 lastAccrual;
        uint16 aprBps;
        LoanState state;
    }

    // ----------------------------------------------------------------
    // Social Attestation
    // ----------------------------------------------------------------

    /// @notice An on-chain vouch from one identity for another, backed by a bond.
    /// @param attesterTokenId Identity making the attestation.
    /// @param subjectTokenId  Identity being vouched for.
    /// @param bondAmount      USDC staked behind the vouch.
    /// @param createdAt       Creation timestamp.
    /// @param expiresAt       Expiry timestamp; weight decays as this approaches.
    /// @param active          Whether the attestation is currently live.
    /// @param relationshipType Categorical tag (e.g. keccak256("AJO")).
    struct Attestation {
        uint256 attesterTokenId;
        uint256 subjectTokenId;
        uint256 bondAmount;
        uint64 createdAt;
        uint64 expiresAt;
        bool active;
        bytes32 relationshipType;
    }

    // ----------------------------------------------------------------
    // Agents
    // ----------------------------------------------------------------

    enum AgentRole {
        None, // 0
        DataCollector, // 1
        Underwriter, // 2
        PoolManager, // 3
        Recovery // 4
    }
}
```


libraries/Roles.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Roles
/// @notice Canonical role identifiers shared across the protocol.
/// @dev DEFAULT_ADMIN_ROLE is 0x00 and lives in OpenZeppelin's AccessControl.
library Roles {
    /// @notice Can pause/unpause all pausable contracts in an emergency.
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Held by ScoringOracle; allowed to write into ScoreRegistry.
    bytes32 internal constant SCORE_UPDATER_ROLE = keccak256("SCORE_UPDATER_ROLE");

    /// @notice Held by CreditSlasher; allowed to reduce scores and slash bonds.
    bytes32 internal constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    /// @notice Held by LoanManager; allowed to draw/return funds from LendingPool
    ///         and to record repayment/graduation events.
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    /// @notice Held by addresses allowed to mint CreditIdentity tokens
    ///         (the onboarding backend / agent).
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Held by the ScoringOracle finalizer flow; allowed to record claims
    ///         on behalf of users in ZKAttestationVerifier (if backend-relayed).
    bytes32 internal constant CLAIM_RECORDER_ROLE = keccak256("CLAIM_RECORDER_ROLE");

    /// @notice Held by CreditSlasher; allowed to spend the InsuranceFund.
    bytes32 internal constant INSURANCE_SPENDER_ROLE = keccak256("INSURANCE_SPENDER_ROLE");

    /// @notice Held by the cross-chain bridge endpoint that writes mirrored scores.
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @notice Held by governance/multisig for proxy upgrades and param changes.
    bytes32 internal constant CONFIG_ROLE = keccak256("CONFIG_ROLE");
}
```


mocks/MockUSDC.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice A 6-decimal mock USDC for local and testnet deployments / demos.
/// @dev Anyone can mint on testnet via the faucet; do NOT deploy this to mainnet.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet for demos: mint yourself test USDC.
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    /// @notice Mint to an arbitrary address (demo seeding).
    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
```


risk/CreditSlasher.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {ICreditSlasher, ISocialAttestation, IInsuranceFund} from "../interfaces/IProtocol.sol";
import {IScoreRegistry} from "../interfaces/IScoreRegistry.sol";

/// @title CreditSlasher
/// @notice Executes the consequences of a loan default. Called by the LoanManager
///         from `markDefault`. It (1) reduces the borrower's on-chain score,
///         (2) slashes the bonds of anyone who attested to the borrower, routing
///         recovered USDC into the InsuranceFund, and (3) draws on the
///         InsuranceFund to make the LendingPool whole on the remaining loss.
/// @dev Holds SLASHER_ROLE (to write reduced scores + slash attestations) and is
///      granted INSURANCE_SPENDER_ROLE (to spend the fund). The pool already wrote
///      down principal in LoanManager; insurance coverage flows USDC back into the
///      pool to back outstanding shares.
contract CreditSlasher is ProtocolBase, ICreditSlasher {
    IScoreRegistry public immutable scoreRegistry;
    ISocialAttestation public immutable attestation;
    IInsuranceFund public immutable insuranceFund;

    /// @notice Address allowed to call processDefault (the LoanManager).
    address public loanManager;

    /// @notice Score penalty applied on default (absolute points).
    uint16 public scorePenalty;

    /// @notice Floor a defaulted score is reduced to, never below MIN.
    uint16 public constant MIN_SCORE = 300;

    /// @notice Default tier assigned after a default when writing the new score.
    uint8 public defaultTier;

    event DefaultProcessed(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        uint256 outstanding,
        uint256 slashedFromAttesters,
        uint256 coveredByInsurance
    );
    event ScoreReduced(uint256 indexed tokenId, uint16 oldScore, uint16 newScore);
    event LoanManagerSet(address loanManager);
    event ScorePenaltySet(uint16 penalty);

    error OnlyLoanManager();

    constructor(
        address accessController,
        address scoreRegistry_,
        address attestation_,
        address insuranceFund_
    ) ProtocolBase(accessController) {
        if (scoreRegistry_ == address(0) || attestation_ == address(0) || insuranceFund_ == address(0)) {
            revert ZeroAddress();
        }
        scoreRegistry = IScoreRegistry(scoreRegistry_);
        attestation = ISocialAttestation(attestation_);
        insuranceFund = IInsuranceFund(insuranceFund_);
        scorePenalty = 150;
        defaultTier = 1;
    }

    /// @inheritdoc ICreditSlasher
    /// @param loss The protocol's realized principal loss to be made whole.
    function processDefault(uint256 loanId, uint256 tokenId, uint256 loss) external {
        if (msg.sender != loanManager) revert OnlyLoanManager();

        // 1. Reduce the borrower's score.
        _reduceScore(tokenId);

        // 2. Slash attesters; recovered USDC is transferred into the InsuranceFund.
        uint256 slashed = attestation.slashAttestations(tokenId, loss);

        // 3. Make the pool whole from the InsuranceFund. We target the FULL loss,
        //    not loss-minus-slashed: the slashed funds were just deposited into
        //    the fund, so cover() deploys them (plus any reserves) toward the pool
        //    up to the fund's balance. Covering only the remainder would strand
        //    the recovered slash money in the fund and under-compensate suppliers.
        uint256 covered = insuranceFund.cover(loanId, loss);

        emit DefaultProcessed(loanId, tokenId, loss, slashed, covered);
    }

    function _reduceScore(uint256 tokenId) internal {
        (uint16 current,,) = scoreRegistry.getScore(tokenId);
        if (current == 0) return; // nothing to reduce
        uint16 newScore = current > MIN_SCORE + scorePenalty ? current - scorePenalty : MIN_SCORE;
        scoreRegistry.updateScore(tokenId, newScore, defaultTier, bytes32("DEFAULT"));
        emit ScoreReduced(tokenId, current, newScore);
    }

    // ----------------------------------------------------------------
    // Config
    // ----------------------------------------------------------------

    function setLoanManager(address loanManager_) external onlyRole(Roles.CONFIG_ROLE) {
        if (loanManager_ == address(0)) revert ZeroAddress();
        loanManager = loanManager_;
        emit LoanManagerSet(loanManager_);
    }

    function setScorePenalty(uint16 penalty) external onlyRole(Roles.CONFIG_ROLE) {
        scorePenalty = penalty;
        emit ScorePenaltySet(penalty);
    }

    function setDefaultTier(uint8 tier) external onlyRole(Roles.CONFIG_ROLE) {
        require(tier >= 1 && tier <= 5, "Slasher: bad tier");
        defaultTier = tier;
    }
}
```


risk/InsuranceFund.sol
```
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProtocolBase} from "../governance/ProtocolBase.sol";
import {Roles} from "../libraries/Roles.sol";
import {IInsuranceFund} from "../interfaces/IProtocol.sol";

/// @title InsuranceFund
/// @notice First-loss reserve. Funded by a slice of interest (via Treasury) and
///         by slashed attestation bonds. On default, the CreditSlasher draws from
///         here to make the pool whole before suppliers absorb any loss.
contract InsuranceFund is ProtocolBase, IInsuranceFund, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset; // USDC

    /// @notice Destination the slasher sends covered funds to (the LendingPool).
    address public coverageRecipient;

    uint256 public totalCovered;

    event Funded(address indexed from, uint256 amount, uint256 newBalance);
    event Covered(uint256 indexed loanId, uint256 requested, uint256 covered);
    event CoverageRecipientSet(address recipient);

    error NoRecipient();

    constructor(address accessController, address asset_) ProtocolBase(accessController) {
        if (asset_ == address(0)) revert ZeroAddress();
        asset = IERC20(asset_);
    }

    /// @inheritdoc IInsuranceFund
    /// @notice Pull `amount` USDC from caller into the fund.
    function fund(uint256 amount) external nonReentrant {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount, asset.balanceOf(address(this)));
    }

    /// @notice Accept funds already transferred in (e.g. slashed bonds), no pull.
    function notifyFunded(uint256 amount) external {
        emit Funded(msg.sender, amount, asset.balanceOf(address(this)));
    }

    /// @inheritdoc IInsuranceFund
    /// @notice Cover up to `amount` of a default loss, sending USDC to the
    ///         coverage recipient (the pool). Returns the amount actually covered.
    /// @dev Restricted to INSURANCE_SPENDER_ROLE (held by CreditSlasher).
    function cover(uint256 loanId, uint256 amount)
        external
        nonReentrant
        onlyRole(Roles.INSURANCE_SPENDER_ROLE)
        returns (uint256 covered)
    {
        if (coverageRecipient == address(0)) revert NoRecipient();
        uint256 bal = asset.balanceOf(address(this));
        covered = amount > bal ? bal : amount;
        if (covered > 0) {
            totalCovered += covered;
            asset.safeTransfer(coverageRecipient, covered);
        }
        emit Covered(loanId, amount, covered);
    }

    /// @inheritdoc IInsuranceFund
    function balance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function setCoverageRecipient(address recipient) external onlyRole(Roles.CONFIG_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        coverageRecipient = recipient;
        emit CoverageRecipientSet(recipient);
    }
}
```


scoring/ScoringOracle.sol
```
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
```


verification/DataOracleAdapter.sol
```
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
```



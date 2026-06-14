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

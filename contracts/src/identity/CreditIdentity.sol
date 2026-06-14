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

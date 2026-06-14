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

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

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

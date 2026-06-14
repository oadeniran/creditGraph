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

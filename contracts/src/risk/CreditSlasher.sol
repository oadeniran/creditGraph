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

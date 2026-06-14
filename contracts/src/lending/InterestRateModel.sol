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

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

/// @title InsuranceLib
/// @notice Pure math for the growth-per-liquidity-unit accumulator that spreads a slash/tax
///         payout across all LPs active in a pool at settlement time, without iterating over
///         them. Mirrors Uniswap's own `feeGrowthGlobalX128` / `feeGrowthInside` mechanism
///         (see ARCHITECTURE_VALIDATION.md #6) — same math, different funding source.
/// @dev No storage, no external calls.
library InsuranceLib {
    /// @notice Growth-index increment for a payout spread over `activeLiquidity`.
    /// @dev Reverts if `activeLiquidity == 0` — a payout cannot be attributed to zero LPs.
    ///      Callers must not invoke this when the pool has no active liquidity; the hook checks
    ///      this and, in that edge case, leaves the funds in the vault's reserve unattributed
    ///      rather than reverting the whole settlement (see BackstopHook `_settle`).
    function growthIncrement(uint256 payout, uint128 activeLiquidity) internal pure returns (uint256) {
        return FullMath.mulDiv(payout, FixedPoint128.Q128, activeLiquidity);
    }

    /// @notice An LP's newly-accrued (unclaimed) entitlement since their last checkpoint.
    function entitlement(uint128 positionLiquidity, uint256 currentGrowthX128, uint256 checkpointGrowthX128)
        internal
        pure
        returns (uint256)
    {
        if (currentGrowthX128 <= checkpointGrowthX128) return 0;
        unchecked {
            return FullMath.mulDiv(positionLiquidity, currentGrowthX128 - checkpointGrowthX128, FixedPoint128.Q128);
        }
    }
}

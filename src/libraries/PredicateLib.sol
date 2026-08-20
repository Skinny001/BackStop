// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopConfig, PredicateResult} from "../types/BackstopTypes.sol";

/// @title PredicateLib
/// @notice Pure math for the same-transaction displacement-and-reversal predicate.
/// @dev No storage, no external calls — deliberately isolated so it can be fuzzed and reasoned
///      about independently of any contract state. See MECHANISM.md "Predicate" for the model.
library PredicateLib {
    uint256 internal constant BPS_DENOM = 10_000;

    /// @notice Whether the price move from `sqrtPriceOpenX96` to `sqrtPriceAfterOpenX96` clears
    ///         the minimum-displacement threshold, expressed as bps of the starting price.
    function isDisplacement(uint160 sqrtPriceOpenX96, uint160 sqrtPriceAfterOpenX96, uint16 minDisplacementBps)
        internal
        pure
        returns (bool)
    {
        if (sqrtPriceOpenX96 == 0) return false;
        uint256 delta = _absDiff(sqrtPriceOpenX96, sqrtPriceAfterOpenX96);
        // bps of a sqrtPrice delta approximates bps of the price delta closely enough for a
        // threshold gate (price = sqrtPrice^2, so this is conservative — it under-counts large
        // moves relative to a true price-bps measure, never over-counts small ones as large).
        return delta * BPS_DENOM / sqrtPriceOpenX96 >= minDisplacementBps;
    }

    /// @notice Evaluates the full four-condition predicate for a candidate closing leg.
    /// @param sqrtPriceOpenX96 pool price immediately before the opening (displacement) leg
    /// @param sqrtPriceAfterOpenX96 pool price immediately after the opening leg
    /// @param sqrtPriceAfterCloseX96 pool price immediately after the candidate closing leg
    /// @param victimNotional accumulated same-direction volume observed while the window was open
    /// @param openWasZeroForOne direction of the opening leg
    /// @param closeIsZeroForOne direction of the candidate closing leg
    function evaluate(
        uint160 sqrtPriceOpenX96,
        uint160 sqrtPriceAfterOpenX96,
        uint160 sqrtPriceAfterCloseX96,
        uint128 victimNotional,
        bool openWasZeroForOne,
        bool closeIsZeroForOne,
        BackstopConfig memory config
    ) internal pure returns (PredicateResult memory result) {
        // Structural condition first: a reversal is only meaningful in the opposite direction.
        if (closeIsZeroForOne == openWasZeroForOne) {
            return result; // matched = false, zeroed fields
        }

        result.displacementX96 = _absDiff(sqrtPriceOpenX96, sqrtPriceAfterOpenX96);
        if (result.displacementX96 == 0) {
            return result; // no displacement, nothing to reverse
        }

        result.reversalX96 = _absDiff(sqrtPriceAfterOpenX96, sqrtPriceAfterCloseX96);
        // Reversal cannot exceed the original displacement for bps purposes; cap it so an
        // overshoot (closing leg pushes price past the pre-open price) still reads as "fully
        // reversed" (100%) rather than an out-of-range percentage.
        uint256 cappedReversal = result.reversalX96 > result.displacementX96 ? result.displacementX96 : result.reversalX96;
        result.reversalBps = cappedReversal * BPS_DENOM / result.displacementX96;

        bool displacementOk = isDisplacement(sqrtPriceOpenX96, sqrtPriceAfterOpenX96, config.minDisplacementBps);
        bool victimOk = victimNotional >= config.minVictimNotional;
        bool reversalOk = result.reversalBps >= config.minReversalBps;

        result.matched = displacementOk && victimOk && reversalOk;
    }

    function _absDiff(uint160 a, uint160 b) private pure returns (uint256) {
        return a >= b ? uint256(a) - uint256(b) : uint256(b) - uint256(a);
    }
}

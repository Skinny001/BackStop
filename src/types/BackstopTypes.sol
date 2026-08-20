// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Owner-configurable economic parameters for one BackstopHook deployment.
/// @dev All bps fields are out of 10_000. See MECHANISM.md for the model each field feeds.
struct BackstopConfig {
    // --- priority tax (charged unconditionally on every eligible-searcher swap) ---
    uint16 priorityTaxBps; // premium * priorityTaxBps / 10_000
    uint128 minFlatTax; // floor, in the swap's unspecified currency
    uint128 maxTax; // cap, in the swap's unspecified currency
    // --- predicate thresholds ---
    uint16 minDisplacementBps; // min |Δprice|/price to open a window
    uint128 minVictimNotional; // min accumulated same-direction victim volume to arm a match
    uint16 minReversalBps; // min fraction of the displacement that must be undone
    // --- slashing ---
    uint16 slashBps; // fraction of bond slashed per match, out of 10_000
}

/// @notice Result of evaluating the predicate for a closing leg. Pure data, no storage.
struct PredicateResult {
    bool matched;
    uint256 displacementX96; // |sqrtPriceAfterOpen - sqrtPriceOpen|
    uint256 reversalX96; // |sqrtPriceAfterOpen - sqrtPriceClose|
    uint256 reversalBps;
}

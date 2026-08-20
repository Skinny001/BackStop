// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopConfig} from "../types/BackstopTypes.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title BondLib
/// @notice Pure math for priority-tax sizing and slash sizing. No storage, no external calls.
/// @dev See ARCHITECTURE_VALIDATION.md #3 for why `tx.gasprice - block.basefee` is treated as a
///      self-reported willingness-to-pay signal (used only to size the tax) rather than an
///      eligibility gate or a proof of purchased priority. Uses `FullMath.mulDiv` (not raw
///      `a * b / c`) for both computations below: `currentBond`/`premium` are attacker- or
///      caller-influenced values, and while realistic ERC-20 balances and gas prices never
///      approach the ~1e72 magnitude where a raw `uint256` multiply would overflow, there is no
///      reason to leave that revert path reachable at all when a safe 512-bit-intermediate
///      multiply is one import away.
library BondLib {
    uint256 internal constant BPS_DENOM = 10_000;

    /// @notice Saturating gas-premium calculation. Never underflows even if `gasPrice <= baseFee`
    ///         (e.g. a legacy-type transaction, or a chain/mempool edge case).
    function gasPremium(uint256 gasPrice, uint256 baseFee) internal pure returns (uint256) {
        return gasPrice > baseFee ? gasPrice - baseFee : 0;
    }

    /// @notice Priority tax for one swap, clamped to [minFlatTax, maxTax].
    function computeTax(uint256 gasPrice, uint256 baseFee, BackstopConfig memory config)
        internal
        pure
        returns (uint128)
    {
        uint256 premium = gasPremium(gasPrice, baseFee);
        uint256 tax = FullMath.mulDiv(premium, config.priorityTaxBps, BPS_DENOM);
        if (tax < config.minFlatTax) tax = config.minFlatTax;
        if (tax > config.maxTax) tax = config.maxTax;
        // Safe: capped at config.maxTax (already uint128) immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(tax);
    }

    /// @notice Slash amount for a matched pattern: a configurable fraction of the current bond,
    ///         never more than the bond actually holds.
    /// @dev `slashBps` is clamped to `BPS_DENOM` (100%) before the multiply. `_validateConfig`
    ///      already rejects a hook config above 100%, so in the deployed system `slashBps` never
    ///      arrives above 10_000 — this clamp exists so the function has well-defined, overflow-
    ///      free behavior across its *entire* `uint16` input domain on its own terms, rather than
    ///      silently depending on a caller-side invariant it cannot itself verify.
    function computeSlash(uint256 currentBond, uint16 slashBps) internal pure returns (uint256) {
        uint256 bps = slashBps > BPS_DENOM ? BPS_DENOM : slashBps;
        return FullMath.mulDiv(currentBond, bps, BPS_DENOM);
    }
}

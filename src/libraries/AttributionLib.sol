// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title AttributionLib
/// @notice Per-pool, transaction-scoped attribution state for the same-transaction
///         displacement-and-reversal window. Backed entirely by EIP-1153 transient storage
///         (`tstore`/`tload`), which the EVM guarantees is zeroed at the start of every new
///         transaction — no manual cleanup is required or performed (see
///         ARCHITECTURE_VALIDATION.md #5). Every slot is namespaced by `poolId` so activity in
///         one pool can never read or corrupt another pool's window (Isolation invariant,
///         MECHANISM.md).
/// @dev No SLOAD/SSTORE, no external calls. Slot derivation mirrors v4-core's own
///      `CurrencyDelta._computeSlot` pattern (`keccak256(field, poolId)`).
library AttributionLib {
    // ---- individual fields, each its own namespaced transient slot ----

    function _slot(bytes32 field, PoolId poolId) private pure returns (bytes32 hashSlot) {
        assembly ("memory-safe") {
            mstore(0, field)
            mstore(32, poolId)
            hashSlot := keccak256(0, 64)
        }
    }

    bytes32 private constant OPEN = keccak256("backstop.window.open");
    bytes32 private constant DISPLACER = keccak256("backstop.window.displacer");
    bytes32 private constant ZERO_FOR_ONE = keccak256("backstop.window.zeroForOne");
    bytes32 private constant SQRT_PRICE_OPEN = keccak256("backstop.window.sqrtPriceOpen");
    bytes32 private constant SQRT_PRICE_AFTER_OPEN = keccak256("backstop.window.sqrtPriceAfterOpen");
    bytes32 private constant VICTIM_NOTIONAL = keccak256("backstop.window.victimNotional");
    bytes32 private constant PRE_SWAP_PRICE = keccak256("backstop.preSwapPrice");

    struct Window {
        bool open;
        address displacer;
        bool zeroForOne;
        uint160 sqrtPriceOpenX96;
        uint160 sqrtPriceAfterOpenX96;
        uint128 victimNotional;
    }

    function load(PoolId poolId) internal view returns (Window memory w) {
        bytes32 openSlot = _slot(OPEN, poolId);
        bytes32 displacerSlot = _slot(DISPLACER, poolId);
        bytes32 zfoSlot = _slot(ZERO_FOR_ONE, poolId);
        bytes32 priceOpenSlot = _slot(SQRT_PRICE_OPEN, poolId);
        bytes32 priceAfterSlot = _slot(SQRT_PRICE_AFTER_OPEN, poolId);
        bytes32 notionalSlot = _slot(VICTIM_NOTIONAL, poolId);

        uint256 openRaw;
        uint256 displacerRaw;
        uint256 zfoRaw;
        uint256 priceOpenRaw;
        uint256 priceAfterRaw;
        uint256 notionalRaw;
        assembly ("memory-safe") {
            openRaw := tload(openSlot)
            displacerRaw := tload(displacerSlot)
            zfoRaw := tload(zfoSlot)
            priceOpenRaw := tload(priceOpenSlot)
            priceAfterRaw := tload(priceAfterSlot)
            notionalRaw := tload(notionalSlot)
        }
        // Each truncation below is safe because every write path in this library zero-extends
        // the narrower type up to a full uint256 word before storing (see `openOrExtend` and
        // `accumulateVictim`) — the upper bits are always already zero, so narrowing back on
        // read never discards nonzero data.
        w.open = openRaw != 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        w.displacer = address(uint160(displacerRaw));
        w.zeroForOne = zfoRaw != 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        w.sqrtPriceOpenX96 = uint160(priceOpenRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        w.sqrtPriceAfterOpenX96 = uint160(priceAfterRaw);
        // forge-lint: disable-next-line(unsafe-typecast)
        w.victimNotional = uint128(notionalRaw);
    }

    /// @notice Opens a new window, or re-anchors an already-open window's displacement leg to a
    ///         later price when the same displacer trades again in the same direction before
    ///         reversing (see MECHANISM.md state machine — this extends rather than
    ///         double-counts the displacement).
    function openOrExtend(
        PoolId poolId,
        address displacer,
        bool zeroForOne,
        uint160 sqrtPriceOpenX96,
        uint160 sqrtPriceAfterOpenX96
    ) internal {
        bytes32 openSlot = _slot(OPEN, poolId);
        bytes32 displacerSlot = _slot(DISPLACER, poolId);
        bytes32 zfoSlot = _slot(ZERO_FOR_ONE, poolId);
        bytes32 priceAfterSlot = _slot(SQRT_PRICE_AFTER_OPEN, poolId);

        Window memory existing = load(poolId);
        // Only (re)write the original open price if this is a fresh window; an extension keeps
        // the original baseline so measured displacement is cumulative from the true start.
        if (!existing.open) {
            bytes32 priceOpenSlot = _slot(SQRT_PRICE_OPEN, poolId);
            uint256 v = sqrtPriceOpenX96;
            assembly ("memory-safe") {
                tstore(priceOpenSlot, v)
            }
        }

        uint256 openVal = 1;
        uint256 displacerVal = uint160(displacer);
        uint256 zfoVal = zeroForOne ? 1 : 0;
        uint256 afterVal = sqrtPriceAfterOpenX96;
        assembly ("memory-safe") {
            tstore(openSlot, openVal)
            tstore(displacerSlot, displacerVal)
            tstore(zfoSlot, zfoVal)
            tstore(priceAfterSlot, afterVal)
        }
    }

    /// @notice Accumulates same-direction volume from a non-displacer sender while the window
    ///         is open (the "victim" leg(s), possibly plural — see Case E, MECHANISM.md).
    function accumulateVictim(PoolId poolId, uint128 amount) internal {
        bytes32 notionalSlot = _slot(VICTIM_NOTIONAL, poolId);
        uint256 current;
        assembly ("memory-safe") {
            current := tload(notionalSlot)
        }
        uint256 updated = current + amount;
        // Saturate rather than wrap: `load()` reads this slot back as uint128, so the stored
        // value must never exceed type(uint128).max even though the transient slot itself is a
        // full uint256 word.
        if (updated > type(uint128).max) updated = type(uint128).max;
        assembly ("memory-safe") {
            tstore(notionalSlot, updated)
        }
    }

    /// @notice Stashes the pool's price immediately before the current swap executes, so this
    ///         same swap's own `afterSwap` call can compute its displacement/reversal without a
    ///         second read racing a state change. Overwritten every swap; never read across a
    ///         swap boundary it wasn't written for, since each `beforeSwap`/`afterSwap` pair for
    ///         a given pool executes back-to-back with no other pool activity interleaved
    ///         (PoolManager permits only one active `unlock()` session at a time).
    function stashPreSwapPrice(PoolId poolId, uint160 sqrtPriceX96) internal {
        bytes32 slot = _slot(PRE_SWAP_PRICE, poolId);
        uint256 v = sqrtPriceX96;
        assembly ("memory-safe") {
            tstore(slot, v)
        }
    }

    function loadPreSwapPrice(PoolId poolId) internal view returns (uint160) {
        bytes32 slot = _slot(PRE_SWAP_PRICE, poolId);
        uint256 v;
        assembly ("memory-safe") {
            v := tload(slot)
        }
        // Safe: `stashPreSwapPrice` only ever writes a zero-extended uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160(v);
    }

    /// @notice Closes the window unconditionally (single-shot semantics — see MECHANISM.md:
    ///         the first opposite-direction leg from the original displacer always closes the
    ///         window, whether or not it matched the predicate).
    function close(PoolId poolId) internal {
        bytes32 openSlot = _slot(OPEN, poolId);
        bytes32 displacerSlot = _slot(DISPLACER, poolId);
        bytes32 zfoSlot = _slot(ZERO_FOR_ONE, poolId);
        bytes32 priceOpenSlot = _slot(SQRT_PRICE_OPEN, poolId);
        bytes32 priceAfterSlot = _slot(SQRT_PRICE_AFTER_OPEN, poolId);
        bytes32 notionalSlot = _slot(VICTIM_NOTIONAL, poolId);
        assembly ("memory-safe") {
            tstore(openSlot, 0)
            tstore(displacerSlot, 0)
            tstore(zfoSlot, 0)
            tstore(priceOpenSlot, 0)
            tstore(priceAfterSlot, 0)
            tstore(notionalSlot, 0)
        }
    }
}

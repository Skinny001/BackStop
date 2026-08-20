// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredicateLib} from "../../src/libraries/PredicateLib.sol";
import {BackstopConfig, PredicateResult} from "../../src/types/BackstopTypes.sol";

/// @notice Pure-math tests for the predicate, covering the case bank in MECHANISM.md.
contract PredicateLibTest is Test {
    BackstopConfig cfg;

    function setUp() public {
        cfg = BackstopConfig({
            priorityTaxBps: 1000,
            minFlatTax: 0,
            maxTax: 1e24,
            minDisplacementBps: 30, // 0.3%
            minVictimNotional: 1e18,
            minReversalBps: 5000, // 50%
            slashBps: 2000
        });
    }

    /// Case C: classic sandwich — sufficient displacement, sufficient victim, full reversal.
    function test_matches_classicSandwich() public view {
        uint160 open = 1_000_000;
        uint160 afterOpen = 1_010_000; // +1% displacement, zeroForOne=false direction (price up)
        uint160 afterClose = 1_000_100; // reverses almost all the way back
        PredicateResult memory r = PredicateLib.evaluate(open, afterOpen, afterClose, 5e18, false, true, cfg);
        assertTrue(r.matched);
    }

    /// Case A/B: no closing leg at all is not representable as a single evaluate() call — the
    /// hook simply never invokes evaluate() when there's no same-sender opposite-direction leg.
    /// Directly verify isDisplacement() is the only gate a lone swap can trip, and that alone is
    /// insufficient without evaluate() (which requires a closing leg's price).
    function test_isDisplacement_thresholds() public pure {
        assertFalse(PredicateLib.isDisplacement(1_000_000, 1_002_000, 30)); // 0.2% < 0.3%
        assertTrue(PredicateLib.isDisplacement(1_000_000, 1_003_100, 30)); // 0.31% >= 0.3%
    }

    /// Case D (structural): same-direction "closing" leg never matches — arbitrage that touches
    /// this pool twice in the same direction (not a reversal) must fail on the direction check
    /// alone, regardless of size.
    function test_noMatch_sameDirectionNeverCloses() public view {
        PredicateResult memory r =
            PredicateLib.evaluate(1_000_000, 1_010_000, 1_020_000, 1e30, false, false, cfg);
        assertFalse(r.matched);
    }

    /// Case D (thresholds): opposite direction exists but no victim volume was ever
    /// accumulated — must not match even though displacement + reversal alone would qualify.
    function test_noMatch_zeroVictimNotional() public view {
        PredicateResult memory r = PredicateLib.evaluate(1_000_000, 1_010_000, 1_000_100, 0, false, true, cfg);
        assertFalse(r.matched);
    }

    /// Case H: partial reversal below threshold does not match.
    function test_noMatch_partialReversalBelowThreshold() public view {
        // displacement = 10_000; close only reverses 3_000 of it => 30% < 50% threshold
        PredicateResult memory r =
            PredicateLib.evaluate(1_000_000, 1_010_000, 1_007_000, 5e18, false, true, cfg);
        assertFalse(r.matched);
        assertEq(r.reversalBps, 3000);
    }

    /// Case H boundary: exactly at the reversal threshold matches (>=, not >).
    function test_matches_exactlyAtReversalThreshold() public view {
        // displacement = 10_000; close reverses exactly 5_000 => 50%
        PredicateResult memory r =
            PredicateLib.evaluate(1_000_000, 1_010_000, 1_005_000, 5e18, false, true, cfg);
        assertTrue(r.matched);
        assertEq(r.reversalBps, 5000);
    }

    /// Overshoot: closing leg pushes price past the original open price. Reversal caps at 100%,
    /// never reads as some nonsensical >100% figure.
    function test_reversalCapsAt100PctOnOvershoot() public view {
        // displacement = 10_000 (1_000_000 -> 1_010_000); close overshoots to 990_000
        PredicateResult memory r =
            PredicateLib.evaluate(1_000_000, 1_010_000, 990_000, 5e18, false, true, cfg);
        assertEq(r.reversalBps, 10_000);
        assertTrue(r.matched);
    }

    function testFuzz_matchImpliesAllFourConditions(
        uint160 open,
        uint160 afterOpen,
        uint160 afterClose,
        uint128 victimNotional,
        bool openDir,
        bool closeDir
    ) public view {
        vm.assume(open > 0);
        PredicateResult memory r = PredicateLib.evaluate(open, afterOpen, afterClose, victimNotional, openDir, closeDir, cfg);
        if (r.matched) {
            assertTrue(closeDir != openDir, "matched with same direction");
            assertGe(victimNotional, cfg.minVictimNotional, "matched below victim floor");
            assertGe(r.reversalBps, cfg.minReversalBps, "matched below reversal floor");
            assertTrue(PredicateLib.isDisplacement(open, afterOpen, cfg.minDisplacementBps), "matched below displacement floor");
        }
    }

    function testFuzz_neverRevertsOnAnyInput(
        uint160 open,
        uint160 afterOpen,
        uint160 afterClose,
        uint128 victimNotional,
        bool openDir,
        bool closeDir,
        uint16 minDisplacementBps,
        uint128 minVictimNotional,
        uint16 minReversalBps
    ) public view {
        BackstopConfig memory c = cfg;
        c.minDisplacementBps = minDisplacementBps;
        c.minVictimNotional = minVictimNotional;
        c.minReversalBps = minReversalBps;
        PredicateLib.evaluate(open, afterOpen, afterClose, victimNotional, openDir, closeDir, c);
    }
}

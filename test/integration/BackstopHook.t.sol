// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopTestBase} from "../utils/BackstopTestBase.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice The predicate case bank from MECHANISM.md, exercised against a real PoolManager,
///         real pool, and two distinct router identities — not mocks. Amounts were empirically
///         calibrated (see git history / ARCHITECTURE_VALIDATION.md methodology) against the
///         harness's liquidity band so that a "small" swap sits below minDisplacementBps and a
///         "large" one sits safely above it.
///
///         Every multi-leg sequence is routed through `_bundle` (see Bundler.sol / TestBase),
///         not three separate `_swap` calls — this is not a style choice. Under Foundry's
///         `--isolate`/`--gas-report` mode, separate top-level calls are correctly executed as
///         separate transactions with independently-cleared EIP-1153 transient storage; only
///         calls nested within one top-level bundler call are genuinely "one transaction." This
///         suite is verified to pass under `forge test --isolate` as well as the default mode.
contract BackstopHookTest is BackstopTestBase {
    using StateLibrary for IPoolManager;

    uint256 constant BOND = 1000e18;
    uint256 constant SMALL = 5e18; // ~9bps price move: below the 30bps (0.3%) threshold
    uint256 constant LARGE = 40e18; // ~79bps price move: safely above threshold
    uint256 constant VICTIM = 10e18; // notional, above minVictimNotional (1e18)

    function _bondA() internal {
        _bondRouter(routerA, BOND);
    }

    function _bondB() internal {
        _bondRouter(routerB, BOND);
    }

    // ---------------------------------------------------------------------
    // Priority tax (single leg -- inherently one transaction regardless of isolation mode)
    // ---------------------------------------------------------------------

    function test_tax_chargedAndCreditedToVault_forEligibleSender() public {
        _bondA();
        vm.txGasPrice(50 gwei);
        vm.fee(10 gwei); // block.basefee -- premium = 40 gwei

        // zeroForOne=false, exact-input swap: input=currency1=specified, unspecified=currency0.
        uint256 vaultToken0Before = manager.balanceOf(address(vault), key.currency0.toId());
        _swap(routerA, searcherEOA, false, LARGE);
        uint256 vaultToken0After = manager.balanceOf(address(vault), key.currency0.toId());

        assertGt(vaultToken0After, vaultToken0Before, "vault did not receive tax claim");
    }

    function test_tax_notChargedForIneligibleSender() public {
        // routerA never bonded.
        uint256 before = manager.balanceOf(address(vault), key.currency0.toId());
        _swap(routerA, searcherEOA, false, LARGE);
        uint256 afterBal = manager.balanceOf(address(vault), key.currency0.toId());
        assertEq(afterBal, before);
    }

    // ---------------------------------------------------------------------
    // Case A: normal swap, no other activity -> no slash
    // ---------------------------------------------------------------------

    function test_caseA_normalSwap_noSlash() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));
        _swap(routerA, searcherEOA, false, SMALL); // below displacement threshold
        assertEq(registry.bond(address(routerA)), bondBefore);
    }

    // ---------------------------------------------------------------------
    // Case B: displacement-sized swap from an ineligible (unbonded) address -> never opens a
    // window at all (no bond exists to slash; mechanism is invisible to non-searchers).
    // ---------------------------------------------------------------------

    function test_caseB_unbondedDisplacement_thenReversal_noSlash() public {
        // routerA is never bonded in this test.
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(routerA, false, LARGE);
        legs[1] = Leg(routerA, true, LARGE);
        _bundle(legs);
        // Nothing to assert on routerA's bond (it has none / isn't eligible); the real assertion
        // is that this sequence does not revert and does not touch registry state for anyone.
        assertEq(registry.bond(address(routerA)), 0);
    }

    // ---------------------------------------------------------------------
    // Case C: classic sandwich -> SLASH
    // ---------------------------------------------------------------------

    function test_caseC_classicSandwich_slashesAndFundsVault() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));
        uint256 vaultBefore = manager.balanceOf(address(vault), key.currency0.toId());

        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(routerA, false, LARGE); // open
        legs[1] = Leg(routerB, false, VICTIM); // victim, same direction, different sender
        legs[2] = Leg(routerA, true, LARGE); // close, opposite direction, same sender
        _bundle(legs);

        uint256 bondAfter = registry.bond(address(routerA));
        uint256 expectedSlash = bondBefore * cfg.slashBps / 10_000;
        assertEq(bondBefore - bondAfter, expectedSlash, "slash amount mismatch");
        assertGt(expectedSlash, 0);

        uint256 vaultAfter = manager.balanceOf(address(vault), key.currency0.toId());
        assertGe(vaultAfter - vaultBefore, expectedSlash, "vault did not receive slashed funds");
    }

    // ---------------------------------------------------------------------
    // Case E: multiple victims, individually below threshold, accumulate to qualify -> SLASH
    // ---------------------------------------------------------------------

    function test_caseE_multipleVictimsAccumulate_slashes() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));

        Leg[] memory legs = new Leg[](4);
        legs[0] = Leg(routerA, false, LARGE); // open
        legs[1] = Leg(routerB, false, 0.6e18); // victim #1, alone below minVictimNotional
        legs[2] = Leg(routerB, false, 0.6e18); // victim #2, combined now above threshold
        legs[3] = Leg(routerA, true, LARGE); // close
        _bundle(legs);

        uint256 bondAfter = registry.bond(address(routerA));
        assertLt(bondAfter, bondBefore, "expected a slash from accumulated victim volume");
    }

    /// Sanity counter-check: a *single* victim leg below the threshold, with no second leg to
    /// accumulate, must NOT slash — proves the accumulation in the test above is doing real work
    /// rather than the threshold being trivially satisfied by one leg alone.
    function test_caseE_singleTinyVictim_belowThreshold_noSlash() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));

        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(routerA, false, LARGE);
        legs[1] = Leg(routerB, false, 0.6e18); // alone, below minVictimNotional (1e18)
        legs[2] = Leg(routerA, true, LARGE);
        _bundle(legs);

        assertEq(registry.bond(address(routerA)), bondBefore);
    }

    // ---------------------------------------------------------------------
    // Case F: two independent searchers, neither closes the other's window -> NO SLASH for either
    // ---------------------------------------------------------------------

    function test_caseF_twoIndependentSearchers_neitherSlashed() public {
        _bondA();
        _bondB();
        uint256 bondABefore = registry.bond(address(routerA));
        uint256 bondBBefore = registry.bond(address(routerB));

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(routerA, false, LARGE); // routerA opens
        legs[1] = Leg(routerB, true, LARGE); // routerB trades opposite direction once, unrelated
        _bundle(legs);

        assertEq(registry.bond(address(routerA)), bondABefore, "routerA slashed unexpectedly");
        assertEq(registry.bond(address(routerB)), bondBBefore, "routerB slashed unexpectedly");
    }

    // ---------------------------------------------------------------------
    // Case G: searcher opens, never reverses -> NO SLASH (tax was still charged, separately)
    // ---------------------------------------------------------------------

    function test_caseG_opensNeverReverses_noSlash() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));
        _swap(routerA, searcherEOA, false, LARGE);
        assertEq(registry.bond(address(routerA)), bondBefore);
    }

    // ---------------------------------------------------------------------
    // Case H: partial reversal below minReversalBps -> NO SLASH
    // ---------------------------------------------------------------------

    function test_caseH_partialReversalBelowThreshold_noSlash() public {
        _bondA();
        uint256 bondBefore = registry.bond(address(routerA));

        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(routerA, false, LARGE); // open (~79bps)
        legs[1] = Leg(routerB, false, VICTIM); // victim
        legs[2] = Leg(routerA, true, SMALL); // tiny reversal, well under 50%
        _bundle(legs);

        assertEq(registry.bond(address(routerA)), bondBefore, "should not slash on partial reversal");
    }

    // ---------------------------------------------------------------------
    // LP claim: after a slash, the LP (this test contract, which added all liquidity) can claim
    // its entitlement as an ERC-6909 claim balance.
    // ---------------------------------------------------------------------

    function _runSandwich() internal {
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(routerA, false, LARGE);
        legs[1] = Leg(routerB, false, VICTIM);
        legs[2] = Leg(routerA, true, LARGE);
        _bundle(legs);
    }

    function test_lpClaim_receivesEntitlementAfterSlash() public {
        _bondA();
        _runSandwich();

        uint256 lpBalBefore = manager.balanceOf(address(this), key.currency0.toId());
        (uint256 amount0,) = vault.claim(poolId, key.currency0, key.currency1, -6_000, 6_000, bytes32(0));

        assertGt(amount0, 0, "LP should have received a nonzero entitlement");
        uint256 lpBalAfter = manager.balanceOf(address(this), key.currency0.toId());
        assertEq(lpBalAfter - lpBalBefore, amount0);
    }

    /// Claiming again immediately, with no new payout event, yields nothing (no double-claim).
    function test_lpClaim_noDoubleClaim() public {
        _bondA();
        _runSandwich();

        vault.claim(poolId, key.currency0, key.currency1, -6_000, 6_000, bytes32(0));
        (uint256 amount0Second,) = vault.claim(poolId, key.currency0, key.currency1, -6_000, 6_000, bytes32(0));
        assertEq(amount0Second, 0);
    }
}

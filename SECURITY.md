# Security Review

Self-audit performed against the implementation in `src/`, informed by the threat model the build
brief mandated (§13) and by issues actually surfaced while writing tests (§21/§22) — not a
theoretical checklist filled in after the fact. Every finding below was either fixed (with a test
proving the fix) or is a documented, deliberate residual limitation.

## Findings fixed during development

### 1. `BondLib.computeSlash` — unsafe multiplication for out-of-range `slashBps` (fixed)

**Found by:** `testFuzz_computeSlash_neverExceedsBondOrBps` reverted with a genuine counterexample
(`bond ≈ type(uint256).max`, `slashBps > 10_000`).

`currentBond * slashBps / BPS_DENOM` can produce a mathematical result exceeding `type(uint256).max`
when `slashBps` (a raw `uint16`, so up to 655.35%) is far above 100% and `currentBond` is
astronomically large. `_validateConfig` on `BackstopHook` already forbids a configured `slashBps`
above `10_000`, and no realistic ERC-20 balance approaches the ~1.76e72 threshold where this would
matter — so this was never reachable through the deployed system's only caller (`onlyHook`). Fixed
anyway: `computeSlash` now clamps `slashBps` to `10_000` internally and uses `FullMath.mulDiv`, so
the function has well-defined, overflow-free behavior across its *entire* input domain rather than
depending on an invariant it cannot itself verify. Same treatment applied to `computeTax`'s
multiplication for consistency and to remove the class of bug entirely.

### 2. `InsuranceLib`/`AttributionLib` — LP reward dilution across a liquidity change (fixed)

Documented in ARCHITECTURE_VALIDATION.md #6. A naive "checkpoint only at claim time" design lets an
LP who adds liquidity *after* a payout but *before* claiming wrongly capture growth that accrued
before their liquidity existed — the same bug class staking contracts hit. Fixed by adding
`beforeAddLiquidity`/`beforeRemoveLiquidity` hook permissions that force a checkpoint (banking
already-accrued entitlement into `owed`) using the position's *pre-change* liquidity before any
delta lands, mirroring exactly how `Position.State.feeGrowthInsideLastX128` is checkpointed inside
v4-core's own `Pool.sol`.

### 3. Mint-before-credit ordering in `afterSwap` — verified, not assumed

ARCHITECTURE_VALIDATION.md #2 traces why `poolManager.mint(vault, ..., tax)` inside `BackstopHook`'s
own `afterSwap` is called *before* `PoolManager.swap()` has actually credited the hook's matching
positive delta (that credit only lands after `afterSwap` returns, per `PoolManager.sol`'s own
control flow). This nets to zero by the time `unlock()` closes, but it is exactly the kind of
reasoning that is easy to get backwards. `test_tax_chargedAndCreditedToVault_forEligibleSender` and
every Case-C-family test exercise this path against a real `PoolManager`, not a mock — if the
ordering were wrong, `unlock()` would revert with `CurrencyNotSettled` and every test would fail.

### 4. Test suite and demo script were validating a non-representative scenario (fixed)

**The most significant finding of this engineering pass.** The original test suite called each
leg of a sandwich sequence (`routerA.swap()`, `routerB.swap()`, `routerA.swap()`) as three separate
top-level calls from the test function, and the original demo script broadcast each leg as its own
separate transaction via `forge script`. Both "worked" — until run under `forge test --isolate`
(which `--gas-report` also triggers), which executes every top-level call as its own separate
transaction/EVM context. Under that mode, 3 of 12 integration tests failed: no slash occurred.

Root-caused with a minimal, independent `tstore`/`tload` probe against a real Anvil chain: EIP-1153
transient storage is correctly cleared between genuinely separate transactions (confirmed via two
real, separately-mined `cast send` transactions), even within the same block. Foundry's *default*
test execution does not isolate a test function's own top-level calls into separate EVM contexts,
so the original suite was passing by accident of the test harness, not because the mechanism works
across genuinely separate transactions (it must not, and does not). The demo script had the same
bug in a more dangerous form: its `console2.log` output (from `forge script`'s local simulation
pass, which *does* run as one continuous context) showed a successful slash, while the actual
broadcast transactions — verified independently via `cast call` after the real broadcast completed
— left the bond completely untouched on-chain. **The script would have demoed successfully in the
terminal while doing nothing on the real chain.**

**Fix:** every multi-leg sequence in both the test suite and the demo script now routes through a
minimal multicall `Bundler` contract (`test/utils/Bundler.sol`), making the legs genuinely nested
calls within one top-level transaction — the same shape as the real batch-router/solver/bundler
class of contract this whole mechanism is designed around (ARCHITECTURE_VALIDATION.md §5). Re-
verified against a fresh Anvil chain with `--slow` (forcing each broadcast transaction into its own
block): the bundled sandwich transaction landed alone in its own block, and `cast call` against the
live contract afterward — not the script's log — confirmed a real, on-chain 20% slash. The full
suite now passes identically under both default `forge test` and `forge test --isolate`. Full
writeup: ARCHITECTURE_VALIDATION.md §8.

## Threat model (§13) — status of each vector

### Searcher attacks

| Vector | Status |
|---|---|
| Fake priority (spoofed `tx.gasprice`) | Mitigated by design: eligibility is bond-gated, not gas-price-gated (ARCHITECTURE_VALIDATION.md #3). A spoofed low gas price only reduces the tax paid, never grants or revokes lane access. |
| Zero/low gas premium | Mitigated: `minFlatTax` floor means tax revenue doesn't depend on the premium signal at all. |
| Bond cycling (deposit → trigger pattern → withdraw before slash) | Not exploitable: `slash` reads the *current* bond at settlement time, inside the same atomic transaction as the triggering swap. A withdraw in an *earlier* transaction just means a smaller available bond (and thus a smaller slash) — see MECHANISM.md "Bond lifecycle." |
| Deposit/withdraw griefing (spam small deposits) | No attack surface: deposit/withdraw are pure balance mutations with no side effects on other actors; gas cost is borne by the caller only. |
| Multiple addresses (Sybil) | Each address needs its own bond; splitting doesn't reduce total capital at risk, and the predicate's `sender == displacer` requirement means only the address that actually executes both legs can be slashed — Sybil addresses can't "protect" the executing address. |
| Intentionally triggering false positives against another searcher | Structurally impossible: only the same `sender` that opened a window can close it (`AttributionLib`/`BackstopHook` check `sender == w.displacer`); an unrelated address's trade is either ignored or accumulates as victim volume, never a slash trigger against someone else's bond. |
| Sandwiching themselves (self-victim) | A searcher trading against their own open window as "victim" (same direction, different `sender`... but same underlying controller) still requires a *second* distinct router/address to generate victim volume, and the slash still lands on their own bond — there is no incentive to do this; it only costs the tax + potential self-slash for no gain. |
| Partial reversal to dodge the threshold | Correctly excluded by design (Case H) — this is the intended "no match" behavior, not a bypass of anything; a searcher who reverses less isn't extracting the sandwich's profit either. |
| Multiple victims / multiple pools | Multiple victims: accumulate correctly (Case E, tested). Multiple pools: impossible to touch from one hook instance — `onlyProtectedPool` rejects any pool other than the one constructed for (tested in `PoolScoping.t.sol`). |
| Nested swaps / flash liquidity / flash loans | v4's `onlyWhenUnlocked` + single global lock means there is no reentrant call path into a second `unlock()` session while one is active (verified by reading `PoolManager.sol`, not assumed) — flash-loan-funded swaps go through the same `beforeSwap`/`afterSwap` path as any other and are subject to the same predicate and tax. |
| Callback manipulation | `beforeSwap`/`afterSwap`/`beforeAddLiquidity`/`beforeRemoveLiquidity` all assert `msg.sender == address(poolManager)`; no other caller can invoke hook logic. |
| Pool initialization manipulation (reusing the hook address on a different pool) | Explicitly defended: `onlyProtectedPool` (ARCHITECTURE_VALIDATION.md #7/#9), tested. |

### Trader / LP attacks

| Vector | Status |
|---|---|
| Deliberately constructing a pattern to slash an innocent searcher | Not possible — an "innocent" address was never bonded/eligible in the first place (Case B), or if it is the displacer, it must itself execute the closing leg for a slash to occur; a third party cannot force someone else's bond to be slashed. |
| Victim self-sandwiching (victim trades both directions to fake a pattern) | The predicate's `sender == displacer` requirement means the "victim" role is defined purely by *not* being the displacer — a victim's own round-trip never opens/closes a window it didn't open, so it cannot create a false slash against anyone. |
| LP manipulating entitlement via mint/burn timing | Mitigated by the mandatory `beforeAddLiquidity`/`beforeRemoveLiquidity` checkpoint (finding #2 above) — an LP cannot capture growth that accrued before their current liquidity existed. |
| Tiny liquidity positions to game distribution | Entitlement is strictly proportional to liquidity contributed at settlement time (`InsuranceLib.entitlement`); a tiny position gets a proportionally tiny, not disproportionate, share — there is no minimum-position bonus to exploit. |
| Repeatedly entering/exiting liquidity around a payout | Each entry/exit forces a checkpoint; growth that already accrued to the pool is not retroactively gained or lost by re-entering, it simply resets that position's "clock" to the current growth value. |

### Hook / contract attacks

| Vector | Status |
|---|---|
| Reentrancy | No `nonReentrant` guard was added, deliberately — `PoolManager`'s own single-global-lock design (`Lock.isUnlocked`) already makes nested `unlock()` calls impossible, which is the only reentrancy surface that matters here (verified by reading `PoolManager.sol`, see ARCHITECTURE_VALIDATION.md #4). Adding a redundant guard would cost gas for no additional safety. |
| Transient-state corruption / cross-pool leakage | `onlyProtectedPool` makes this moot for this deployment (only one pool can ever reach the hook); `AttributionLib` additionally namespaces every slot by `PoolId` as defense in depth. |
| Malicious currencies / tokens (fee-on-transfer, rebasing) | **Residual risk, documented, not mitigated**: `BackstopRegistry`/`BackstopHook` assume standard ERC-20 semantics (transferred amount == requested amount). A fee-on-transfer bond asset would cause the registry's internal `bond[]` accounting to diverge from its actual token balance (the invariant test `invariant_registryBalanceCoversAllBonds` would catch this class of token in practice, but the code does not defend against it). **Mitigation for production**: restrict `bondAsset` to a vetted allowlist of standard tokens; this is a config-time decision, not a code fix, and is explicitly out of scope for the hackathon prototype. |
| Gas griefing via unbounded iteration | No unbounded loops exist anywhere in the settlement or claim path — this was a first-order design constraint (ARCHITECTURE_VALIDATION.md #6), not a later patch. |
| Price manipulation of the predicate itself | The predicate reads `sqrtPriceX96` directly from `StateLibrary`, the same source of truth the pool's own swap math uses — there is no separate oracle to manipulate. A searcher *can* manipulate the pool's own price via a large swap, but doing so is exactly the observable pattern the predicate is designed to catch, priced in via `minDisplacementBps`/`minReversalBps`/`minVictimNotional`. |

### Economic attacks

| Vector | Status |
|---|---|
| False-positive profitability (predicate fires on legitimate activity, searcher profits from the resulting insurance-fund drain somehow) | Not applicable — a slash moves value from the searcher's *own* bond to the vault; there is no path for a searcher to profit from their own bond being slashed. |
| Bond cheaper than expected extraction | An economic/governance parameter (`minBond`, `slashBps`), not a code vulnerability — flagged in MECHANISM.md as a configuration responsibility, not something the contract can enforce on-chain without an oracle. |
| Tax avoidance | Tax is charged on every eligible-sender swap unconditionally; the only "avoidance" is not enrolling (in which case there is no lane-access benefit either — see MECHANISM.md Tax Model). |
| Reserve drain via repeated slash events | Each slash is capped at `slashBps` of the *triggering searcher's own* bond — there is no shared "reserve" a searcher can drain; they can only ever move their own capital into the vault. |
| Reserve exhaustion vs. LP claims | `InsuranceVault._payOut` caps any single claim at `min(entitlement, vault's actual claim balance)` and never reverts on a shortfall — the unpaid remainder stays in `owed` for a future claim (MECHANISM.md "Failure modes"). |

## Known limitations (stated, not hidden — §30/§36 claim discipline)

- **Cross-transaction, same-block sandwiches are entirely out of scope.** This is the single most
  important limitation and is stated in every doc in this repo, not just here.
- **`tx.gasprice - block.basefee` is a self-reported signal, not proof of purchased priority**, and
  is used only to size a tax, never to gate access (ARCHITECTURE_VALIDATION.md #3).
- **The bond asset must be one of the protected pool's two currencies**, and one hook deployment
  protects exactly one pool (ARCHITECTURE_VALIDATION.md #6/#7).
- **Fee-on-transfer / rebasing bond assets are not supported** (see table above).
- **PositionManager-routed LPs (NFT positions) cannot self-serve `claim()`** without a periphery-
  aware helper that resolves an NFT `tokenId` back to its `(owner, tickLower, tickUpper, salt)` —
  only direct `PoolManager.modifyLiquidity` callers can claim in this implementation. Documented as
  future work, not silently broken (MECHANISM.md).
- **No governance/timelock on `BackstopHook.setConfig`** — a single `owner` EOA/multisig controls
  economic parameters. Acceptable for a hackathon prototype; production would need a timelock and
  bounded per-update deltas at minimum, explicitly flagged rather than presented as finished.
- **transient-storage composability warning** (Solidity's own compiler flags this on any `tstore`
  use): transient storage is cleared only at *transaction* end, not at the end of each call frame
  into this contract. `AttributionLib`'s single-shot window design (a window always closes on the
  first same-sender opposite-direction leg, regardless of match outcome) is the mitigation — there
  is no code path that leaves stale "open" state for a later, unrelated call within the same
  transaction to misinterpret. This was a design constraint from the start (MECHANISM.md), not an
  afterthought.

# Mechanism

The claim Backstop actually makes, precisely:

> Backstop detects a narrowly defined, objectively observable **same-transaction
> displacement-and-reversal pattern**, and backs it with a searcher-posted bond that is slashed
> into an LP insurance reserve when the pattern is observed. It does not detect sandwiches in
> general, does not infer intent, and does not attribute across transactions or addresses.

## Actors

| Actor | Role | On-chain identity |
|---|---|---|
| Searcher | Bonds capital for lane access; may trigger the predicate | The address that is `sender` in `PoolManager.swap()` (§ARCHITECTURE_VALIDATION.md #1) |
| Victim | Any other swap that occurs while a searcher's displacement window is open | Any `sender` ≠ the open displacer, in the same pool, same tx |
| LP | Supplies liquidity to the protected pool | `(owner, tickLower, tickUpper, salt)` position key, per `Position.calculatePositionKey` |
| Hook (`BackstopHook`) | Observes every swap/liquidity change in the protected pool; owns predicate + tax logic | Deployed at a mined address encoding required permission bits |
| Registry (`BackstopRegistry`) | Bond custody + eligibility + slashing | Separate contract, called by the hook |
| Vault (`InsuranceVault`) | Reserve accounting + LP entitlement + claims | Separate contract, called by the hook and by LPs directly |
| PoolManager | v4 singleton; source of truth for balances, pools, positions | `lib/v4-core` |

## Assets

- **Bond asset**: a single configurable ERC-20 (or native currency) posted by searchers. Held by `BackstopRegistry`, *not* inside PoolManager (bonds are not swap liquidity and must be seizable independent of pool state).
- **Pool currencies** (`currency0`, `currency1`): the protected pool's own tokens. Tax and slash proceeds are denominated in whichever of these is the *unspecified* currency of the triggering swap.
- **Insurance reserve**: PoolManager ERC-6909 claim balances, held by `InsuranceVault`, one balance per `(currency)`. Redeemable 1:1 for the underlying pool currency via PoolManager's own `burn`.
- **LP entitlement**: not a balance — a *computed* quantity (§4), realized as an ERC-6909 claim transfer only when an LP calls `claim()`.

## State

### Persistent (regular storage)

`BackstopRegistry`:
- `bond[searcher] : uint256` — posted bond, in bond-asset units.
- `enrolledAt[searcher] : uint64` — 0 if never enrolled.
- `config: {minBond, cooldownAfterSlash}`.

`InsuranceVault`:
- `rewardGrowthX128[poolId][currency] : uint256` — cumulative, monotonically non-decreasing.
- `checkpoint[poolId][positionKey][currency] : uint256` — an LP's last-seen growth value.
- `reserve[currency] : uint256` — mirror of the vault's own ERC-6909 claim balance (defensive accounting cross-check, §Invariants).

`BackstopHook`:
- `config: {priorityTaxBps, minFlatTax, maxTax, slashBps, minDisplacementBps, minVictimNotional, minReversalBps}` — owner-settable.

### Transient (EIP-1153, per pool, auto-zeroed at tx end — see ARCHITECTURE_VALIDATION.md §5)

A single packed struct per `PoolId`, addressed via `keccak256(NAMESPACE, poolId)`-derived slots (mirrors `CurrencyDelta`'s own pattern):

```
Window {
  bool    open;              // is a displacement window currently active for this pool?
  address displacer;         // the bonded searcher who opened it
  bool    zeroForOne;        // direction of the opening leg
  uint160 sqrtPriceOpenX96;  // pool price immediately before the opening leg
  uint160 sqrtPriceAfterOpenX96; // pool price immediately after the opening leg
  uint128 victimNotional;    // accumulated |amount| of same-direction swaps by non-displacer senders
}
```

## State machine (per pool, transient, reset automatically every transaction)

```
IDLE ──(eligible searcher swaps, |Δprice| ≥ minDisplacement)──▶ OPEN
OPEN ──(same-direction swap by a different sender, notional ≥ 0 accum)──▶ OPEN (victimNotional += amount)
OPEN ──(opposite-direction swap by the SAME displacer, reversal ≥ minReversalBps, victimNotional ≥ minVictimNotional)──▶ MATCH ──▶ slash + payout ──▶ IDLE
OPEN ──(opposite-direction swap by the SAME displacer, reversal < minReversalBps OR victimNotional < minVictimNotional)──▶ IDLE (no match; window closes either way — see "single-shot window" below)
OPEN ──(opposite-direction swap by a DIFFERENT sender)──▶ OPEN unchanged (irrelevant to this displacer's window)
OPEN ──(same displacer swaps again in the SAME direction, before reversing)──▶ OPEN, window re-anchored to the new price (extends the displacement rather than double-counting)
```

**Single-shot window, not a rolling one:** the *first* opposite-direction swap from the original
displacer always closes the window (to `MATCH` or back to `IDLE`) — a displacer does not get
unlimited attempts within one transaction to find a qualifying reversal. This bounds the mechanism
to the literal three-leg pattern the brief specifies (open → victim(s) → close) and prevents a
searcher from probing multiple reversal sizes against the same victim exposure.

**Why the window is scoped per-`PoolId`, not per-transaction:** two unrelated pools trading in the
same transaction (e.g. a multi-hop route) must not contaminate each other's attribution — an
isolation invariant (§6). Since v4 keys all its own per-pool state by `PoolId`, doing the same for
transient attribution state is the natural, minimal-risk choice, and costs nothing extra (the slot
derivation already hashes in the pool id).

**Why only the bonded displacer's own reversal can close the window:** if *any* address's opposite
trade could close another party's open window, an unrelated third party's ordinary trade could
trigger a slash against a searcher who never intended or executed a reversal — a false-attribution
bug, not a hardening measure. The closing leg must match `sender == window.displacer`.

## Predicate (pure math, `PredicateLib`, no storage/no external calls)

Given:
- `sqrtP0` = price before the opening leg, `sqrtP1` = price after it (displacement)
- `sqrtP2` = price after the closing (reversal) leg
- `victimNotional` = accumulated same-direction victim volume while the window was open
- config: `minDisplacementBps`, `minReversalBps`, `minVictimNotional`

```
displacement      = |sqrtP1 - sqrtP0|                 (in sqrtPriceX96 units)
reversalAmount     = |sqrtP1 - sqrtP2|                  (how much of the move was undone)
reversalFractionBps = reversalAmount * 10_000 / displacement

MATCH  ⟺  displacement/sqrtP0 ≥ minDisplacementBps
        ∧ victimNotional ≥ minVictimNotional
        ∧ reversalFractionBps ≥ minReversalBps
        ∧ closing leg direction == ¬(opening leg direction)
```

All four conditions are required simultaneously; there is no scoring/weighting — this keeps the
predicate auditable and removes any tunable "gray zone" a false-positive could hide in.

### Why directional arbitrage does not match (Case B/D, §False-Positive Analysis)

Arbitrage is, by construction, **one-directional**: an arbitrageur trades *into* a mispricing and
stops — they do not round-trip back through the same pool in the same transaction, because doing so
would give back the very profit they came for. A multi-hop arbitrage route (Case D) touches this
pool at most once in each direction as part of a larger cycle through *other* pools/venues; it never
produces a same-pool, same-sender, opposite-direction second leg. Because `MATCH` requires the
**same `sender`** to close in the **opposite direction**, arbitrage structurally cannot satisfy the
predicate regardless of size or displacement — it fails the "closing leg exists at all" condition,
not a tunable threshold. This is a structural (not merely a threshold-tuned) exclusion, and is the
strongest form of false-positive defense the mechanism has.

## False-Positive / True-Positive Case Bank (also implemented as tests, `PredicateLib.t.sol`)

| Case | Description | Expected |
|---|---|---|
| A | Normal single swap, no other activity | NO SLASH — window never opens past `IDLE` (only one leg exists) |
| B | Simple one-directional arbitrage (buy low, done) | NO SLASH — no opposite-direction closing leg from the same sender |
| C | Classic sandwich: same sender A→B, victim A→B, same sender B→A, reversal ≥ threshold | SLASH |
| D | Multi-hop arbitrage cycling through this pool once each direction *as part of a larger route*, no victim swap sandwiched between the two legs of *this* pool | NO SLASH unless a genuine victim swap sits between the two legs *and* thresholds are met — tested explicitly with `victimNotional = 0` ⇒ NO SLASH even though direction+reversal alone would pass |
| E | Multiple victims while window is open | `victimNotional` accumulates across all of them; SLASH if the aggregate clears `minVictimNotional` and the other conditions hold — one slash event, sized by the searcher's own bond, not by victim count |
| F | Two independent (unrelated) searchers each doing one leg | NO SLASH — window is keyed to a single `displacer`; a second searcher's swap while a window is open is itself either a same-direction "victim" leg (accumulates) or an opposite-direction leg that is ignored because `sender != displacer` — it can never close *someone else's* window |
| G | Searcher front-runs (opens window) but never reverses in this tx | NO SLASH at tx end — an open-but-unclosed window is simply discarded when transient storage clears; **however** the priority tax was still charged on the opening leg regardless of outcome (tax is unconditional, per §Tax Model) |
| H | Searcher partially reverses (reversal fraction below `minReversalBps`) | NO SLASH — explicit threshold; window closes to `IDLE` either way (single-shot, see above) |
| I | Searcher reverses only after an unrelated intervening swap in a *different* pool | Irrelevant — windows are per-`PoolId`; the other pool's activity never touches this pool's transient state. Reversal in *this* pool still evaluated on its own terms whenever it occurs later in the same tx |

## Bond lifecycle

```
deposit(amount) ─▶ bond[searcher] += amount        (searcher becomes eligible once bond ≥ minBond)
withdraw(amount) ─▶ requires bond[searcher] - amount ≥ 0 AND no cooldown active
slash(searcher, amount) ─▶ only callable by BackstopHook; bond[searcher] -= amount (floored at 0, never negative);
                            amount minted as InsuranceVault reward growth
```

There is deliberately **no separate "locked/committed" sub-balance**: a bond is either present (and
thus slashable up to its full value) or it isn't. A staged in-swap "hold" was considered and
rejected — it would require the registry to know a swap is *in flight* before its outcome is known,
adding cross-contract state coupling for a benefit (preventing same-tx withdraw-then-swap) already
achieved more simply by making `slash` read the *current* `bond[searcher]` value at settlement time,
inside the same atomic transaction as the swap that triggered it. A searcher cannot front-run their
own slash by withdrawing mid-transaction — `withdraw` and the triggering `swap` cannot both execute
if the sandwich happens inside a single atomic unlock session initiated by the searcher's own
router, and if withdraw happened in an *earlier*, separate transaction, the bond is simply smaller
(and the slash is capped at whatever remains — see Slash invariant).

**Slash sizing:** `slashAmount = min(bond[searcher], bond[searcher] * slashBps / 10_000)` — a
configurable fraction of the bond, not the whole bond, so a single false-positive-adjacent event
(should the predicate ever mis-fire against a genuinely ambiguous pattern) does not zero out a
searcher's entire stake. `slashBps` is owner-configurable up to 10_000 (100%).

## Tax model

Charged unconditionally on every swap from an eligible (bonded, enrolled) `sender`, regardless of
whether a sandwich pattern ever materializes (Case G) — this is the "priority tax," not a fine.

```
premium = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0     // saturating
tax     = clamp(premium * priorityTaxBps / 10_000, minFlatTax, maxTax)
```

Ineligible senders pay no tax and get no lane-access benefit beyond what any ordinary swapper gets
(this hook adds no restriction on non-searcher swaps — it is additive, not gating, for ordinary
traders and LPs).

## Slash / payout model

At `MATCH`:
1. `slashAmount = BackstopRegistry.slash(displacer, slashBps)` — bond debited, capped at available bond.
2. Slash proceeds are pool-currency-denominated for accounting purposes as the *unspecified*
   currency's worth is not directly comparable to the bond asset in general (bond asset may differ
   from pool currencies) — see **Bond/Insurance currency mismatch** below.
3. `InsuranceVault.fund(poolId, currency, amount)`: `rewardGrowthX128[poolId][currency] += amount * Q128 / activeLiquidity` (`activeLiquidity` read live via `StateLibrary.getLiquidity`).
4. LPs' entitlement increases automatically (§ARCHITECTURE_VALIDATION.md #6); no LP transaction required for the entitlement to exist. Physical claim is a separate, LP-initiated `claim()` call.

**Bond/insurance currency mismatch, resolved:** the bond asset is a single configured ERC-20
(simplifies bonding — searchers don't need to hold both pool currencies), while the reserve is
denominated in the pool's own currencies (so it can be paid out as real, usable pool-currency claims
to LPs without a swap). Backstop's MVP therefore requires **the bond asset to be one of the
protected pool's two currencies** (enforced at hook configuration time) — this removes the need for
an on-chain price oracle to convert a slashed bond into pool-currency terms, which would reintroduce
exactly the oracle dependency the brief explicitly rules out. This is a scope-narrowing decision
made explicitly, not hidden: multi-pool deployments with heterogeneous bond assets are future work
(§Limitations).

## Invariants (enforced in code + fuzz/invariant tests)

| Invariant | Statement | Where enforced |
|---|---|---|
| Bond | `withdraw` never allows `bond[searcher] < 0`; solidity's checked arithmetic reverts on underflow before any state is written | `BackstopRegistry.withdraw` |
| Slash | `slash(x)` never removes more than `bond[searcher]` currently holds | `min()` clamp in `BackstopRegistry.slash` |
| Reserve | `InsuranceVault`'s ERC-6909 claim balance for a currency is always ≥ sum of all outstanding (unclaimed) entitlement for that currency | invariant test `Invariant_ReserveCoversLiabilities` |
| Payout | `claim()` can never mint value — it only ever transfers existing vault claim balance, capped by `rewardGrowthX128` delta × liquidity, itself capped by what was actually funded | `InsuranceVault.claim` |
| Attribution | Transient window state cannot be observed in a later, unrelated transaction | guaranteed by EIP-1153 (not app code) — verified by a test that swaps in tx N+1 see `IDLE` |
| Isolation | Pool A's window state is unaffected by Pool B's activity in the same tx | transient slots keyed by `PoolId`; tested with two pools in one multicall |
| Reentrancy | Nested `unlock()` calls cannot corrupt window state mid-evaluation | `PoolManager` itself forbids nested `unlock()` (`AlreadyUnlocked`); no additional guard needed, verified by architecture reading, not assumed |
| Accounting | Sum of all `bond[]` balances the registry believes it holds equals its actual ERC-20 balance | invariant test `Invariant_RegistrySolvency` |
| Checkpoint | An LP cannot claim growth that accrued before their position existed at its current size | `beforeAddLiquidity`/`beforeRemoveLiquidity` force a checkpoint before the liquidity delta lands |

## Failure modes / economic assumptions made explicit

- **Insolvency is allowed by design.** If `rewardGrowthX128` implies more than the vault's actual
  ERC-6909 balance for a currency (should not happen given the funding-at-settlement design, but is
  defended against anyway), `claim()` **must not** revert-and-strand the LP indefinitely nor pay out
  more than the vault holds — `claim()` caps the transferred amount at `min(entitlement,
  vault.balanceOf(currency))` and leaves the shortfall in the LP's checkpoint delta for a future
  `claim()` once the vault is refunded, rather than reverting.
- **A searcher who is rationally willing to eat the slash still pays the tax.** The tax is
  unconditional; only the slash is conditional on the predicate. This preserves the brief's stated
  mitigation for "searcher rationally eats the slash."
- **The mechanism does not, and cannot, stop cross-transaction, same-block sandwiches.** This is
  stated as a hard limitation, not a future roadmap item that's "basically done."

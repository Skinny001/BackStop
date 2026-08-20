# Architecture Validation

This document records what was verified against the actual installed Uniswap v4 source (not
memory/assumption) before any Backstop contract was written, per the mandated Phase 1 process.
Every row is: **assumption → evidence → conclusion → decision**.

Dependency versions actually installed and read:

| Dependency | Version pinned | Path |
|---|---|---|
| `Uniswap/v4-core` | `v4.0.0` (tag `v4.0.0`, commit `e50237c`) | `lib/v4-core` |
| `Uniswap/v4-periphery` | `main` @ install time | `lib/v4-periphery` |
| `forge-std` | latest via `forge init` | `lib/forge-std` |
| Solidity | `0.8.26`, `evm_version = cancun` (required for `TSTORE`/`TLOAD`) | `foundry.toml` |
| Foundry | `1.7.1` | installed this session |

---

## 1. Hook callback signatures and `sender` semantics

**Assumption (brief):** hook can identify "the searcher" from a swap call.

**Evidence:** `lib/v4-core/src/interfaces/IHooks.sol` — `beforeSwap`/`afterSwap` receive
`address sender`, documented as *"the initial msg.sender for the swap call"*. `PoolManager.swap()`
(`lib/v4-core/src/PoolManager.sol:185`) is called directly by whatever contract or EOA invokes it;
`Hooks.beforeSwap` passes `msg.sender` at that call site — i.e. the **immediate caller of
`PoolManager.swap()`**, not `tx.origin` and not necessarily the wallet that "wants" the trade.

**Conclusion:** if a user routes through an aggregator/router/PositionManager-style contract,
`sender` is the router's address, not the end user. There is no reliable way for a v4 hook to
recover the ultimate EOA behind a routed swap.

**Decision:** Backstop's "searcher" identity **is** the immediate caller of `swap()`. Enrollment
and bonding are therefore done by a specific address (an EOA or a searcher's own execution
contract) that calls `PoolManager.swap()` directly or via a router *it controls* and passes
`hookData`/is itself `msg.sender`. Section 18's question "can routers call on behalf of
searchers?" is answered explicitly: **yes, but the bond is attached to whichever address is
`sender` at the PoolManager boundary — that address must be the one enrolled.** This is documented
as a known boundary condition, not hidden.

---

## 2. Charging the priority tax: `BeforeSwapDelta` mechanics

**Assumption (brief):** tax can be levied "via `BeforeSwapDelta`".

**Evidence:** `Hooks.sol:246-281` (`beforeSwap`) — the `BeforeSwapDelta` a hook returns is
**only honored if the hook address encodes `BEFORE_SWAP_RETURNS_DELTA_FLAG`**
(`Hooks.sol:265`); otherwise it is discarded regardless of what the hook function returns. The
specified-currency component of that delta is *added into the actual swap amount*
(`amountToSwap += hookDeltaSpecified`, `Hooks.sol:274`), which can flip exact-in/exact-out if
misused (`HookDeltaExceedsSwapAmount`). The unspecified-currency component flows unmodified into
`afterSwap` (`Hooks.sol:294-311`) where it is combined with any delta `afterSwap` itself returns
(gated separately by `AFTER_SWAP_RETURNS_DELTA_FLAG`) into a single `hookDelta`, which
`PoolManager.swap()` (`PoolManager.sol:218-224`) accounts **to the hook's own address** via
`_accountPoolBalanceDelta(key, hookDelta, address(key.hooks))`, and debits the swapper's realized
delta by the same amount (`swapDelta - hookDelta`).

**Conclusion:** the safe way to charge a tax without perturbing the trader's exact-in/exact-out
intent is to return a **zero specified delta and a positive unspecified delta** from `beforeSwap`.
This makes the hook "owed" `taxAmount` of the unspecified currency once the swap settles, without
changing how much is actually swapped through the pool. This requires the hook address to encode
`BEFORE_SWAP_RETURNS_DELTA_FLAG`.

**Decision:** `BackstopHook` returns `toBeforeSwapDelta(0, int128(tax))` from `beforeSwap`, and
immediately converts the resulting hook-owed balance into an ERC-6909 claim via
`poolManager.mint(address(vault), currency.toId(), tax)` before the `unlock()` session ends
(inside `afterSwap`, still within the same unlocked context — see §4). Verified end-to-end by an
integration test that asserts the swapper's realized output/input changes by exactly `tax` and the
vault's ERC-6909 balance increases by the same amount.

---

## 3. `tx.gasprice - block.basefee` as a priority signal

**Assumption (brief):** this quantity is a valid, safe proxy for "how much the searcher paid for
priority," usable on Unichain, fail-closed elsewhere.

**Evidence / reasoning:**
- Both `GASPRICE` and `BASEFEE` are ordinary opcodes available to any contract in any call frame;
  `tx.gasprice` is fixed for the entire transaction (identical across every internal call/swap in
  that tx). `block.basefee` is fixed for the whole block. The subtraction is a legitimate EVM
  quantity, not something invented off-chain.
- Unichain is an OP-Stack chain with a **single sequencer** (at hackathon time) implementing
  EIP-1559-style basefee, not an open proposer-builder-separation priority-gas auction like L1.
  That means "premium paid" is **self-selected by the sender**, not a market-cleared price for
  actual execution order the way it is on L1. A searcher can pay an arbitrarily large premium
  without the sequencer being obligated to reorder anything today — and conversely, in a future
  state with priority-ordering (Unichain's stated roadmap, e.g. Flashblocks-style builders), a real
  bidding signal would exist.
- Worse: nothing stops a searcher from setting `tx.gasprice` far below what they will actually pay
  the block builder off-chain (private orderflow), or a chain/tx-type where `tx.gasprice` can be
  `<= block.basefee` in edge cases (e.g. some L2 fee mechanics, or a legacy-type transaction),
  which would make the naive subtraction **underflow** if computed as `unchecked` arithmetic — a
  real bug the brief did not flag.

**Conclusion:** this signal is **directionally correct as a self-reported willingness-to-pay
proxy** but is **not proof of actually purchased priority** on Unichain today. Treating it as a
hard eligibility gate would be dishonest (violates §30 claim discipline) and exploitable (searcher
sets `tx.gasprice = block.basefee + 1` to pay a near-zero tax while still being "in the lane").

**Decision (correction to the brief):**
1. **Lane eligibility is decoupled from the gas-premium signal entirely.** Eligibility = bonded +
   enrolled + not-currently-slashed-below-minimum, checked via `BackstopRegistry.isEligible(sender)`
   — a deterministic, non-manipulable, on-chain fact. The gas premium never gates access.
2. The premium only **sizes the tax**, and is computed safely:
   `premium = tx.gasprice > block.basefee ? tx.gasprice - block.basefee : 0` (saturating, never
   underflows).
3. Tax = `max(minFlatTax, premium * priorityTaxBps / 10_000)`, capped at `maxTax`. The flat floor
   guarantees the insurance pool still accrues revenue even when the premium signal is zero or
   gamed; the cap bounds worst-case cost to a searcher who overpays gas.
4. This is documented in README/SECURITY.md as an explicit, honest limitation: the tax is a
   **configurable lane-usage fee**, not a cryptographic proof of purchased block-priority.

---

## 4. `onlyWhenUnlocked` and where token movement is legal

**Assumption (brief, implicit):** the insurance vault can just "pay LPs" and searchers can "post a
bond" without further constraint.

**Evidence:** `PoolManager.sol` — `take`, `settle`, `settleFor`, `clear`, `mint`, `burn`, `sync`,
`swap`, `modifyLiquidity`, `donate` are **all** gated by `onlyWhenUnlocked`
(`PoolManager.sol:95-98`, applied throughout). `unlock()` can only be called once at a time —
`if (Lock.isUnlocked()) AlreadyUnlocked.selector.revertWith();` (`PoolManager.sol:104`) — so a
second, *nested* `unlock()` call within the same call stack reverts. Crucially, `Lock.lock()`
(`PoolManager.sol:112`) runs at the end of `unlock()`, which means **a single Ethereum transaction
can contain multiple, sequential, non-overlapping `unlock()` sessions** (e.g. an EOA calls router A,
which unlocks/settles/locks, then calls router B, which does the same) — this is unlocked/locked
serially, not concurrently, so there is no reentrancy hazard for hook-local state across sessions
within one tx, but it does mean tx-scoped transient state must survive across multiple unlock
sessions (see §5).

**Conclusion:**
- Any PoolManager accounting call (`mint`/`take`/`burn`) **must** happen from inside an active
  `unlock()` session. `beforeSwap`/`afterSwap` are called by `PoolManager.swap()`, which itself
  requires `onlyWhenUnlocked` — so hook code can safely call `mint`/`take` during those callbacks.
- An LP calling `InsuranceVault.claim()` **on its own, outside of any swap**, is *not* inside an
  unlock session. The vault therefore **cannot** call `poolManager.take()`/`burn()` directly from
  `claim()` without itself opening a fresh `unlock()` session (extra complexity, extra gas, and a
  new re-entrancy surface to reason about for no real benefit).

**Decision:** LP payouts are **ERC-6909 claim-token transfers**, not raw ERC-20 transfers.
`InsuranceVault` accumulates tax/slash revenue as PoolManager ERC-6909 claims (minted to itself
during `afterSwap`, inside the unlocked context). `claim()` moves entitled claim-token balance from
the vault to the LP via the plain (non-`onlyWhenUnlocked`) ERC-6909 `transfer`, which PoolManager
exposes unconditionally. The LP now holds a fungible, PoolManager-redeemable claim they can cash
out for the underlying ERC-20 at their own convenience (their own `unlock()` session, their own
gas, their own timing) — this is the "automatic entitlement creation, not necessarily a physical
transfer in the same instruction" resolution demanded by §10, made concrete.

---

## 5. Same-transaction vs. "same-block": correcting the brief's own terminology

**Assumption (brief):** the tagline and Architecture table say "the instant a **same-block**
sandwich pattern is observed," while the Feasibility section says attribution is "**same-
transaction** state... valid because all legs share one transaction."

**Evidence:** EIP-1153 transient storage (`tstore`/`tload`) is explicitly scoped to a single
transaction and is guaranteed zeroed at the start of every new transaction — this is an EVM-level
guarantee, not something Backstop's code has to implement (see `Lock.sol`'s own use of `tstore` for
exactly this reason). There is **no EVM primitive that lets one transaction observe or influence
another transaction in the same block** short of maintaining *persistent* storage across the block
and reasoning about "the previous swap in this block," which reopens exactly the false-attribution
risk the brief itself says same-transaction scoping was chosen to avoid (unrelated back-to-back
trades, no atomic settlement, no capped-liability guarantee).

**Conclusion:** "same-block" and "same-transaction" are **not interchangeable**, and the brief's own
mechanism (transient storage) can only ever deliver the latter. The two classic real sandwich
patterns are:
1. **Cross-transaction, same-block** (searcher tx → victim tx → searcher tx, ordered by a builder
   via priority fee) — the textbook mempool sandwich. **This is explicitly out of scope**; there is
   no synchronous, provable, atomic way to attribute and settle it from within a v4 hook.
2. **Same-transaction, multiple `swap()` calls inside one `unlock()`/multi-session tx** — this is
   real and current: any router/aggregator/intent-solver/filler/ERC-4337 bundler that batches
   multiple parties' swaps atomically (for gas efficiency, for solving multiple intents at once, or
   adversarially) can order a bonded searcher's own two legs around an unrelated party's swap
   **within one transaction**. This is exactly what Backstop can observe and prove.

**Decision (correction to the brief):** all product copy, docs, and code comments consistently say
**"same-transaction displacement-and-reversal pattern"**, never "same-block." The tagline is
corrected accordingly. This is a stricter, more defensible claim, and is the one actually
implemented.

---

## 6. Identifying "affected LPs" without iteration

**Assumption (brief):** "pay affected LPs pro-rata... capped at what's actually in the pool," with
an open question of how LPs are identified and whether iteration is safe.

**Evidence:** `StateLibrary.sol` (`lib/v4-core/src/libraries/StateLibrary.sol`) exposes
`getLiquidity(manager, poolId)` — **total active in-range liquidity for the whole pool**, and
`getPositionInfo(manager, poolId, owner, tickLower, tickUpper, salt)` — a **specific position's**
liquidity, both via `extsload` (a single cold/warm `SLOAD`, no external call, no iteration). This is
exactly the same low-level access Uniswap's own `feeGrowthGlobal0X128`/`feeGrowthInside` fee
accounting is built on (`getFeeGrowthGlobals`, `getFeeGrowthInside` in the same file) — i.e. v4's
own canonical answer to "distribute a pool-wide reward to LPs without iterating over them" is a
**growth-per-liquidity-unit accumulator**, checkpointed per position.

**Conclusion:** iterating over LPs is neither necessary nor safe (unbounded, DoS-able,
gas-unpredictable — ruled out per §10/§36). The correct, precedented v4-native mechanism is the
same one Uniswap itself uses for fees.

**Decision:** `InsuranceVault` maintains `rewardGrowthX128[poolId][currency]`, incremented by
`payout * Q128 / activeLiquidity` in **O(1)** at settlement time (read via
`StateLibrary.getLiquidity`). An LP's entitlement is lazily computed at claim time as
`positionLiquidity * (currentGrowth - lastCheckpoint) / Q128`, mirroring `getFeeGrowthInside`
exactly. **Correctness hazard found and fixed:** because Backstop does not itself run the swap fee
accounting, a naive version of this (checkpoint-only-on-claim) is vulnerable to the same
"phantom/diluted rewards" bug class staking contracts hit — an LP who adds liquidity *after* a
payout event but *before* claiming would wrongly capture growth accrued before their liquidity
existed. **Fix:** `BackstopHook` also implements `beforeAddLiquidity`/`beforeRemoveLiquidity` to
force a checkpoint of the caller's position *before* their liquidity delta is applied, exactly
mirroring how `Position.State.feeGrowthInsideLastX128` is checkpointed on every `modifyLiquidity` in
`Pool.sol`. This costs two more hook permission bits and O(1) extra work per liquidity change; it
is the correctness-required design, not scope creep.

---

## 7. Hook address / permission flags

**Evidence:** `Hooks.sol:26-46` — permission bits are encoded in the **lowest 14 bits of the hook's
deployed address**; `PoolManager.initialize` calls `key.hooks.isValidHookAddress(key.fee)`
(`Hooks.sol:108-126`) which reverts (`HookAddressNotValid`) if the address's flag bits don't match
what the pool expects, and each individual callback silently no-ops unless its bit is set. There is
no way to "just implement `IHooks`" and have callbacks fire — the deployed address must be mined
(`CREATE2` + salt search) to encode exactly the required bits.

**Decision:** `BackstopHook` requires exactly:
`BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURNS_DELTA | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY`.
No `afterInitialize`, no `afterAddLiquidity`/`afterRemoveLiquidity` delta return (liquidity deltas
themselves are untouched by Backstop — only checkpointing is needed, no value is taken/given on
`modifyLiquidity`), no donate hooks. The deployment script mines a salt via Foundry's
`HookMiner`-equivalent logic against this exact flag set. `AFTER_SWAP_RETURNS_DELTA` is **not**
requested — the tax is fully captured through the `beforeSwap`-originated unspecified delta; slash
proceeds are moved via a *separate* `mint` call to the vault inside `afterSwap`'s body (ordinary
internal accounting, not a hook-delta return), so `afterSwap`'s own `int128` return stays zero.

---

## 8. "Same transaction" means genuinely nested calls — verified against a real chain, not assumed

**What happened:** the Foundry test suite's original methodology called `routerA.swap(...)`,
`routerB.swap(...)`, `routerA.swap(...)` as three separate **top-level** calls from the test
function. Under Foundry's *default* `forge test` execution, every call a test function makes runs
inside one shared EVM context, so this happened to work — the three swaps' attribution state
persisted across them. Running the same suite with `forge test --isolate` (Foundry's mode that
"executes all top-level calls as a separate transaction in a separate EVM context," which
`--gas-report` also enables) made 3 of the 12 integration tests fail outright: the slash amount
came back `0` instead of the expected 20% of bond.

**Investigation:** this is not a test-runner bug. EIP-1153 transient storage is *specified* to
clear at the end of every transaction. A minimal repro — deploy a two-function `tstore`/`tload`
probe contract, call `setT(777)` in one real, independently-mined transaction via `cast send`,
then call a state-changing `captureT()` in a *second* real, separately-mined transaction, and read
back the persisted result — confirmed Anvil correctly clears transient storage between genuinely
separate transactions, even within the same block. The Foundry test suite's default non-isolated
execution was therefore not representative of real on-chain behavior for a sequence of separate
top-level calls: it was silently relying on a test-harness artifact, not proof that the mechanism
works within one real transaction.

The demo script (`script/Demo.s.sol`) had exactly the same latent bug: `forge script`'s
`vm.startBroadcast()` sends **each** top-level call the script makes as its own independently
signed, separately mined transaction. The original script called `searcher.swap()`,
`victim.swap()`, `searcher.swap()` as three separate broadcasted calls. Its `console2.log` output
*looked* correct (bond dropping from 1000e18 to 800e18) — but that output comes from `forge
script`'s local **simulation** pass, which (like default `forge test`) runs the whole script as one
continuous in-memory execution before ever broadcasting anything. Querying the actual chain state
after the real broadcast, independently via `cast call`, showed the bond **unchanged at 1000e18** —
the real transactions, correctly isolated by the EVM, never shared attribution state, so no slash
ever actually happened on-chain. The script's own printed "success" was not evidence of anything.

**Fix:** both the test suite and the demo script now route every multi-leg sequence through a
minimal multicall `Bundler` contract (`test/utils/Bundler.sol`, reused by `Demo.s.sol`) — a stand-in
for the real class of contract this mechanism targets (a batch router / intent-solver / ERC-4337
bundler, see §5 above). `Bundler.execute(targets, data)` makes the three legs genuinely **nested**
calls inside one top-level call, which is one real transaction under both Foundry's default mode
and `--isolate`, and on a real chain.

**Re-verified end-to-end after the fix, against a fresh local Anvil chain with `--slow` (forcing
each broadcasted transaction into its own separate block):**
- The three swap legs were sent as one `Bundler.execute(...)` transaction, mined alone in its own
  block.
- Independently queried via `cast call` *after* the full broadcast completed (not the script's own
  log output): `registry.bond(searcherRouter)` read back `800000000000000000000` — a real, on-chain,
  20% slash, exactly matching `slashBps`.
- The full Foundry suite (`forge test`) and the same suite under `forge test --isolate` both pass
  all 12 integration tests with identical assertions.

**Takeaway, stated plainly for anyone building on top of this hook:** the same-transaction pattern
this hook detects can *only* be produced by a contract that itself makes multiple nested
`PoolManager.swap()` calls (directly or via sub-calls) within one top-level transaction — e.g. a
batch router, solver, or bundler. Three independent EOAs each submitting their own transaction,
even into the same block, will never trigger it, no matter how they are ordered. This is the
correct, honest boundary of what "same-transaction" can mean, and it is now something this repo
has actually demonstrated against a real EVM rather than asserted in prose.

## 9. No `BaseHook` in the pinned `v4-periphery`

**Evidence:** `find lib/v4-periphery/src -iname "*hook*"` and a full file listing of
`lib/v4-periphery/src/**` show **no `BaseHook.sol`** in this checkout (it existed in older
`v4-periphery` releases at `src/utils/BaseHook.sol`; the version resolved by `forge install` today
does not ship it — periphery has moved its hook-adjacent code toward the router/position-manager
utilities in `base/`).

**Decision:** `BackstopHook` implements `IHooks` **directly**, with its own minimal constructor-time
`Hooks.validateHookPermissions` call and its own `onlyPoolManager` modifier, instead of depending on
an external `BaseHook` that would either be missing or version-mismatched. This is also the smaller,
more auditable option per §36 ("no unnecessary inheritance").

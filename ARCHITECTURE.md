# Architecture

## Contracts

```
src/
  BackstopHook.sol          v4 hook: beforeSwap (tax+snapshot), afterSwap (predicate+settle),
                             beforeAddLiquidity/beforeRemoveLiquidity (checkpoint)
  BackstopRegistry.sol       bond custody: deposit/withdraw/slash/eligibility
  InsuranceVault.sol         ERC-6909 reserve accounting: fund/claim, growth-index per pool+currency
  libraries/
    AttributionLib.sol       transient per-pool window state machine (pure slot math + tstore/tload)
    PredicateLib.sol         pure math: displacement/reversal/match, no storage, no external calls
    BondLib.sol              pure math: slash sizing, tax sizing, saturating premium calc
    InsuranceLib.sol         pure math: growth-index update/entitlement calc (mirrors feeGrowthInside)
  interfaces/
    IBackstopHook.sol
    IBackstopRegistry.sol
    IInsuranceVault.sol
  types/
    BackstopTypes.sol        shared structs/enums (WindowState, Config)
```

Every library is storage-free and externally-call-free except `AttributionLib` (which only touches
`tstore`/`tload`, no `SLOAD`/`SSTORE`, no calls) — this keeps `PredicateLib`/`BondLib`/`InsuranceLib`
independently fuzzable and formally reasoned about in isolation, per §15 of the brief.

## Why three contracts, not one

- **`BackstopHook`** must be deployed at a mined address (permission bits in the low 14 bits of the
  address). Bond custody and reserve accounting have no such constraint — bundling them into the
  hook would force every config/bond/reserve change to go through a hook-mining-constrained
  contract for no reason, and would make the hook's own storage layout (already constrained by v4's
  `extsload`-friendly slot ordering for anything StateLibrary-style external readers might want)
  needlessly large.
- **`BackstopRegistry`** is pool-agnostic — one registry can back multiple protected pools/hooks
  sharing the same bond asset, avoiding duplicated bond bookkeeping if Backstop is deployed across
  more than one pool.
- **`InsuranceVault`** is the only contract that touches PoolManager's ERC-6909 balance/claim
  surface on behalf of LPs; isolating it means the growth-index math (the most economically
  sensitive code in the system) has a single, auditable home rather than being interleaved with hook
  callback control flow.

The hook calls into the registry and vault as an authorized caller (`onlyHook` modifiers on the
state-changing entrypoints of both); neither the registry nor the vault ever calls back into the
hook, so there is no cross-contract reentrancy cycle to reason about.

## Callback flow

```
searcher/router calls PoolManager.unlock(data)
  └─ unlockCallback: PoolManager.swap(key, params, hookData)
       ├─ beforeSwap(sender, key, params, hookData)
       │    ├─ eligible = BackstopRegistry.isEligible(sender)
       │    ├─ if eligible: tax = BondLib.computeTax(tx.gasprice, block.basefee, config)
       │    │                returns toBeforeSwapDelta(0, tax)   [requires BEFORE_SWAP_RETURNS_DELTA]
       │    ├─ AttributionLib.snapshotBeforePrice(poolId) → sqrtP0 (always, cheap, needed either way)
       │    └─ if eligible ∧ |Δprice from AttributionLib.lastKnown| ≥ minDisplacement:
       │         AttributionLib.openWindow(poolId, sender, zeroForOne, sqrtP0, sqrtP1)
       │       else if window open ∧ sender == displacer ∧ opposite direction:
       │         evaluate PredicateLib.matches(...) → close window, mark pending settlement
       │       else if window open ∧ same direction ∧ sender != displacer:
       │         AttributionLib.accumulateVictim(poolId, amount)
       │
       ├─ [pool executes the actual swap]
       │
       └─ afterSwap(sender, key, params, delta, hookData)
            ├─ if beforeSwap minted a tax delta: poolManager.mint(vault, currency.toId(), tax)
            └─ if a MATCH was flagged in beforeSwap for this call:
                 slashed = BackstopRegistry.slash(displacer, slashBps)
                 poolManager.mint(vault, currency.toId(), slashed)
                 InsuranceVault.fund(poolId, currency, slashed)   // updates rewardGrowthX128
```

**Why the predicate is evaluated in `beforeSwap`, not `afterSwap`:** the pre/post *price* either
side of the opening leg is what defines displacement, and `beforeSwap` is the only callback that
sees the pool's price *before* the current swap executes (`afterSwap` only sees the result). The
closing leg's reversal fraction needs the price after the closing swap too, which is only known
once that swap itself resolves — so the *evaluation* of whether the closing leg reversed enough
happens in that closing swap's own `afterSwap` (where the post-close price is finally known),
using the pre/open/close prices already snapshotted by the two `beforeSwap` calls that bracket it.
Settlement (slash + fund) happens in `afterSwap` because it is the only callback allowed to safely
finalize PoolManager accounting for *this* swap without altering `amountToSwap` for a *different*
swap already in flight.

## Storage layout

**`BackstopRegistry`** (persistent):
```solidity
mapping(address => uint256) public bond;
address public immutable bondAsset;
uint256 public immutable minBond;
address private immutable deployer;   // may call setHook exactly once
address public hook;                  // only authorized slasher, wired post-deploy — see below
```

**`InsuranceVault`** (persistent):
```solidity
mapping(PoolId => mapping(Currency => uint256)) public rewardGrowthX128;
mapping(PoolId => mapping(bytes32 positionKey => mapping(Currency => uint256))) public checkpointGrowthX128;
mapping(PoolId => mapping(bytes32 positionKey => mapping(Currency => uint256))) public owed;
IPoolManager public immutable poolManager;
address private immutable deployer;
address public hook;
```

**Why `hook` isn't `immutable`:** `BackstopHook`'s constructor requires the registry's and vault's
addresses (they're immutables *it* stores). The registry and vault symmetrically want the hook's
address to restrict `slash`/`fund`/`checkpoint` to it. Three-way circular constructor dependencies
aren't expressible with plain `immutable` fields without CREATE2 address-prediction for all three
contracts. The resolution: registry and vault are deployed first (their constructors don't need the
hook), the hook is deployed (mined) third using their now-known addresses, and the deploy script
immediately calls `registry.setHook(hookAddr)` / `vault.setHook(hookAddr)` — each callable exactly
once, only by the original deployer (`msg.sender` at that contract's own construction), and reverting
if called again. This is a standard, minimal two-phase-init pattern, not a general-purpose
upgradeability backdoor — there is no way to change `hook` once set.

**`BackstopHook`** (persistent — config only, no per-swap state):
```solidity
IPoolManager public immutable poolManager;
BackstopRegistry public immutable registry;
InsuranceVault public immutable vault;
Config public config;   // owner-settable: taxBps, minFlatTax, maxTax, slashBps,
                         // minDisplacementBps, minVictimNotional, minReversalBps
```

**Transient (per pool, `AttributionLib`)** — see MECHANISM.md `Window` struct. Packed into 2 storage
words using `tstore`, addressed as:
```
slot0 = keccak256("backstop.window.meta",  poolId)   // open|displacer|zeroForOne packed
slot1 = keccak256("backstop.window.price", poolId)   // sqrtPriceOpenX96|sqrtPriceAfterOpenX96 packed
slot2 = keccak256("backstop.window.notional", poolId) // victimNotional
```
following the exact `keccak256(target, key)` derivation pattern `CurrencyDelta.sol` already uses in
v4-core, so there is precedent for this being a safe, collision-free approach at the same trust
level as v4's own internals.

## Security boundaries

- `BackstopRegistry.slash` and `InsuranceVault.fund`/mint-authority are `onlyHook` — only the
  specific deployed `BackstopHook` address can trigger value movement out of a bond or into the
  reserve's growth index. Neither function is reachable by an LP, searcher, or arbitrary contract.
- `InsuranceVault.claim` is the **only** function an LP calls directly, and it only ever reads
  PoolManager state (`StateLibrary`, view-only) and moves the vault's *own* already-minted ERC-6909
  balance — it never calls `mint`/`take`/`burn` against PoolManager on the LP's behalf, so it never
  needs `onlyWhenUnlocked` access (see ARCHITECTURE_VALIDATION.md #4).
- `BackstopHook`'s external entrypoints other than the `IHooks` callbacks are `onlyOwner`
  configuration setters; there is no path for an arbitrary caller to alter `config`.
- All PoolManager-facing hook callbacks assert `msg.sender == address(poolManager)` — the standard
  v4 hook guard against a contract impersonating the manager to fire callbacks directly.

## External dependencies

`v4-core` (pinned `v4.0.0`) only, for the protocol and types. No `BaseHook` dependency (removed from
the pinned `v4-periphery`, see ARCHITECTURE_VALIDATION.md #9). No oracle. No AVS. `v4-periphery` is
used **only** in tests/scripts (e.g. `PositionManager`/routers for building realistic swap
transactions), never linked into the deployed contracts.

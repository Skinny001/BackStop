# UHI10 Hookathon · Project Brief

## Backstop

**The attacker funds the insurance that pays the LP.**

A Uniswap v4 hook where searchers bond for a priority lane; a priority tax and slashed bonds fund an on-chain LP insurance pool that pays LPs automatically the instant a same-block sandwich pattern is observed.

| Field | Detail |
|---|---|
| Track | UHI10 — Sustainable Liquidity & MEV Protection |
| Hook category | Sandwich neutralization + protocol-native recapture (fused) |
| Core primitive | Bonded execution + parametric LP insurance from slashing and priority tax |
| Chain | Unichain (mainnet target); Unichain Sepolia (hackathon deploy) |
| Root cause attacked | Contestable, unassigned execution/priority rights; LPs have no recourse |
| One-sentence pitch | Searchers bond for priority; sandwich attempts are slashed to an LP insurance pool that auto-pays. |

## Overview

Backstop fuses the two halves of the hackathon's win condition — defense and recapture — into a single coherent primitive. Searchers who want priority access to a protected pool post a bond. A priority tax is levied on that lane, and any bond slashed for a detected same-transaction sandwich pattern is paid into an LP-facing insurance pool. When the observable displacement pattern fires, the pool pays affected LPs automatically, on-chain, with no claim and no oracle. The bond is the deterrent; the slash is the LP's payment. One mechanism does both jobs.

The design is deliberately scoped to what a Uniswap v4 hook can actually observe and prove synchronously. It does not claim to detect every sandwich or to prove intent; it charges for priority and places bonded capital behind a narrowly defined, objectively observable same-transaction execution pattern. That honesty is what makes the claim defensible.

## Problem Statement

Sandwiching and toxic ordering exist because AMM trades live inside a competitive ordering market where adjacency to a victim is purchasable and the right to go first is unassigned. Existing defenses fall into two camps, each half a solution:

- **Shields without recapture:** randomized delay and commit-reveal break sandwich timing but return nothing to LPs and degrade UX.
- **Recapture without a shield:** LVR auctions redistribute value but do not stop sandwiching and are heavily over-built (53 prior submissions).
- **Export:** private orderflow protects the swapper but routes value to fillers and wallets and starves on-chain LPs.

And LPs, the party bearing the risk, have no direct recourse when they are picked off. There is no on-chain market that turns the attacker's own capital into an LP backstop.

## Solution

Backstop creates a bonded execution lane with a parametric LP insurance pool behind it.

- **Bond:** a searcher posts capital for priority access to the protected pool — skin in the game.
- **Priority tax:** the lane levies a tax on `tx.gasprice − block.basefee`, monetizing priority regardless of intent, paid to the pool.
- **Attribution:** the hook recognizes a narrow, same-transaction round-trip-around-a-displaced-victim pattern — the only case where attribution is clean because all legs share one transaction and EIP-1153 transient storage can carry state across them.
- **Parametric payout:** when the pattern fires, the slashed bond funds an automatic payout to affected LPs — no claim, no oracle, capped at funded reserves.

## How It Works

- **Enrollment:** a searcher deposits a bond and is granted priority-lane access; bonds are tracked in persistent storage.
- **beforeSwap:** levy the priority tax (`tx.gasprice − basefee`) via `BeforeSwapDelta`; record the pre-trade price into transient storage for same-transaction attribution.
- **Within the same transaction:** if a subsequent leg reverses a displacement created around an intervening victim swap beyond a minimum notional and reversal fraction, mark the pattern matched.
- **Settlement:** slash the bond, credit the LP insurance pool, and pay affected LPs pro-rata — all atomic, all on-chain.

Scope is stated explicitly: cross-block sandwiches, JIT-liquidity sandwiches, and proof of common control across addresses are out of scope by design, because they cannot be honestly proven from swap observations. The mechanism underwrites an observable pattern, not an intent.

## Architecture

| Component | Design |
|---|---|
| Hook callbacks | `beforeSwap` (priority tax + pre-trade snapshot), `afterSwap` (pattern check + settlement) |
| Attribution state | EIP-1153 transient storage — valid because attribution is same-transaction only |
| Bond registry | Persistent storage; deposit / slash / withdraw lifecycle |
| Insurance pool | ERC-6909-accounted reserve; parametric payout capped at reserves |
| Priority rail | `tx.gasprice − block.basefee` (Unichain competitive priority ordering; fail closed elsewhere) |
| Predicate | Min displacement, min victim size, min reversal fraction — tuned to exclude directional arbitrage |

## Impact

- **For LPs:** a guaranteed on-chain backstop funded by attackers — protection becomes a payout, not a promise.
- **For traders:** the bonded lane and priority tax raise the cost of predatory ordering, reducing sandwich pressure on the pool.
- **For Uniswap / DeFi:** the first on-chain parametric insurance primitive for LPs — an entirely new safety product native to the AMM.

## Why It Matters

Backstop turns the attacker's capital into the LP's safety net and does it with a mechanism honest about its own limits. It is the cleanest expression of the theme's stated win condition — a shield and a redistribution in one primitive — and it introduces a genuinely new object to DeFi: parametric, claimless, oracle-free LP insurance settled inside the pool.

## Novelty & Differentiation

| Prior art | How Backstop differs |
|---|---|
| AsyncSwap / commit-reveal delay | Shields only, no recapture, UX cost; Backstop pays LPs from the attacker's bond |
| LVR / AVS auctions | Redistribution only, no sandwich defense, over-built and off-Unichain; Backstop needs no AVS |
| Searcher bonding (UHI10 whitespace) | Reframed from unprovable "sandwich detection" to a bonded observable pattern + parametric insurance |
| Private orderflow | Value leaves LPs; Backstop keeps recapture and payout in the pool |

## Feasibility & Technical Reality

- **Synchronous in-call:** pre/post price, swap size, `tx.gasprice`, `block.basefee`.
- **Same-transaction state:** EIP-1153 transient storage — valid because all legs share one transaction (this is the key scoping decision).
- **Persisted:** bond registry and insurance reserve.
- **Build:** pure Solidity, no oracle, no AVS — the safest solo build of the three; strong Unichain Sepolia demo.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Predicate false-positives on directional arbitrage | Require same-transaction round-trip + reversal fraction; directional arb does not round-trip around a victim in one tx |
| Cross-block / cross-address evasion | Explicitly out of scope; claim is same-block same-transaction underwriting, stated honestly |
| Searcher rationally eats the slash | Bond sized as a configurable economic floor; priority tax captures value even when slash does not fire |
| Insurance-pool insolvency | Payouts capped at funded reserves; parametric, promises nothing beyond reserves |

## Demo / Wow Moment

A searcher bonds, attempts a same-block sandwich against a victim swap in the demo, the hook recognizes the displacement pattern, slashes the bond, and an LP receives an automatic on-chain insurance payout — reserve balance updating live, no claim filed.

Differentiation: "an LP is paid out on-chain the instant a same-block sandwich pattern is observed, funded by the attacker's bonded capital, with zero oracle and zero AVS."

## Rubric Scorecard

| Criterion (weight) | Score | Rationale |
|---|---|---|
| Original Idea (30%) | 4 / 5 | Novel fusion + first on-chain parametric LP insurance; bonding is listed whitespace |
| Unique Execution (25%) | 4 / 5 | Transient-storage same-tx attribution + ERC-6909 insurance accounting |
| Impact (20%) | 4 / 5 | Direct LP backstop; reduces sandwich pressure |
| Functionality (15%) | 5 / 5 | Pure Solidity, no oracle/AVS, safest build, clean end-to-end demo |
| Presentation (10%) | 5 / 5 | The automatic payout is an unforgettable live beat |

# ADR-0012 — Settlement refuses to run without enough gas

Date: 2026-07-28 · Status: accepted

## What happened

Settling a series on a local Base fork voided it. Every precondition checked out: 29 genuine
observations against 12 required, 133 944 seconds of history against a 3 600-second window, and
both source calls returning correct data when made as `eth_call` immediately beforehand.

The same call with an explicit `--gas-limit` settled normally.

## Why

`settle` wraps its source reads in `try/catch` so that a broken source voids the series rather
than freezing it. That is the right behaviour and it created the hole.

`eth_estimateGas` searches for the **cheapest gas at which the transaction succeeds**. Falling
into the catch and voiding is a success by that definition — the transaction does not revert,
it just produces the wrong outcome — and it costs roughly half of what reading the series costs.

So the estimator returned a figure sufficient only for the void. Every wallet would have done
the same thing:

```
settle → estimateGas → ~400k → sampleSeries runs out → catch → VOIDED → deposits refunded
```

Nothing reverts. Nothing looks broken. The winning side simply gets a refund instead of a
payout, and the number that should have settled never does.

## Why the test suite missed it

156 tests, two invariant suites, twelve fork tests against the real pool — all of them call
`settle` with effectively unlimited gas. The cheap path was never taken because nothing ever
constrained the budget. The failure needs a real `eth_estimateGas` against a real node, which is
exactly what a local fork provides and a unit test does not.

This is the argument for the fork stage of the dApp plan, stated as a fact rather than a
prediction.

## Decision

Check `gasleft()` before starting, and revert if it is short:

```solidity
needed = (samples * GAS_PER_SAMPLE + GAS_SETTLE_OVERHEAD) * 64 / 63;
if (gasleft() < needed) revert InsufficientGasToSettle(needed, gasleft());
```

This removes the cheap path entirely. Below the threshold the transaction **reverts** rather
than voiding, so the estimator does not count it as a success and keeps searching until it funds
the real work.

The 64/63 is EIP-150: a call receives 63/64 of the gas available to its caller, so the caller
needs proportionally more than the callee will spend.

Applied to both entry points. `redeem` settles lazily, so leaving it unguarded would just move
the hole: a redeemer would void the series on the way to collecting from it.

## Rejected

**Removing the try/catch.** It exists so a dead source cannot freeze a fully collateralised
series, which is a worse failure than this one.

**A fixed gas floor.** Cost scales with the grid — 12 points and 256 points are an order of
magnitude apart — and a single number would either strand large grids or under-protect small
ones.

**Documenting a recommended gas limit.** Puts the burden on every caller and every wallet, and
fails silently when ignored. Guards belong in the contract.

## Consequences

- Settling a 256-point series now requires ~11.9M gas available. That is affordable on Base and
  is a real constraint on L1 — one more reason the protocol targets L2.
- `InsufficientGasToSettle(needed, available)` says exactly what to do, unlike a silent void.
- Four tests pin it, including one that reproduces the original failure by handing `settle`
  precisely the budget an estimator would have chosen.

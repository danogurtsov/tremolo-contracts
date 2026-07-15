# Measurement — what formal verification could and could not prove

**Date:** 2026-07-28 · **Reproduce:** `make verify` · **Tool:** halmos 0.1.13

Three properties are proven symbolically. Four are not, and the reason is worth more than the
three that are.

---

## Proven

| Property | Time | Why it discharges |
|---|---|---|
| `check_depositsSumToPot` | 1.0s | Structural: `shortCollateral` is the remainder of the pot, so the identity holds without evaluating any division |
| `check_annualiseDoesNotOverflow` | 0.7s | Bounded accumulator — a tick delta cannot exceed 2×887 272 and the grid cannot exceed 256 points, so the sum of squares is under 8.1e17 |
| `check_minIsBoundedByBothArguments` | 0.1s | Pure comparison, no arithmetic |

Domains cover the entire reachable parameter space: strike ≤ 100e18 (1000% annualised vol),
cap 1.05×–10×, notional ≤ 1e30 — all enforced by `createSeries`. These are proofs about the
protocol, not about a convenient subset of it.

## Not proven, and why

| Property | Status |
|---|---|
| `payoutsSumToPot` | timeout |
| `payoutMonotoneInVariance` | timeout |
| `payoutIsCapped` | timeout |
| `notionalRoundsTowardsThePool` | timeout |

All four reduce to the monotonicity of `a * n / 1e18`. The escalation, in order:

```
uint256 args, 20s budget                     4 of 6 timed out
uint128 args, 60s budget                     the same 4 timed out
concrete cap and notional, symbolic strike   timed out
300s budget on a single property             timed out
isolated one-line lemma:
  a <= b  =>  a*n/1e18 <= b*n/1e18           timed out at 70s
```

The last line is the diagnosis. It is not expression size, property shape, or budget: **fixed-
point division is expensive to reason about in bitvector arithmetic**, and every one of these
properties has a division between its inputs and its comparison.

## What stands in for them

- `testFuzz_payoutsSumToCollateral`, `testFuzz_payoutMonotoneInVariance`,
  `testFuzz_notionalRoundingDirections` — 50 000 runs each under the `ci` profile.
- `invariant_payoutsSumToCollateral` and `invariant_payoutRespectsCap` — asserted after every
  step of every sequence, in both invariant suites.

That is weaker than a proof, and it is labelled as weaker rather than reported as equivalent.

## How to close the gap

Either a solver that handles fixed-point division — worth retrying as halmos matures — or
restating the payoff so no division sits between the inputs and the comparison. The second is
possible: comparing `min(rv, ceiling) * notional` against `ceiling * notional` before dividing
would make the property structural. It has not been done because it would complicate the code
to suit the tool, and the code is what gets audited.

## Note on `certora/`

The directory was created empty as a placeholder. It has been removed: an empty directory named
after a verification tool claims work that does not exist, which is worse than not claiming it.

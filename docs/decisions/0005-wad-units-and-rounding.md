# ADR-0005 — Positions are WAD-denominated, and rounding is deliberately asymmetric

Date: 2026-07-27 · Status: accepted

## Context

Subscription is matched pro rata: `matched = min(subscribedLong, subscribedShort)`, and each
side is filled at `matched / subscribed`. The first implementation counted positions in whole
units and stored the fill as a WAD factor.

Both choices turned out to be wrong, and neither was found by reading the code. The invariant
suite found them, at 512 runs and depth 128 — a length the default profile does not reach.

### Failure 1: a floored fill factor loses a whole unit

```
long  subscribes 1 unit,  short subscribes 3 units    ->  matched = 1
fillShort = 1e18 / 3 = 333333333333333333

mintPositions(short): 3 * fillShort / 1e18
                    = 999999999999999999 / 1e18
                    = 0                            <- a whole matched unit vanishes
                      refund = full 180 USDC deposit

mintPositions(long):  1 position, no refund
```

The short side walked away with its entire deposit while the long side kept a fully matched
position. At `RV >= cap*K` the long was owed 100 USDC against a pool holding 40.

Pro-rata over indivisible units cannot be exact, and the residue does not land on rounding —
it lands on solvency.

### Failure 2: the fill denominator kept moving

`mintPositions` divided by `matchedUnits`, which **decreases** as positions are netted. A
subscriber who minted after somebody else had netted was measured against a smaller matched
figure, and received a proportionally larger refund — collateral that was still backing a
position somebody else held.

```
long: A 50, B 50   short: C 100   ->  matched = 100
A and C mint in full. C sends 50 short to A; A nets 50  ->  matchedUnits = 50, pool 5000
B mints: 50 * 50/100 = 25 positions, refund = 1000     ->  pool 4000
Outstanding: B long 25, C short 50.  At RV = 0 the short side is owed 5000.
```

## Decision

1. **Positions are WAD-denominated.** A unit is `1e18`, with a `MIN_SUBSCRIPTION` floor. The
   pro-rata residue drops from one whole unit to one wei.
2. **Store the numerator and denominator, not a pre-divided factor:** `matchedAtActivation`,
   `longAtActivation`, `shortAtActivation`. `matchedUnits` remains as the live counter, and is
   never used for distribution.
3. **The refund is a share of the deposit, not a function of minted units.** Minting rounds
   down; the refund takes `paid * (total - matched) / total`, also down. The matched share of
   every deposit therefore stays in the pool even when the position it backs rounds down.
4. **Rounding is asymmetric on purpose:** deposits round up, withdrawals and payouts round down.

Point 4 has its own reason. With symmetric rounding, a subscription could be withdrawn in
slices for more than it cost, because `ceil(a+b)` can be one wei below `ceil(a) + ceil(b)`, and
that wei comes out of another user's collateral. Two fuzz tests now pin this: a full round trip
costs at most one wei, and sliced withdrawals never exceed the deposit.

## Rejected

**Keeping whole units and refusing awkward fills** — rejected: it makes valid subscriptions fail
for arithmetic reasons, and the rule ("your size must divide the matched amount") is not one a
user can satisfy in advance.

**Distributing the residue by iterating over subscribers** — rejected: unbounded loops over a
user-supplied set, for a wei.

## Consequences

- `decimals` on position tokens is 18, and every amount in tests is scaled accordingly.
- Every rounding direction favours the pool. Dust accumulates in the series and can only make
  it more solvent.
- The default test profile did not reach either failure. The `pr` and `ci` profiles exist for
  this reason, and "invariants pass locally" is not a claim worth making on its own.

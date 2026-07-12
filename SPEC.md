# Specification

Mechanics and conventions of a Tremolo variance series. Where this document and the code
disagree, the code is authoritative and this document is a bug.

---

## 1. The quantity being settled

Annualised realized variance over the series window:

```
RV = (SECONDS_PER_YEAR / window) * SUM_{i=1..N} [ ln(P_i / P_{i-1}) ]^2
```

**Conventions, stated because every one of them is a choice someone could make differently:**

| Convention | Choice | Note |
|---|---|---|
| Year length | 365 days, exactly | Not 252 trading days: crypto has no closed days |
| Returns | log returns | Not simple returns |
| Mean | not subtracted | Standard for variance swaps; the drift term is left in |
| Divisor | window in seconds | Not `N-1`, not `N`; see below |
| Series | geometric TWAP per grid step | Not spot at grid points |
| Sampling | evenly spaced over the window | Remainder is absorbed into the first interval |

**On the divisor.** The textbook form is `(A/N) * SUM` with `A` the number of periods per year.
With `A = SECONDS_PER_YEAR / dt` and `dt = window / N`, this reduces to
`SUM * SECONDS_PER_YEAR / window`. The grid step cancels. The result therefore does not depend on
how finely the window was sampled — only on the window. Sampling frequency still affects the
*estimate* (see §6), but not the scaling.

## 2. Payoff and collateral

```
ceiling      = cap * K
RV_effective = min(RV, ceiling)

longPayout   = notional * RV_effective
shortPayout  = notional * ceiling - longPayout

longDeposit  = notional * K                    (maximum loss, at RV = 0)
shortDeposit = notional * (cap - 1) * K        (maximum loss, at RV >= ceiling)
pot          = longDeposit + shortDeposit = notional * ceiling
```

`longPayout + shortPayout = pot` for every possible `RV`. This identity is what removes
liquidation from the design and is asserted continuously by the invariant suite.

**Rounding.** Deposits round **up**; withdrawals, payouts and minting round **down**.
`shortDeposit` is defined as the remainder of the pot so the two deposits sum exactly.

Symmetric rounding would let a subscription be withdrawn in slices
for more than it cost, since `ceil(a+b)` can be one wei below `ceil(a) + ceil(b)` — and that wei
would come from another user's collateral. A full-size round trip costs at most one wei, and the
wei stays in the series.

**Units.** `notionalPerUnit` is collateral tokens per 1.0 of variance, per whole unit. Positions
are WAD-denominated: one unit is `1e18`, with a minimum subscription of `0.0001e18`. Whole units
were tried first and rejected: pro-rata matching cannot be exact over indivisible units, and the
residue shows up as a solvency hole.
Worked example, the one used throughout the tests:

```
K = 0.04 (20% annual vol), cap = 2.5, notionalPerUnit = 1000 USDC

longDeposit  = 1000 * 0.04       =  40 USDC
shortDeposit = 1000 * 1.5 * 0.04 =  60 USDC
pot                              = 100 USDC

RV = 0.09 (30% vol)  ->  long receives 90, short receives 10
RV = 0               ->  long receives  0, short receives 100
RV >= 0.10           ->  long receives 100, short receives 0
```

## 3. Lifecycle

```
                 activate()                    settle()
  SUBSCRIBING ───────────────► ACTIVE ─────────────────► SETTLED
       │                          │
       │                          └── source failed ───► VOIDED
       │
       └── one side empty ──────────────────────────────► CANCELLED
```

| State | Entered when | What is possible |
|---|---|---|
| `SUBSCRIBING` | creation | `subscribe`, `unsubscribe` |
| `ACTIVE` | `activate()` after `startTime`, both sides non-empty | `mintPositions`, `net`, transfers |
| `SETTLED` | `settle()` after `expiry`, window dense enough | `redeem` at the formula |
| `VOIDED` | source reverted, or window too sparse | `redeem` at deposit |
| `CANCELLED` | activation with one side empty | `unsubscribe` in full |

**Matching is pro rata.** `matchedUnits = min(subscribedLong, subscribedShort)`; each side is
filled at `matched / subscribed`. The unmatched remainder is refunded when positions are minted.
A queue would require iterating over subscribers, which does not scale and is not needed.

Distribution reads the **activation snapshots** (`matchedAtActivation`, `longAtActivation`,
`shortAtActivation`), never the live `matchedUnits`, which falls as positions are netted. The
refund is computed as a share of the deposit rather than from the minted amount, so the matched
share of every deposit stays in the pool even when the position it backs rounds down.

**Claims never expire.** There is no deadline on `redeem` and no sweep of unclaimed funds.

## 4. Parameter validation at creation

Immutable parameters mean a wrong series is wrong forever, so creation is strict:

| Parameter | Constraint | Why |
|---|---|---|
| `startTime` | strictly future | there must be a subscription window |
| `window` | 1 hour .. 365 days | |
| grid step | >= 60 seconds | finer than blocks are reliable |
| `strike` | 0 < K <= 100e18 | upper bound is 1000% annual vol |
| `capMultiple` | 1.05x .. 10x | at 1.0x the short deposit is zero |
| deposits | both non-zero | rounding must not hand out free exposure |
| `minCompletenessBps` | <= 10000 | |
| source | `validateSource` passes | buffer must span the window with headroom |

## 5. Settlement procedure

1. Require `ACTIVE` and `block.timestamp >= expiry`.
2. Ask the observer how many genuine recordings fall inside the window. If
   `real * 10000 < samples * minCompletenessBps`, the series **voids**.
3. Read the tick series in one call and compute `RV`.
4. If either observer call reverts, the series **voids**.

Voiding returns deposits. Settling on a series that is mostly interpolation would pay out
on an artefact, and would make killing a source a profitable strategy.

## 6. Known bias

Uniswap interpolates linearly between genuine recordings. A dense grid over a quiet pool yields
an artificially smooth series and **understates** realized variance. The protocol reports
completeness rather than correcting the number.

The related structural fact: a fixed-size ring buffer is overwritten faster the busier the pool
is, so **the deepest pools have the shortest memory**. Liquidity depth, which protects against
manipulation, works against history depth. Extending a buffer is permissionless.

The magnitude of the bias as a function of pool activity is not yet measured. Until it is,
`minCompletenessBps` is set conservatively rather than derived.

## 7. Isolation between series

One contract holds every series, so isolation is something the invariant suite has to prove. A series may only ever pay out its own collateral: `collateralHeld[id]` covers
every claim against series `id` on its own, and per collateral token the sum over series equals
the contract's balance.

Stated per series because a contract-wide check nets a leak between two series out to zero
and sees nothing.

## 8. Trust boundary

The guardian may pause creation of **new** series. It cannot pause, alter, or delay `settle`,
`redeem`, `net`, or `unsubscribe` on an existing series — there is no code path. Anyone already
exposed reaches their money without permission from anyone.

Series parameters, including the observer and the price source, are immutable after creation.
Changing a source would change the quantity being measured; a new source is a new series.

# Measurement — what it costs to move realized variance

**Date:** 2026-07-28 · **Reproduce:** `forge test --match-path "test/fork/ManipulationCost*" -vv`
**Where:** Uniswap V3 WETH/USDC 0.05% on Base, block 49 000 000, real swaps on a fork

The protocol's central security claim is that settling on a time-weighted average makes
manipulation expensive. That claim was asserted in three documents and never priced. This prices it by carrying out
the attack on a fork.

---

## The attack worth defending against

A long position gains when realized variance settles high, and variance is a sum of *squared*
log returns. So an attacker does not need to move the price anywhere in particular — only to
move it, repeatedly. Direction is irrelevant, which makes this strictly cheaper than any
directional manipulation.

## 1. Depth: what a trade costs, and what it moves

Real swaps against the pool, measured as the round-trip shortfall (fees plus impact):

| USDC in | Ticks moved | Round-trip cost | Cost as % of size |
|---|---|---|---|
| 10 000 | 4 | $9 | 0.09% |
| 100 000 | 40 | $99 | 0.10% |
| 1 000 000 | **620** (6.4%) | $986 | 0.10% |
| 5 000 000 | 5 200 (68%) | $4 468 | 0.09% |

Cost tracks the 0.05% fee paid twice. Price impact is nearly free on this pool up to seven
figures: depth alone does not stop the price from moving.

## 2. The flash spike does not move the average

$1 000 000 through the pool, price pushed 620 ticks, sold straight back:

```
variance before   0.04476
variance after    0.04385
change            0 bps      (it went down)
```

**A million dollars changed the settled number by nothing.** The excursion lasted one block —
two seconds of a fifteen-minute step — so the average it landed in barely registered it.

Against a spot print, that same trade lands its full 620 ticks in the series.

## 3. The attack that works: hold the price

To move a time-weighted average you have to weight it. Push the price and keep it there for a
meaningful share of the interval — here, five minutes of a fifteen-minute step:

```
pushed                1 000 000 USDC
held away             620 ticks, five minutes
variance before       0.04476
variance after        0.70091          <- 15.7x
gain                  +146 594 bps
break-even notional   $1 524 051
```

So the attack is real. Holding a 6% dislocation for a third of one grid interval multiplies the
settled variance by nearly sixteen, and pays for itself against any long position above roughly
**$1.5M of variance notional**.

### Why the real cost is far higher than $1M

**On a fork there are no arbitrageurs.** The price stays where it is put, for free, for as long
as wanted. On a live chain, holding a 6% dislocation on the deepest ETH pool on Base for five
minutes means absorbing every arbitrage trade aimed at it for five minutes, against every other
venue quoting ETH. The $1M above is only the entry fee; the real bill includes every arbitrage trade absorbed
while holding.

Nothing here measures that. What it establishes is the **lower bound**, which is the number
a defence has to be sized against.

---

## What follows for the protocol

**1. Series size must be bounded relative to source depth.** The break-even is a ratio between
notional and pool depth, so the defence is a ceiling on notional per source; capping manipulation itself is not
available at any price.

**2. Grid step is also a security parameter.** The attack's leverage is
`hold time / step length`. Longer steps are harder to move, and separately they understate
variance (variance_bias.md). The two pull in
opposite directions and the trade-off is now quantified on both sides.

**3. Completeness is not a manipulation defence.** A held price produces plenty of genuine
observations; `minCompletenessBps` catches dead sources, not manipulated ones.

## Not yet measured

- The same attack on a thinner pool, where the entry fee is far lower.
- What arbitrage actually costs an attacker holding a dislocation — needs simulated
  counter-traders, and is the single largest unknown in this document.
- Whether a truncated-tick source changes the picture. It caps per-block movement, which would
  blunt the flash spike (already harmless here) while doing nothing about a held price.

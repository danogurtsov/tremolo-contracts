# Measurement — settlement cost and the price of history

**Date:** 2026-07-28 · **Reproduce:** `forge test --match-path "test/fork/*" -vv`

Measured against the real Uniswap V3 WETH/USDC 0.05% pool on Base
(`0xd0b53D9277642d899DF5C87A3966A349A798F224`) at block **49 000 000**, base fee
**0.005 gwei**, ETH assumed at $3 000.

This is not a benchmark for its own sake. Two protocol parameters were set from it, and one of
them had to be changed.

---

## 1. What the pool actually looks like

| Property | Value |
|---|---|
| `observationCardinality` | 5 000 |
| History the buffer holds | 116 828 s = **32.5 hours** |
| Average gap between recordings | **23 seconds** |
| Genuine recordings in a 6-hour window | 775 |

Consequences, directly:

- A **daily** series fits inside this buffer. A **weekly** one does not, and never will at this
  cardinality — the pool is too busy, which is the buffer paradox in numbers rather than in
  prose.
- At 23 seconds between recordings, interpolation is not the dominant error on this pool. That
  matters, because the design notes had assumed it was (see `variance_bias.md`).

---

## 2. Cost of reading the series

`sampleTicks` against the live pool:

| Grid points | Gas | Per point | On Base | On L1 at 20 gwei |
|---|---|---|---|---|
| 12 | 497 882 | 41 490 | $0.007 | $29.87 |
| 24 | 652 089 | 27 170 | **$0.010** | $39.13 |
| 96 | 2 479 664 | 25 829 | **$0.037** | $148.78 |
| 256 | 7 027 132 | 27 449 | **$0.105** | $421.63 |
| 512 | 17 442 934 | 34 068 | $0.262 | $1 046.58 |
| 1024 | 48 678 559 | 47 537 | $0.730 | $2 920.71 |

Cost per point is flat to about 96 and then climbs: each reading binary-searches the ring
buffer, and a deeper window means longer searches.

### What changed because of this

`MAX_SAMPLES` was **1024**, chosen because it sounded generous. At 1024 points a settlement
costs **48.68M gas** — 12% of an entire Base block (limit 400M) and more than a whole Ethereum
block. It would have shipped as a grid size that no one could ever settle at.

**`MAX_SAMPLES` is now 256**, in the adapter *and* independently in the core, so a third-party
observer with a laxer limit cannot turn settlement into a gas bomb. 256 costs ~2% of a Base
block. The recommended range is **24–96**, where the marginal cost per point is lowest.

The L1 column is the other half of the answer: settling a 96-point series on Ethereum costs
$149 against a series whose entire notional might be a few thousand dollars. **L2 is not a
preference, it is a precondition.**

---

## 3. Cost of buying more history

`increaseObservationCardinalityNext`, extending a pool that already holds 5 000 slots:

| Added slots | Gas | Per slot | On Base | On L1 at 20 gwei |
|---|---|---|---|---|
| 1 000 | 22 244 157 | 22 244 | **$0.33** | $1 334.65 |

One `SSTORE` per slot, paid once, by whoever calls it — which the protocol treats as its own
responsibility rather than someone else's.

### What this settles

The open question was whether extending buffers is a recurring operating cost that eats the
economics. On Base it is not: **$0.33 buys 1 000 slots**, and at this pool's rate of ~23 seconds
per recording that is roughly 6.4 additional hours of history. Taking a busy pool from a
one-day window to a one-week window costs on the order of a dollar, once.

On L1 the same purchase is $1 335 and the answer would be different. This is the second
independent argument for L2, arrived at from a different direction than the first.

---

## 4. What is still unmeasured

- The same profile on Arbitrum, where calldata pricing differs.
- Cost at cardinality far above 5 000, where searches lengthen further.
- Behaviour on a **thin** pool, where recordings are minutes apart rather than seconds — the
  regime where interpolation, not grid step, dominates the error.

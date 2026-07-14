# Measurement — how much variance the TWAP grid destroys

**Date:** 2026-07-28 · **Reproduce:** `python3 reference/bias_measurement.py`
**Data:** [bias_data.json](bias_data.json) · Base, block 49 000 000

The protocol settles on a series of TWAPs sampled on an even grid. Each point is an average
over its step, and averaging inside a step cancels whatever moved within it. This measures how
much.

---

## Method

Three series over the same window:

| Series | What it is |
|---|---|
| **spot** | the tick in force at each grid boundary, from `Swap` events — the price *at* the instant |
| **twap** | what `UniV3Observer.sampleTicks` returns — the price *averaged around* the instant |
| ~~all swaps~~ | every swap in order — **rejected as a reference, see below** |

The obvious reference is the sequence of every swap, and it is wrong. On the active pool
**3 187 of 3 743 swaps (85%) do not move the tick at all**: a tick is one basis point and most
swaps are smaller than that. Summing squared differences over that series measures tick
discretisation, not volatility. It reported variance ~50% *below* the grid series, which at first read as the grid
inflating variance.

Sampling spot at grid boundaries avoids this: over a 15-minute step the price has moved by many
ticks, so discretisation is negligible.

---

## Result

### Active pool — WETH/USDC 0.05%, 6-hour window

3 744 swaps, 5.8 s apart.

| Grid | Step | spot RV | twap RV | twap/spot | spot vol | twap vol |
|---|---|---|---|---|---|---|
| 6 | 60m | 0.03847 | 0.01740 | **45%** | 19.6% | 13.2% |
| 12 | 30m | 0.04886 | 0.03382 | **69%** | 22.1% | 18.4% |
| 24 | 15m | 0.07336 | 0.04476 | **61%** | 27.1% | 21.2% |
| 48 | 8m | 0.07639 | 0.04791 | **63%** | 27.6% | 21.9% |
| 96 | 4m | 0.06889 | 0.05508 | **80%** | 26.2% | 23.5% |
| 192 | 112s | 0.06831 | 0.04746 | **69%** | 26.1% | 21.8% |
| 256 | 84s | 0.05750 | 0.04609 | **80%** | 24.0% | 21.5% |

**Mean 67%, range 45–80%.**

### Active pool — 1-hour window

**Mean 64%, range 50–82%.** The effect does not depend on how long the window is.

### Thin pool — WETH/USDC 1.00%, 6-hour window

22 swaps, ~16 minutes apart. **Mean 112%, range 95–121%.**

---

## What it means

**1. The 67% matches theory.** For a Brownian path, the variance of
differences of interval averages is exactly **2/3** of the variance of differences of endpoints.
Measured: 67% on a six-hour window, 64% on a one-hour window, on live ETH. Theory and data agree
to within the measurement's own scatter.

**2. Realized variance settled by this protocol is systematically about one third below spot
realized variance.** This follows from the definition, and it is only benign if everyone pricing the instrument
knows it.

**3. On a thin pool the effect vanishes** (112%). With 16 minutes between swaps there is nothing
inside a step to average away; both series degenerate to the same handful of price changes. So
the bias is governed by **step length relative to trading frequency**, not by "sparse pools bias
downward", which is what the design notes had assumed.

**4. The original hypothesis was half right.** Interpolation was blamed; averaging is the actual
mechanism. The two coincide on quiet pools and diverge on busy ones, which is why the busy pool
— the one this protocol targets — shows the largest effect.

---

## Consequences for the protocol

### Pricing (the sharp one)

A market maker quoting a strike from an off-chain implied volatility — Deribit, Volmex, BVIV —
is quoting a **spot-based** number against a **TWAP-based** settlement. Realized variance will
come in roughly a third lower for reasons that have nothing to do with the market. The short
side wins systematically; the long side loses systematically.

Any strike quoted for this instrument must either be derived from TWAP-based realized variance,
or be scaled by the measured ratio. This is now a requirement on the pricing layer.

### Grid choice

Between 12 and 256 points the ratio moves within 61–80% without a clean trend — scatter, not
signal. The grid should therefore be chosen on cost and on completeness, not in the hope of
reducing bias. The recommended 24–96 range from the gas profile stands.

### Completeness threshold

`minCompletenessBps` was set to a guess. The thin pool shows what happens below roughly one
genuine recording per grid point: the series stops describing a market and the ratio becomes
erratic (95–121% with no pattern). **The floor should be one genuine observation per grid
point**, i.e. `minCompletenessBps = 10000` against `samples`. The active pool clears this by a
factor of eight (775 recordings against 96 grid points in six hours); the thin pool fails it, as
it should.

---

## Still open

- Whether the 2/3 ratio holds through a volatility spike, when the path is not Brownian.
- The same measurement on Arbitrum, and on a pair whose price is not ETH.
- Whether a **stepped** grid (spot at boundaries rather than TWAP) is worth the manipulation
  exposure it would reintroduce.

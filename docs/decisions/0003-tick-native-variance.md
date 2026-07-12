# ADR-0003 — Variance is computed from tick differences, with no logarithm on chain

Date: 2026-07-27 · Status: accepted

## Context

The instrument settles on a sum of squared log returns. The obvious implementation calls a
fixed-point `ln` per observation. That was the plan, and the open question was which library:
Solady's `FixedPointMathLib.lnWad`, PRBMath, or ABDKMath64x64 — each with a different accuracy
and gas profile, to be chosen by measurement.

The measurement was never needed, because of an identity that removes the question:

```
A Uniswap tick is defined by  P = 1.0001^tick
therefore   ln(P_i / P_{i-1}) = (tick_i - tick_{i-1}) * ln(1.0001)
```

The logarithm of a price ratio is a **linear function of the tick difference**. For a tick-based
source, no logarithm needs to be evaluated at all.

## Decision

`VarianceMath.fromTicks` sums squared integer tick differences — exact, no rounding — and applies
`ln(1.0001)^2` once, scaled at 1e36, in a single `fullMulDiv`. `fromPrices`, which does call
`lnWad`, exists only for sources that cannot express prices as ticks.

Two things this forced, both found by testing rather than by reasoning:

1. **One division, not two.** Rounding to WAD and then annualising loses up to
   `SECONDS_PER_YEAR / window` wei — 365 wei on a daily series. The differential test measured
   34 wei of error on a single-jump case before the two steps were collapsed into one.
2. **The constant needs 28 digits.** `ln(1.0001)^2` is held at 1e36 scale so the squaring itself
   contributes nothing measurable.

## Rejected

Choosing a fixed-point library by benchmark: unnecessary for the primary path. The comparison
still matters for price-based sources, and the differential suite bounds how much accuracy the
price path loses (currently under 0.5%).

Uniswap V4's `TruncatedOracle` as a source: it caps per-block tick movement, which systematically
removes exactly the moves a volatility instrument is measuring. If a truncated source is ever
used, the cap must be a disclosed series parameter.

## Consequences

- The accuracy of the primary path is limited by one division, not by an approximation.
- Tick sources are strictly preferred, and that preference is now a property of the design.
- Ticks are bounded by Uniswap's own domain (+-887272), which bounds the accumulator and makes
  overflow analysis a one-liner.

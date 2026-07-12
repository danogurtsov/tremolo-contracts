# ADR-0001 — v0 is fully collateralised, with no liquidations

Date: 2026-07-27 · Status: accepted

## Context

A variance swap has a linear payoff in realized variance, and realized variance is unbounded
above. Every existing on-chain volatility product answers that with margin: post part of the
exposure, mark to market, liquidate when the margin runs out. That answer imports a large amount
of machinery — a liquidator with a working economic incentive, a fast price source, an auction
that still clears when gas spikes, and a backstop for when it does not.

Two observations changed the shape of the problem:

- With a cap on the payout, the loss is bounded on **both** sides, not just one.
- Long's maximum loss is `notional * K`; short's is `notional * (cap - 1) * K`. Together they
  are `notional * cap * K`, which is exactly the maximum total payout.

## Options considered

| Option | Capital efficiency | Machinery required | Verdict |
|---|---|---|---|
| Partial margin + liquidation | high | liquidator incentives, fast oracle, auction, backstop | rejected for v0 |
| Full collateral, uncapped payoff | impossible | — | not viable: short's loss is unbounded |
| **Full collateral + capped payoff** | low | none | **chosen** |
| Insurance fund covering the tail | medium | fund sizing, governance | rejected: replaces a proof with a hope |

## Decision

Both sides deposit their maximum loss. The cap is a series parameter, validated at creation to
sit between 1.05x and 10x the strike.

The number that supports this: with `cap = 2.5` (the TradFi convention) and a 20% vol strike,
long posts 40 USDC and short 60 USDC per 1,000 USDC of variance notional. Total 100, which is
`notional * cap * K` exactly.

## Rejected, and under what condition to revisit

Partial margin was rejected because it makes settlement depend on things the protocol cannot
control: liquidator behaviour under stress, oracle latency, and gas markets. Revisit when there
is real volume and the capital cost is what limits growth — not before. It returns as v1, as an
opt-in module, never as a change to the v0 series semantics.

## Consequences

- Capital efficiency is poor by design. Netting exists to soften this and is the reason a market
  maker can quote both sides without doubling their collateral.
- Solvency becomes an identity provable in one line, which is what makes the invariant suite
  meaningful rather than decorative.
- No dependency on any actor being alive at any particular moment, which removes the entire
  class of failures that stress events produce.

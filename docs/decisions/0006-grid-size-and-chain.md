# ADR-0006 — Grid size is capped at 256 points, and the chain must be an L2

Date: 2026-07-28 · Status: accepted

## Context

`MAX_SAMPLES` was 1024. The number was not measured, it was chosen because it sounded generous
and left room to grow. Two questions had never been answered: what a settlement actually costs,
and whether the largest permitted grid is settleable at all.

Fork tests against the real WETH/USDC 0.05% pool on Base answered both. Full numbers in
[docs/measurements/gas_profile.md](../measurements/gas_profile.md).

## What the measurement showed

```
  12 points     0.50M gas        256 points     7.03M gas
  24 points     0.65M gas        512 points    17.44M gas
  96 points     2.48M gas       1024 points    48.68M gas
```

**1024 points costs 48.68M gas.** That is 12% of an entire Base block, and more than a whole
Ethereum block. The limit as written permitted a grid size at which no series could ever be
settled — a parameter that looked like headroom and was in fact a trap.

Cost per point is flat to roughly 96 points and climbs after: each reading binary-searches the
ring buffer, so a longer window means longer searches.

## Decision

1. **`MAX_SAMPLES = 256`**, at ~7M gas — about 2% of a Base block. Recommended range is 24–96,
   where marginal cost per point is lowest.
2. **The limit lives in the core as well as in the adapter.** A third-party observer with a
   laxer bound could otherwise make settlement unaffordable, which leaves a fully collateralised
   series permanently stuck — the one outcome the design promises cannot happen.
3. **L2 only, as a hard requirement.** Settling a 96-point series costs $0.04 on Base and $149
   on Ethereum at 20 gwei. Extending a pool's buffer by 1 000 slots costs $0.33 on Base and
   $1 335 on L1.

## Rejected

**Keeping 1024 and letting callers choose sensibly** — rejected. An immutable series with an
unsettleable grid cannot be fixed after creation, and "the caller should know better" is not a
guard rail.

**Splitting large grids across several transactions** — deferred, not rejected. It would allow
finer grids on long windows, at the cost of partial settlement state. Worth revisiting only if
someone actually wants a grid finer than 256 points, which the bias measurement does not
currently justify.

## Consequences

- Series longer than a day face a real trade-off: 256 points over a week is a 39-minute grid
  step, and coarse steps understate variance (see ADR-0007 and `variance_bias.md`).
- The L2 requirement is now supported by two independent measurements — settlement cost and
  buffer cost — rather than by a general preference for cheap chains.
- Existing unit tests that used 2 000 samples to trigger a grid-step error now trip the sample
  ceiling instead. Same outcome, stricter reason.

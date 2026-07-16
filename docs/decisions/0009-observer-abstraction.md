# ADR-0009 — The observer interface carries a scale, because a second adapter proved it had to

Date: 2026-07-28 · Status: accepted · Amends [ADR-0002](0002-lazy-series-reconstruction.md)

## Context

`IPriceObserver` existed from the start and was described as making the price source a parameter
of the instrument rather than an integration detail. It had one implementation. An interface with
one implementation is a description of that implementation with extra steps, and the only way to
find out which it was is to write a second one.

`ChainlinkObserver` is that second one. Three things surfaced.

## What the second adapter exposed

**1. The interface hard-coded a scale.** `sampleTicks` returned "ticks" because Uniswap has
ticks, and a tick is a base-1.0001 logarithm — free to difference, no logarithm on chain. A push
feed reports prices. Forcing prices into ticks means a logarithm *and* rounding to an integer
tick, discarding up to a full basis point per sample. Measured moves on a four-minute grid are a
few ticks, so that rounding would have been a large share of the signal. The abstraction would
have silently destroyed the measurement it exists to produce.

**2. History is not always indexed by time.** Uniswap answers "the price N seconds ago"
directly. Chainlink answers "round R", so finding the round in force at an instant is a search —
unbounded in principle, bounded here by `MAX_SEARCH_STEPS` and a revert rather than an
unpayable transaction.

**3. Sources are not interchangeable in quality**, and pretending otherwise would be the real
failure. Measured on the same 12-point grid: Uniswap 498k gas, Chainlink 1.37M — **2.7x**. And a
feed updates on deviation thresholds, so between updates its series is genuinely flat rather
than interpolated. On a feed with a 0.5% threshold, every move smaller than 0.5% is invisible,
which for a volatility instrument is most of them.

## Decision

1. `sampleTicks` becomes **`sampleSeries`**, and the interface gains **`seriesKind()`** returning
   `TICKS` or `PRICES_WAD`. The market dispatches to `fromTicks` or `fromPrices` accordingly.
2. `ChainlinkObserver` ships, with its limitations in its own doc comment rather than in a
   footnote somewhere else.
3. **Tick sources remain strongly preferred**, and the reason is now measured rather than
   asserted: cheaper, finer, and free of a logarithm whose error enters the result squared.

## Rejected

**Normalising everything to ticks inside each adapter.** Tidier interface, and it throws away
precision at exactly the point where precision is the product.

**Returning a struct with a scale field per sample.** Per-sample scale is meaningless — a series
has one scale — and it would cost a word per element on a 256-point grid.

## Consequences

- The interface is now genuinely source-agnostic, which it was not before, and the difference was
  invisible until something else implemented it.
- Adding a third source kind means adding a `SeriesKind`, which the market must learn to handle.
  That is a deliberate friction: a new scale is a change to what is being measured.
- Chainlink is available for assets with no on-chain venue worth trusting. For anything with a
  real pool it is the wrong choice, and the code says so where someone choosing will read it.

# Security

## Status

This code is **unaudited** and deployed only to testnets. Do not put money at risk with it.

## Reporting a vulnerability

Email dan.ogurtsov@gmail.com. Please do not open a public issue for anything exploitable.
Expect an acknowledgement within 72 hours.

## Scope

In scope: everything under `src/`.

Out of scope: `src/mocks/` (test doubles, never deployed), `lib/` (upstream dependencies —
report those upstream).

## What the protocol assumes

Stated plainly, because most of what could go wrong lives in these assumptions rather than
in the code:

1. **The price source is honest about its own history.** The protocol reads a Uniswap V3
   observation buffer and rebuilds a series from it. A source that can be made to report a
   different history can move settlement.
2. **A sparse window is detectable.** Completeness is measured by counting genuine recordings
   in the ring buffer. An adapter that cannot distinguish recorded values from interpolated
   ones degrades this check to a no-op.
3. **Collateral tokens behave like ERC-20.** Fee-on-transfer and rebasing tokens are not
   supported and will break the accounting; series should not be created with them.
4. **Integer rounding always favours the pool.** Deposits round up, payouts round down. Dust
   accumulates in the series and can only make it more solvent, never less.

## What the protocol does not assume

- No liveness requirement on keepers: there are none.
- No latency requirement on the price source: it is read once, at settlement.
- No solvency monitoring: payouts sum to deposits by construction.

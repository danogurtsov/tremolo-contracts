# ADR-0011 — Settlement is lazy, and nobody is paid to trigger it

Date: 2026-07-28 · Status: accepted

## Context

`settle` is permissionless and unrewarded. Nothing obliged anyone to call it, so a series could
sit expired for days: no money is lost, but none is paid either — and worse, the source's buffer
keeps advancing. A series that could have settled on a number eventually voids because its
window has fallen out of memory. The losing side has no reason to act, and until recently the
winning side could not even tell it had won.

## Options considered

| Option | Who pays | Verdict |
|---|---|---|
| Reward from the pot | the counterparties | rejected — breaks the solvency identity |
| Reward from an insurance fund | whoever fills the fund | rejected — a fund to govern, for a gas refund |
| External automation (Chainlink, Gelato) | the protocol, forever | rejected — a subscription and a dependency |
| **Settle lazily on `redeem`** | whoever wants their money | **chosen** |

**Why not a reward from the pot.** Deposits equal payouts exactly. Taking a keeper fee out of
that makes the series pay out less than it holds, and the identity is the whole reason there are
no liquidations. Paying for a convenience with the property the design is built on is a bad
trade at any price.

**Why nothing is needed at all.** Whoever is owed money already has the incentive, and
`accruedVariance` now lets them see they are owed it before expiry. The party with a reason to
act is exactly the party who benefits, so the incentive does not need to be manufactured.

## Decision

`redeem` settles the series first if it has expired and nobody has. The public `settle` stays —
an indexer, or a losing side wanting the number fixed at a particular moment, may still call it.

This follows Squeeth, which accrues its funding on any interaction rather than on a schedule.
The pattern generalises: state that can be derived on demand should be, and the caller who needs
it pays for it.

## Rejected

**Making `settle` internal only.** Tempting for size, but the number becoming public is an event
worth being able to trigger deliberately, and an indexer should not have to move money to
produce one.

**Settling lazily in `net` and `mintPositions` too.** `net` is only legal while ACTIVE, so there
is nothing to settle; `mintPositions` moves no collateral out and gains nothing from it.

## Consequences

- The first redeemer of each series pays about 440k gas more than the rest — roughly $0.01 on
  Base. Nobody is compensated, and at that price nobody needs to be.
- A series can still void by being left long enough for its window to fall out of the source's
  buffer. That is now a cost borne by whoever was winning and did not collect, which is the
  right place for it.
- One fewer moving part than a keeper network, a reward schedule, or a fund.

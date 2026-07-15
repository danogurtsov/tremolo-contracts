# ADR-0008 — Strikes come from signed quotes, not from whoever creates a series

Date: 2026-07-28 · Status: accepted

## Context

v0 had a settlement engine and no market. Two gaps, which turned out to be one gap:

**No price discovery.** `createSeries` took a strike as a parameter. Whoever created the series
typed a number. Nothing connected that number to what anyone was willing to trade at, and
nothing in the protocol could tell a fair strike from an absurd one.

**No way in or out on demand.** A taker could only enter during a subscription window somebody
had opened in advance, and could only exit by finding a counterparty for the opposite leg —
which nobody would take, because nobody could price it. The exit story in
[ADR-0004](0004-exit-by-netting.md) was correct in mechanism and unreachable in practice:
`net` needs someone holding both legs, and nobody accumulates both legs without a way to open
offsetting trades on demand.

## Options considered

| Option | Price discovery | Entry on demand | Verdict |
|---|---|---|---|
| Strike from an oracle of implied vol | outsourced | no | rejected — see below |
| On-chain auction per series | yes | no, batched | rejected: latency, and thin books auction badly |
| Pool of quotes (AMM for variance) | yes | yes | rejected: this is what killed the last generation |
| **Signed quotes (RFQ)** | yes | yes | **chosen** |

**Why not an implied-vol oracle.** Beyond the trust it imports, [ADR-0007](0007-twap-variance-is-the-instrument.md)
makes it actively wrong: off-chain implied vol is spot-based, settlement here is TWAP-based, and
the measured gap is about a third. An oracle would systematically misprice in the short side's
favour.

**Why not a pool.** Hegic, Ribbon, Dopex, Friktion, Lyra and Premia all ended the same way: a
pool holding unhedgeable volatility risk on behalf of passive depositors. A quote signed by
someone who chose to take that side, and who posts collateral for it in the same transaction,
does not have that failure mode.

## Decision

`RFQSettlement`, a separate contract:

- a maker signs an EIP-712 `Quote` — source, window, strike, cap, size, deadline, nonce;
- any taker fills it, in whole or in part, while it is live;
- the trade opens **immediately** with both legs funded in the same transaction.

The core gains one entry point, `openImmediate`, which creates a series that is ACTIVE from its
first block with both sides collateralised. It knows nothing about signatures.

**Separation is deliberate.** The market moves collateral and computes variance. Signatures,
nonces and deadlines are execution policy, and someone should be able to write a different
execution layer — an auction, a batch, an order book — against `openImmediate` without touching
the contract that holds the money.

## What this makes possible

A market maker can now quote both directions, open offsetting trades on demand, and net them for
full collateral at any time. That is what makes quoting an exit economically possible, and it is
what ADR-0004 assumed without providing.

## Rejected

**Putting the RFQ logic in the core.** It would save an external call and make the market a
policy contract. The audit surface of the thing holding collateral should be as small as it can
be.

**Cancelling by quote hash.** Cancellation is by nonce: a maker pulling a price should not have
to reconstruct the exact bytes they signed, and may no longer have them.

## Consequences

- The strike is now the number a counterparty stood behind, which is the only definition of a
  fair price this protocol can honestly claim.
- Series can be created by anyone at any parameters, so the registry will contain junk. That is
  acceptable: series are isolated by construction (see the multi-series invariant suite), and a
  series nobody funded costs nobody anything.
- Quote distribution is off chain and out of scope. Signatures are portable and can be relayed
  by any venue; the contract only cares that one arrived.

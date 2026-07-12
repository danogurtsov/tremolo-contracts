# ADR-0004 — Exit is by netting the opposite leg, not by a secondary market

Date: 2026-07-27 · Status: accepted

## Context

Full collateral means capital sits locked for the life of the series. The obvious complaint is
"I am in until expiry". The obvious fix — a secondary market for positions — splits liquidity
between a primary and a secondary venue and needs a price for something nobody quotes.

The property that dissolves the problem: **variance is additive**. Holding both legs of the same
series is holding nothing, whatever variance does, because the two payouts sum to the deposits
by construction.

## Options considered

| Option | Needs a counterparty | Needs a price | Verdict |
|---|---|---|---|
| **Netting the opposite leg** | any holder | no | **chosen** |
| Transferable positions (ERC-6909) | a buyer | negotiated off chain | **chosen, as the pairing** |
| Bilateral unwind at an agreed price | the original counterparty | yes | v1 |
| Protocol-computed early settlement at mark | none | yes — implied variance on chain | rejected |

## Decision

`net(seriesId, units)` burns both legs and releases the full collateral, at any point before
settlement. Positions are ERC-6909, so they transfer freely.

Together these are the exit: sell the long leg to someone who is short the same series; the buyer
nets immediately and frees capital, so they can quote a price for it. Liquidity concentrates in
the series rather than splitting across venues.

## Rejected

Protocol-computed early settlement would need implied variance for the remaining term **inside**
the contract. That drags an oracle into the core for a convenience feature, which is the opposite
of what ADR-0001 bought. Rejected outright, not deferred.

## Consequences

- Market makers can hold both sides without posting double collateral. This is what makes
  quoting an exit economically possible.
- Exit costs the spread and nothing else.
- Marking a position is available off chain from data the contract already exposes:
  `E[RV_total] = (elapsed * RV_accrued + remaining * IV_remaining) / T`.

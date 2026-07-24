# Changelog

Not yet released. Dated entries begin at the first tagged version; until then the git history is
the changelog and is written to be read as one.

## Unreleased

### Protocol

- Fully collateralised variance swaps with no liquidations: deposits equal payouts by
  construction.
- Realized variance computed on chain from a Uniswap V3 observation buffer, with no keepers and
  no logarithm — a tick is a base-1.0001 logarithm, so log returns are integer differences.
- RFQ execution: strikes come from signed EIP-712 quotes rather than from whoever creates a
  series.
- Exit by netting; positions are ERC-6909 and transferable.
- Live position reads: accrued variance and mark-to-market against a caller-supplied implied view.
- Settlement is lazy — `redeem` settles an expired series, so nobody is paid to trigger it.
- Notional capped against source depth, sized from a manipulation cost measured by carrying the
  attack out.
- Second price source (`ChainlinkObserver`), which is what forced the observer interface to
  carry a scale rather than assume ticks.

### Known limits

Listed in [README](README.md) and [THREAT_MODEL.md](THREAT_MODEL.md). The short version: no
partial margin, no perpetual variance, no external audit, rebasing collateral undetected, and
the cost of arbitrage against a manipulator is unmeasured.

# Tremolo — realized volatility, computed on chain

A variance swap whose settlement number is not quoted by anyone. The contract reconstructs the
price series itself, from an observation buffer that already exists on chain, and computes
realized variance from it.

```
RV = (SECONDS_PER_YEAR / window) * SUM [ ln(P_i / P_{i-1}) ]^2

long  receives  notional * min(RV, cap * K)
short receives  the rest of the pot
```

Both sides post their maximum loss up front. There is nothing else.

---

## Why this shape

**No liquidations.** The payoff is bounded on both sides: a long can lose at most `notional * K`
(when variance realises at zero), a short at most `notional * (cap - 1) * K` (when it exceeds the
cap). Each posts exactly that, so deposits total `notional * cap * K` — which is exactly what the
two payouts sum to. Solvency is an identity, not a property to be monitored. No liquidator, no
liquidation cascade, no auction that fails when gas spikes.

**No keepers.** Nothing is recorded during the life of the swap. At settlement, one call to
`observe()` returns the whole series, because Uniswap V3 already keeps a cumulative tick
integral. There is no scheduled write to pay for, and no window where choosing the moment of
observation is worth money.

**No oracle latency requirement.** The source is read once, after expiry. Being slow costs
nothing, because nothing depends on reacting quickly.

**No logarithm on chain.** A Uniswap tick *is* a base-1.0001 logarithm of price, so log returns
are integer tick differences. The sum of squares is exact integer arithmetic, and the only
rounding in the whole calculation is one final division. This is why tick sources are preferred
over price feeds, and it is a design decision rather than an optimisation — see
[ADR-0003](docs/decisions/0003-tick-native-variance.md).

---

## What v0 does not do

Stated up front, because the list is short and hiding it would be worse than having it.

- **No partial margin.** Capital efficiency is deliberately traded for the absence of
  liquidations. Margin is v1.
- **No early exit against the protocol.** Exit is by netting: buy the opposite leg of the same
  series and the collateral is released in full, at any time, with no price and no oracle.
  Someone has to be willing to take the other side.
- **No unmatched-subscription refund before expiry.** A partially filled subscription gets its
  remainder back when positions are minted, not on demand during the window.
- **No protocol fee.** The field is absent rather than set to zero; introducing one changes the
  settlement identity and deserves its own decision record.
- **No perpetual variance.** Fixed expiry only. Continuous funding is what made holding Squeeth
  cost ~65% a year, and that is not a mistake worth repeating without a reason.
- **Not audited.** Testnet only. See [SECURITY.md](SECURITY.md).

---

## Repository

```
src/
  VarianceMarket.sol        singleton: registry, subscription, netting, settlement, ERC-6909
  libraries/VarianceMath    the calculation and the settlement identities
  observers/UniV3Observer   rebuilds a tick series from a Uniswap V3 buffer
  types/Variance.sol        user-defined type: variance is not volatility
  interfaces/  mocks/
test/
  unit/  integration/  invariant/  differential/  helpers/
reference/
  variance_reference.py     60-digit reference implementation; Solidity is checked against it
docs/decisions/             one file per decision, with what was rejected and why
```

## Running it

```bash
forge install
forge test                      # fast local suite
make fuzz                       # longer fuzz and invariant run
make ci                         # what CI executes
make reference                  # regenerate differential fixtures
```

52 tests: unit, fuzz, differential against the Python reference, and a handler-based invariant
suite running with `fail_on_revert = true`.

## The invariants

Stated in English first, because they are the safety argument:

1. The contract's token balance equals its own ledger.
2. Nothing leaves that did not first enter — over the entire life of a series.
3. Every claim every holder could make right now is covered by collateral held.
4. Position supply never exceeds matched units.
5. Long and short payouts sum to exactly the collateral behind a matched unit.

Property 5 is the design in one line, and the reason property 3 can hold without liquidations.

## Known limitations of the measurement

Between two genuine recordings, Uniswap interpolates linearly. A dense grid over a quiet pool
therefore produces an artificially smooth series and **understates** realized variance. The
protocol does not correct for this. It measures it — `realObservations` counts genuine
recordings — and refuses to settle a window that is too sparse, returning deposits instead.

There is a second, sharper version of the same problem: **the busier a pool is, the shorter its
memory**, because a fixed-size ring buffer is overwritten faster. Depth of liquidity, which is
what protects against manipulation, works against depth of history. Extending the buffer is
permissionless and treated here as part of operating the protocol.

## Licence

MIT.

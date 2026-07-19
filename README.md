# Tremolo — realized volatility, computed on chain

A variance swap whose settlement number is not quoted by anyone. The contract reconstructs the
price series itself, from an observation buffer that already exists on chain, and computes
realized variance from it.

```
RV = (SECONDS_PER_YEAR / window) * SUM [ ln(P_i / P_{i-1}) ]^2

long  receives  notional * min(RV, cap * K)
short receives  the rest of the pot
```

Both sides post their maximum loss up front.

---

## Why this shape

**No liquidations.** The payoff is bounded on both sides: a long can lose at most `notional * K`
(when variance realises at zero), a short at most `notional * (cap - 1) * K` (when it exceeds the
cap). Each posts exactly that, so deposits total `notional * cap * K`, which is also what the
two payouts sum to, so every series stays solvent in every state. No liquidator, no
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
over price feeds.

---

## What v0 does not do

Stated up front.

- **No partial margin.** Full collateral means no liquidations, at the cost of capital
  efficiency. Margin is v1.
- **No resting order book.** Entry is by filling a signed quote (`RFQSettlement`), which opens
  both legs immediately at the strike the maker named. Quote distribution is off chain. Exit is
  by netting: sell the leg back to someone holding the other, and collateral is released in full
  with no price and no oracle.
- **No unmatched-subscription refund before expiry.** A partially filled subscription gets its
  remainder back when positions are minted, not on demand during the window.
- **No protocol fee.** There is no fee field at all; introducing one changes the
  settlement arithmetic.
- **No perpetual variance.** Fixed expiry only. Continuous funding made holding Squeeth
  cost ~65% a year.
- **Not audited.** Testnet only. See [SECURITY.md](SECURITY.md).

---

## Repository

```
src/
  VarianceMarket.sol        singleton: registry, subscription, netting, settlement, ERC-6909
  RFQSettlement.sol         EIP-712 quotes: price discovery and entry on demand
  libraries/VarianceMath    the calculation and the settlement identities
  observers/UniV3Observer   rebuilds a tick series from a Uniswap V3 buffer
  observers/ChainlinkObserver  price series from an aggregator's rounds (2.7x the gas)
  types/Variance.sol        user-defined type: variance is not volatility
  interfaces/  mocks/
test/
  unit/  integration/  invariant/  differential/  helpers/
reference/
  variance_reference.py     60-digit reference implementation; Solidity is checked against it
```

## Running it

```bash
forge install
forge test                      # fast local suite
make fuzz                       # longer fuzz and invariant run
make ci                         # what CI executes
make reference                  # regenerate differential fixtures
```

The suite: unit, fuzz, differential against the Python reference, and two handler-based
invariant suites running with `fail_on_revert = true` — one over a single series, one over
several series sharing a contract, two collateral tokens and two price sources.

Two solvency holes were found by invariants at 512 runs and depth 128, a depth the fast
local profile never reaches; neither was reachable from any scenario written by hand.

## The invariants

In English first:

1. Per collateral token, the sum of every series' ledger equals the contract's balance.
2. Nothing leaves that did not first enter — over the entire life of a series, per token.
3. Every claim every holder could make right now is covered by collateral held.
4. **Every series covers its own claims out of its own collateral.**
5. Position supply never exceeds matched units.
6. Long and short payouts sum to exactly the collateral behind a matched unit.
7. Position token ids of different series never collide.

Property 6 is why property 3 can hold without liquidations. Property 4 exists because a
contract-wide balance check would net a leak between two series out to zero and see nothing,
so isolation has to be stated per series.

## What manipulation costs

Measured by carrying it out, against the real pool on a fork:

| Attack | Spend | Effect on the settled number |
|---|---|---|
| $1M pushed and reversed in one block | $986 in fees | **0 bps** — a two-second excursion inside a fifteen-minute average |
| $1M pushed and **held five minutes** | $1M committed | **15.7x** — pays for itself above ~$1.5M of notional |

The first line is the flash attack failing. The second is the real limit: a time-weighted
average makes manipulation expensive, not impossible. The held-price figure is also a lower
bound — on a fork nobody arbitrages the price
back, and on a live chain holding a 6% dislocation on the deepest ETH pool means absorbing every
arbitrage trade aimed at it.

The defence is a cap on notional per series relative to source depth: a series may not write
more notional than moving its source one percent would cost — about **$254k** on the target
pool. It binds on aggregate size rather than per call, and collateral must be the token the
source quotes in, so the cap cannot be sidestepped by denominating a series in something else.

Full numbers: [manipulation_cost.md](docs/measurements/manipulation_cost.md)

## Known limitations of the measurement

Between two genuine recordings, Uniswap interpolates linearly. A dense grid over a quiet pool
therefore produces an artificially smooth series and **understates** realized variance. The
protocol does not correct for this. `realObservations` counts genuine recordings, and
settlement refuses a window that is too sparse, returning deposits instead.

A second version of the same problem: the busier a pool is, the shorter its memory, because
a fixed-size ring buffer is overwritten faster. Depth of liquidity, which is
what protects against manipulation, works against depth of history. Extending the buffer is
permissionless and treated here as part of operating the protocol.

## Licence

MIT.

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
- **No early exit against the protocol.** Exit is by netting: buy the opposite leg of the same
  series and the collateral is released in full, at any time, with no price and no oracle.
  Someone has to be willing to take the other side.
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
  libraries/VarianceMath    the calculation and the settlement identities
  observers/UniV3Observer   rebuilds a tick series from a Uniswap V3 buffer
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

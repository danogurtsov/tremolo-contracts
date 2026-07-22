# Measurement — would either side have made money?

**Date:** 2026-07-28 · **Reproduce:** `make backtest` · **Data:** [backtest_data.json](backtest_data.json)
**Sample:** 226 390 swaps over 276 hours (11.5 days) of Base, ending block 49 000 000
**Setup:** 6-hour windows, 24 grid points, cap 2.5×, strike from a trailing mean of the previous
six windows — the only estimator available on chain, using no information from the window it
prices.

Everything else in this repository establishes that the contract computes the right number and
cannot be drained. This asks whether the instrument is worth trading.

---

## Result

Realized volatility over the sample: **median 27.9%**, range 10.6%–57.3%. Never zero — on a pool
trading every six seconds it cannot be.

| Strike premium | Long wins | Long P&L, mean | Long P&L, median | Cap hit |
|---|---|---|---|---|
| 1.0× trailing | 35% | **−1.0%** | −36.1% | 10% |
| 1.2× trailing | 32% | −14.8% | −46.7% | 5% |
| 1.5× trailing | 22% | −29.4% | −57.4% | 5% |

P&L is per unit of collateral the long side deposited. Worst window −94.5%, best +150% (the cap).

## What it says

**1. The payoff profile is the one this instrument is supposed to have.** At a fair strike the
long side loses in 65% of windows and still comes out roughly flat on average (−1.0%), because
the wins are large and the losses are small. Frequent small losses against rare large gains is
what buying volatility looks like; a median of −36% against a mean of −1% is that asymmetry in
two numbers.

**2. The variance risk premium shows up, and it is what makes a market maker possible.** Selling
at a 20% premium turns the short side's edge from marginal into systematic: long mean P&L drops
to −14.8%, at 50% to −29.4%. Someone quoting this instrument has a reason to quote it, which is
the precondition for the RFQ layer having anyone on the other side.

**3. The cap is set about right.** It binds in 5–10% of windows. A cap that never binds is not
protecting the short side from anything; one that binds constantly makes the long side's payoff
a step function. Two.5× lands between those.

**4. Nobody buys this to make money on average — and that was always the thesis.** The intended
buyer is an AMM liquidity provider who is structurally short variance through LVR and pays for
it whether or not they hedge. For them the relevant number is not the mean, it is that the
instrument pays exactly when their LVR bill is largest. This backtest does not measure that, and
it would be the natural next one.

## What it does not say

**The sample is 11.5 days.** Forty windows is enough to see the shape of the payoff and not
nearly enough to price it. One volatile episode moves every figure in the table. Everything here
should be read as "the mechanism behaves as designed", not as "the strike rule is correct".

**The strike rule is deliberately naive.** A trailing mean is the simplest estimator that uses no
future information. A real maker would use a better one, which would move the win rates and
would not change the shape.

**Costs are excluded.** Settlement gas is about $0.10 on Base, negligible against these
notionals, but nothing here accounts for the spread a maker would actually charge.

**No stress period is in the sample.** The window covers 10.6%–57.3% annualised volatility, which
is an ordinary fortnight. The interesting question — what the cap does when realized volatility
triples in an afternoon — needs a date where that happened.

## Next measurement this suggests

Correlate settled variance against the LVR an LP on the same pool paid over the same window. If
the instrument pays when the LVR bill is largest, the product has its buyer; if the correlation
is weak, the thesis needs revisiting. That is one query away from the data already fetched here.

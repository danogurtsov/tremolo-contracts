# ADR-0007 — The instrument settles on TWAP variance, and that is a third below spot variance

Date: 2026-07-28 · Status: accepted

## Context

The design assumed one bias: Uniswap interpolates between genuine recordings, so a sparse pool
would look artificially smooth and understate variance. `minCompletenessBps` existed to catch
exactly that, with a threshold chosen conservatively because nothing had been measured.

The measurement ([variance_bias.md](../measurements/variance_bias.md)) says the assumption was
half right, and the half that was wrong matters more.

## What was measured

Against the live WETH/USDC 0.05% pool on Base, comparing the protocol's TWAP series with spot
ticks at the same grid boundaries:

```
  active pool, 6h window     twap/spot = 67%   (range 45-80%)
  active pool, 1h window     twap/spot = 64%   (range 50-82%)
  thin pool,   6h window     twap/spot = 112%  (range 95-121%)
```

For a Brownian path, differences of interval averages have exactly **2/3** the variance of
differences of endpoints. The measured 67% and 64% are that number, on live data.

The mechanism is **averaging inside the step**, not interpolation. On the active pool a genuine
observation lands every 23 seconds, so even a 4-minute grid has ~10 real recordings per step and
interpolates almost nothing — and still loses a third. On the thin pool, where interpolation is
everywhere, the effect disappears, because there is no movement inside a step to average away.

## Decision

**1. TWAP variance is the instrument, stated explicitly.** The settled quantity is realized
variance of a time-averaged price series, and it is roughly a third below realized variance of
a spot series. This goes in SPEC as a property, not a caveat.

**2. Strikes must be quoted in the same units as settlement.** A strike taken from an off-chain
implied vol — Deribit, Volmex, BVIV — is a spot-based number. Quoted unadjusted against this
settlement, the short side wins about a third of the notional for reasons unrelated to the
market. Any pricing layer must derive strikes from TWAP-based realized variance, or scale by the
measured ratio. This is a hard requirement on the RFQ work, not advice.

**3. `minCompletenessBps` defaults to 10000** — one genuine recording per grid point. Derived
rather than guessed: below that density the thin pool's ratio becomes erratic (95–121%, no
pattern), meaning the series has stopped describing a market. The active pool clears the bar
eightfold.

## Rejected

**Correcting the number by 1.5x on chain.** Rejected: 2/3 is the Brownian value, and a
volatility spike is not Brownian. A correction factor that is right on calm days and wrong on
the days the instrument exists for is worse than no correction. The bias is disclosed instead.

**Sampling spot at grid boundaries instead of TWAP.** This would remove the bias outright and is
genuinely tempting. Rejected because TWAP is what makes manipulation expensive: moving a spot
print at a known boundary costs a swap, moving a time-weighted average costs holding the price
there. **The third we lose is the price of that protection**, and stated that way it is a
reasonable trade — but it is a trade, and it should be written down as one.

## Consequences

- Historical realized-vol series computed off chain from spot data are **not** comparable to
  what this protocol settles. Any dashboard showing both must label them differently.
- The bias is now a disclosed parameter of the product rather than an unknown, which changes it
  from a risk into a specification.
- Grid size no longer needs to be chosen to minimise bias — the ratio does not trend with grid
  density in the 12–256 range. Cost and completeness decide it.

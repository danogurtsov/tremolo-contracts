# ADR-0002 — The observation series is rebuilt at settlement, not recorded during the swap

Date: 2026-07-27 · Status: accepted

## Context

Realized variance needs a series of prices. There are three ways to get one on chain.

## Options considered

| Option | How | Verdict |
|---|---|---|
| Active observations | a keeper writes the price on a schedule | rejected |
| Push feed at boundaries | read Chainlink/Pyth at each grid point | rejected for v0 |
| **Lazy reconstruction** | one `observe()` call at settlement returns the whole series | **chosen** |

Keeper-written observations bring an operational dependency and, worse, make *the choice of
moment* worth money — whoever writes the observation picks which price is recorded. A push feed
inherits someone else's trust assumptions and a heartbeat that does not line up with the grid;
under congestion it stops updating exactly when variance is highest.

Lazy reconstruction works because Uniswap V3 already maintains a cumulative tick integral.
The difference of two cumulatives over an interval is the average tick over that interval, so a
whole evenly spaced series can be recovered after the fact in a single call.

## Decision

Series are reconstructed at settlement through an `IPriceObserver` adapter. The adapter and the
source address are fixed at series creation and can never be changed — swapping the source would
silently change the quantity being measured.

## Rejected, and what it costs

The known defect of this approach, stated rather than hidden: between genuine recordings,
Uniswap interpolates linearly. A dense grid over a quiet pool produces an artificially smooth
series and **understates** variance. The protocol does not correct for it; it counts genuine
recordings via `realObservations` and voids a series whose window is too sparse.

The magnitude of that bias as a function of pool activity is the first measurement the project
owes, and it is not yet made. Until it is, the completeness threshold is a parameter chosen
conservatively rather than one derived from data.

## Consequences

- No keepers, at all.
- Manipulation requires moving a time-weighted average rather than a spot price.
- Series creation must validate that the pool's buffer can span the window, with headroom —
  a busy pool's buffer shrinks in time terms as it gets busier.

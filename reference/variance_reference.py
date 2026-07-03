"""
Reference implementation of realized variance.

This file is the source of truth. The Solidity in `src/libraries/VarianceMath.sol` is
checked against it, not the other way round.

Why it exists at all: the instrument settles on a sum of squared log returns. Any error in
the logarithm enters the result squared and then accumulates across every observation, so
"looks right" is not a standard that can be applied here. The reference computes the same
quantity in 60-digit decimal arithmetic, which is roughly 40 digits more than the on-chain
result needs, and the difference between the two is measured rather than assumed.

Run directly to regenerate the differential-test fixtures:

    python3 reference/variance_reference.py

Outputs `test/fixtures/variance_cases.json`, which `test/differential` reads.
"""

from __future__ import annotations

import json
import math
import random
from dataclasses import dataclass
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 60

WAD = Decimal(10) ** 18
SECONDS_PER_YEAR = Decimal(365 * 24 * 60 * 60)
TICK_BASE = Decimal(1) + Decimal(1) / Decimal(10_000)


def ln_decimal(x: Decimal, terms: int = 80) -> Decimal:
    """ln(x) for x near 1, by series on ln(1+u). Exact to working precision for our domain."""
    u = x - Decimal(1)
    if abs(u) >= Decimal("0.5"):
        raise ValueError("series only used near 1; ticks keep us there")
    total = Decimal(0)
    term = u
    for n in range(1, terms + 1):
        total += ((-1) ** (n + 1)) * (u**n) / Decimal(n)
    return total


LN_TICK = ln_decimal(TICK_BASE)
LN_TICK_SQUARED_E36 = int(LN_TICK * LN_TICK * (Decimal(10) ** 36))

# Mirrors VarianceMath.LN_TICK_SQUARED_E36. Asserted in the fixture generator so the two
# can never drift apart silently.
assert LN_TICK_SQUARED_E36 == 9_999_000_091_658_334_094_374_450_925, LN_TICK_SQUARED_E36


def realized_variance_from_ticks(ticks: list[int], window_seconds: int) -> Decimal:
    """
    Annualised realized variance from a tick series.

        RV = (SECONDS_PER_YEAR / window) * SUM (tick_i - tick_{i-1})^2 * ln(1.0001)^2

    A tick is already a base-1.0001 logarithm of price, so log returns are exact integer
    differences and no logarithm is ever evaluated. This is the only reason the on-chain
    path can be exact up to a single final rounding.
    """
    if len(ticks) < 2:
        raise ValueError("need at least two observations")
    if window_seconds <= 0:
        raise ValueError("window must be positive")

    sum_squares = sum((ticks[i] - ticks[i - 1]) ** 2 for i in range(1, len(ticks)))
    quadratic_variation = Decimal(sum_squares) * LN_TICK * LN_TICK
    return quadratic_variation * SECONDS_PER_YEAR / Decimal(window_seconds)


def realized_variance_from_prices(prices: list[Decimal], window_seconds: int) -> Decimal:
    """Same quantity from a price series. Used to cross-check the tick path."""
    if len(prices) < 2:
        raise ValueError("need at least two observations")
    total = Decimal(0)
    for i in range(1, len(prices)):
        r = ln_decimal(prices[i] / prices[i - 1])
        total += r * r
    return total * SECONDS_PER_YEAR / Decimal(window_seconds)


def to_wad(x: Decimal) -> int:
    """Floor to WAD, matching Solidity integer division."""
    return int(x * WAD)


def annual_vol(variance: Decimal) -> Decimal:
    """Variance -> annualised volatility, for human-readable output only."""
    return Decimal(math.sqrt(float(variance)))


# ---------------------------------------------------------------------------
# Settlement arithmetic — same identities as the contract
# ---------------------------------------------------------------------------


@dataclass
class Settlement:
    long_payout: int
    short_payout: int
    total_collateral: int

    def is_balanced(self) -> bool:
        return self.long_payout + self.short_payout == self.total_collateral


def settle(realized_wad: int, strike_wad: int, cap_multiple_wad: int, notional: int) -> Settlement:
    """
    long  gets notional * min(RV, cap*K)
    short gets the rest of the pool

    The pool is notional * cap * K, which is exactly what the two deposits add up to.
    Payouts summing to deposits is an identity here, and the property the contract's
    invariant suite asserts.
    """
    ceiling = strike_wad * cap_multiple_wad // 10**18
    effective = min(realized_wad, ceiling)

    total = _mul_wad_up(ceiling, notional)
    long_payout = effective * notional // 10**18
    return Settlement(long_payout, total - long_payout, total)


def _mul_wad_up(a: int, b: int) -> int:
    p = a * b
    return 0 if p == 0 else (p - 1) // 10**18 + 1


# ---------------------------------------------------------------------------
# Fixture generation
# ---------------------------------------------------------------------------


def generate_cases() -> list[dict]:
    """
    Cases the differential test replays. Chosen to cover the domain rather than to look
    plausible: a flat series (RV must be exactly zero), a single jump, realistic drift,
    a series pinned at the tick extremes, and randomised series at several volatilities.
    """
    rng = random.Random(20260727)
    cases: list[dict] = []

    def add(name: str, ticks: list[int], window: int) -> None:
        rv = realized_variance_from_ticks(ticks, window)
        cases.append(
            {
                "name": name,
                "ticks": ticks,
                "windowSeconds": window,
                "sumSquaredDeltas": sum(
                    (ticks[i] - ticks[i - 1]) ** 2 for i in range(1, len(ticks))
                ),
                "expectedVarianceWad": to_wad(rv),
                "annualVolPct": float(annual_vol(rv) * 100),
            }
        )

    add("flat", [200_000] * 25, 86_400)
    add("single_jump", [200_000] * 12 + [201_000] * 12, 86_400)
    add("monotone_drift", [200_000 + i * 20 for i in range(25)], 86_400)
    add("tick_extremes", [-887_272, 887_272, -887_272], 86_400)
    add("two_points", [200_000, 200_100], 3_600)

    # Randomised series across a plausible volatility range. sigma_per_step in ticks:
    # 100 ticks is a 1% move, which at hourly sampling is a very volatile market.
    for sigma_ticks, tag in ((5, "calm"), (30, "normal"), (120, "stressed")):
        for k in range(3):
            ticks = [200_000]
            for _ in range(167):
                ticks.append(ticks[-1] + int(rng.gauss(0, sigma_ticks)))
            add(f"random_{tag}_{k}", ticks, 7 * 86_400)

    return cases


def main() -> None:
    cases = generate_cases()
    out = Path(__file__).resolve().parents[1] / "test" / "fixtures" / "variance_cases.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"count": len(cases), "cases": cases}, indent=2) + "\n")

    print(f"ln(1.0001)        = {LN_TICK}")
    print(f"ln^2 * 1e36       = {LN_TICK_SQUARED_E36}")
    print(f"wrote {len(cases)} cases -> {out}")
    print()
    print(f"{'case':<22} {'sum(dTick^2)':>14} {'RV (wad)':>24} {'ann. vol':>9}")
    for c in cases:
        print(
            f"{c['name']:<22} {c['sumSquaredDeltas']:>14} "
            f"{c['expectedVarianceWad']:>24} {c['annualVolPct']:>8.1f}%"
        )


if __name__ == "__main__":
    main()

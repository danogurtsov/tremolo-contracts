"""
Would anyone have made money on this?

Everything else in this repository establishes that the contract computes the right number and
cannot be drained. None of it says whether the instrument is worth trading. This replays the
protocol over real history: for every rolling window, compute what realized variance settled at,
price a strike the way a market maker plausibly would, and record what each side made.

The question it answers is narrow and worth stating precisely: **given the strike rule, how often
does each side win, and by how much?** A market maker who is systematically wrong loses money
until they stop quoting, and an instrument nobody quotes has no market.

Method
------
1. Pull `Swap` events over a long stretch and build a tick series.
2. For each rolling window, compute realized variance exactly as `UniV3Observer` +
   `VarianceMath` would: TWAP-per-step over a fixed grid.
3. Set the strike from a trailing estimate of the same quantity — the only estimator a maker has
   on chain — with a configurable premium.
4. Settle: long receives `notional * min(RV, cap * K)`, short receives the rest of the pot.

Run:
    python3 reference/backtest.py
    python3 reference/backtest.py --windows 200 --window-hours 6 --premium 1.2
"""

from __future__ import annotations

import argparse
import json
import statistics
from dataclasses import dataclass
from decimal import Decimal, getcontext
from pathlib import Path

from bias_measurement import Rpc, POOL_ACTIVE, SWAP_TOPIC, to_int24
from variance_reference import LN_TICK, SECONDS_PER_YEAR

getcontext().prec = 50

WAD = Decimal(10) ** 18


@dataclass
class Settlement:
    end_ts: int
    realized: Decimal
    strike: Decimal
    long_payout: Decimal
    short_payout: Decimal
    pot: Decimal

    @property
    def long_pnl(self) -> Decimal:
        """Long deposited notional * K and received notional * min(RV, cap*K)."""
        return self.long_payout - self.strike

    @property
    def short_pnl(self) -> Decimal:
        return self.short_payout - (self.pot - self.strike)


def fetch_ticks(rpc: Rpc, pool: str, from_block: int, to_block: int, end_ts: int) -> list[tuple[int, int]]:
    """(timestamp, tick) for every swap, oldest first. Base makes a block every 2 seconds."""
    out: list[tuple[int, int]] = []
    start = from_block
    while start <= to_block:
        end = min(start + 799, to_block)
        logs = rpc.call(
            "eth_getLogs",
            [{"address": pool, "topics": [SWAP_TOPIC], "fromBlock": hex(start), "toBlock": hex(end)}],
        )
        for log in logs:
            block = int(log["blockNumber"], 16)
            tick = to_int24("0x" + log["data"][2:][-64:])
            out.append((end_ts - 2 * (to_block - block), tick))
        start = end + 1
    out.sort()
    return out


def twap_series(swaps: list[tuple[int, int]], start_ts: int, window: int, samples: int) -> list[Decimal]:
    """
    Time-weighted average tick per grid step — the same quantity `observe()` returns.

    Rebuilt here from raw swaps rather than read from the pool, because the pool's buffer only
    reaches back about thirty hours and a backtest needs weeks.
    """
    step = window // samples
    series: list[Decimal] = []
    idx = 0
    current = swaps[0][1] if swaps else 0

    for i in range(samples):
        left = start_ts + i * step
        right = left + step

        while idx < len(swaps) and swaps[idx][0] <= left:
            current = swaps[idx][1]
            idx += 1

        total = Decimal(0)
        prev_ts = left
        tick = current
        j = idx
        while j < len(swaps) and swaps[j][0] < right:
            ts, next_tick = swaps[j]
            total += Decimal(tick) * Decimal(ts - prev_ts)
            prev_ts, tick = ts, next_tick
            j += 1
        total += Decimal(tick) * Decimal(right - prev_ts)
        series.append(total / Decimal(step))

    return series


def realized_variance(series: list[Decimal], window: int) -> Decimal:
    if len(series) < 2:
        return Decimal(0)
    total = sum((series[i] - series[i - 1]) ** 2 for i in range(1, len(series)))
    return total * LN_TICK * LN_TICK * SECONDS_PER_YEAR / Decimal(window)


def settle(realized: Decimal, strike: Decimal, cap: Decimal) -> Settlement:
    ceiling = strike * cap
    effective = min(realized, ceiling)
    return Settlement(0, realized, strike, effective, ceiling - effective, ceiling)


def run(rpc: Rpc, pool: str, end_block: int, window: int, samples: int, count: int,
        premium: Decimal, cap: Decimal, lookback: int) -> dict:
    end_ts = rpc.block_timestamp(end_block)

    # Enough history for `count` windows plus the trailing estimate that prices the first one.
    span = window * (count + lookback)
    from_block = end_block - span // 2 - 500
    print(f"fetching {span // 3600}h of swaps ({(end_block - from_block):,} blocks)...")
    swaps = fetch_ticks(rpc, pool, from_block, end_block, end_ts)
    print(f"{len(swaps):,} swaps\n")

    first_start = end_ts - span
    variances: list[Decimal] = []
    settlements: list[Settlement] = []

    for i in range(count + lookback):
        start = first_start + i * window
        rv = realized_variance(twap_series(swaps, start, window, samples), window)
        variances.append(rv)

        if i < lookback:
            continue

        # The strike a maker could actually set: the mean of the trailing windows, times a
        # premium. Nothing here uses information from the window being settled.
        trailing = variances[i - lookback : i]
        strike = (sum(trailing) / Decimal(len(trailing))) * premium
        if strike <= 0:
            continue

        s = settle(rv, strike, cap)
        s.end_ts = start + window
        settlements.append(s)

    return summarise(settlements, premium, cap, window, samples, lookback)


def summarise(settlements: list[Settlement], premium: Decimal, cap: Decimal,
              window: int, samples: int, lookback: int) -> dict:
    if not settlements:
        return {"settlements": 0}

    long_pnls = [float(s.long_pnl / s.strike) for s in settlements]  # as a multiple of the deposit
    long_wins = sum(1 for s in settlements if s.realized > s.strike)
    capped = sum(1 for s in settlements if s.realized >= s.strike * cap)
    zero = sum(1 for s in settlements if s.realized == 0)

    vols = [float((s.realized ** Decimal("0.5")) * 100) for s in settlements]

    print(f"window {window // 3600}h, {samples} grid points, strike = {premium}x trailing "
          f"mean of {lookback}, cap {cap}x")
    print(f"settlements                {len(settlements)}")
    print(f"realized vol, median       {statistics.median(vols):.1f}%")
    print(f"realized vol, min / max    {min(vols):.1f}% / {max(vols):.1f}%")
    print()
    print(f"long side wins             {long_wins} of {len(settlements)} "
          f"({100 * long_wins / len(settlements):.0f}%)")
    print(f"hit the cap                {capped} ({100 * capped / len(settlements):.0f}%)")
    print(f"realized exactly zero      {zero}")
    print()
    print(f"long P&L per unit deposited, mean    {statistics.mean(long_pnls):+.1%}")
    print(f"long P&L per unit deposited, median  {statistics.median(long_pnls):+.1%}")
    print(f"worst window for long                {min(long_pnls):+.1%}")
    print(f"best window for long                 {max(long_pnls):+.1%}")

    return {
        "settlements": len(settlements),
        "windowSeconds": window,
        "samples": samples,
        "premium": float(premium),
        "cap": float(cap),
        "longWinRate": long_wins / len(settlements),
        "cappedRate": capped / len(settlements),
        "medianVolPct": statistics.median(vols),
        "longMeanReturn": statistics.mean(long_pnls),
        "longMedianReturn": statistics.median(long_pnls),
        "longWorst": min(long_pnls),
        "longBest": max(long_pnls),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default="https://mainnet.base.org")
    ap.add_argument("--pool", default=POOL_ACTIVE)
    ap.add_argument("--end-block", type=int, default=49_000_000)
    ap.add_argument("--window-hours", type=int, default=6)
    ap.add_argument("--samples", type=int, default=24)
    ap.add_argument("--windows", type=int, default=60)
    ap.add_argument("--lookback", type=int, default=8)
    ap.add_argument("--premium", type=float, default=1.0)
    ap.add_argument("--cap", type=float, default=2.5)
    ap.add_argument("--out", default="docs/measurements/backtest_data.json")
    args = ap.parse_args()

    rpc = Rpc(args.rpc)
    results = []

    for premium in (Decimal("1.0"), Decimal("1.2"), Decimal("1.5")):
        print("=" * 72)
        results.append(
            run(
                rpc,
                args.pool,
                args.end_block,
                args.window_hours * 3600,
                args.samples,
                args.windows,
                premium,
                Decimal(str(args.cap)),
                args.lookback,
            )
        )
        print()

    Path(args.out).write_text(json.dumps({"results": results}, indent=2) + "\n")
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()

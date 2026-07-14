"""
How much does the grid understate realized variance?

The protocol settles on a series of TWAPs sampled on an even grid. That series is not the
market: each point is an average over its step, and averaging inside a step cancels whatever
moved within it. The question this script answers, with numbers rather than intuition, is how
much variance that cancellation destroys — and how the answer depends on the grid step and on
how busy the pool is.

Method
------
1. Pull every `Swap` event from a pool over a window. Each carries the tick the swap left the
   pool at, so the events give the price at every moment it changed.
2. Build the **reference series**: the spot tick at each grid boundary. Same instants the
   protocol samples, but the price *at* the instant rather than averaged around it. This
   isolates the one thing being measured — averaging — from everything else.
3. Build the **protocol series** by asking the pool's oracle for the same grid, exactly as
   `UniV3Observer.sampleTicks` does.
4. Report `RV(twap) / RV(spot)` per grid size.

A note on what NOT to use as the reference, learned the hard way. The obvious choice is the
sequence of every swap in order, and it is wrong: on this pool 3 220 of 3 776 swaps do not move
the tick at all, because a tick is 1 basis point and most swaps are smaller than that. Summing
squared differences over that series measures tick discretisation, not volatility, and it
understated variance by roughly half. Sampling spot at the grid boundaries avoids the problem
entirely, because over a 15-minute step the price has moved by many ticks.

Run:
    python3 reference/bias_measurement.py
    python3 reference/bias_measurement.py --pool 0x... --window 21600 --end-block 49000000
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.request
from dataclasses import dataclass
from decimal import Decimal, getcontext

from variance_reference import LN_TICK, SECONDS_PER_YEAR

getcontext().prec = 60

DEFAULT_RPC = "https://mainnet.base.org"

# Uniswap V3 on Base. The first is the venue this protocol targets; the second is the same pair
# at a fee tier almost nobody trades, kept as the thin-pool contrast.
POOL_ACTIVE = "0xd0b53D9277642d899DF5C87A3966A349A798F224"  # WETH/USDC 0.05%
POOL_THIN = "0x0b1C2DCbBfA744ebD3fC17fF1A96A1E1Eb4B2d69"  # WETH/USDC 1.00%

SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
OBSERVE_SELECTOR = "0x883bdbfd"  # observe(uint32[])
SLOT0_SELECTOR = "0x3850c7bd"


# Public endpoints reject requests without a User-Agent, and rate-limit generously but not
# infinitely. Both are handled here rather than left as a surprise for whoever reruns this.
FALLBACK_RPCS = ["https://mainnet.base.org", "https://base.drpc.org"]


class Rpc:
    def __init__(self, url: str):
        self.urls = [url] + [u for u in FALLBACK_RPCS if u != url]
        self._id = 0

    def call(self, method: str, params: list, attempts: int = 4):
        self._id += 1
        payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id})
        last = None
        for attempt in range(attempts):
            url = self.urls[attempt % len(self.urls)]
            req = urllib.request.Request(
                url,
                data=payload.encode(),
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "tremolo-bias-measurement/1.0",
                },
            )
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    body = json.load(resp)
                if "error" in body:
                    raise RuntimeError(f"{method}: {body['error']}")
                return body["result"]
            except Exception as exc:  # noqa: BLE001 - retry across endpoints deliberately
                last = exc
                time.sleep(0.4 * (attempt + 1))
        raise RuntimeError(f"{method} failed after {attempts} attempts: {last}")

    def block_timestamp(self, block: int) -> int:
        blk = self.call("eth_getBlockByNumber", [hex(block), False])
        return int(blk["timestamp"], 16)

    def eth_call(self, to: str, data: str, block: int) -> str:
        return self.call("eth_call", [{"to": to, "data": data}, hex(block)])


def to_int24(word: str) -> int:
    """Last 32-byte word of the Swap payload, interpreted as a signed tick."""
    v = int(word, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


@dataclass
class SwapPoint:
    block: int
    tick: int
    timestamp: int


def fetch_swap_ticks(
    rpc: Rpc, pool: str, from_block: int, to_block: int, end_ts: int, chunk: int = 800
) -> list[SwapPoint]:
    """Every tick the pool was left at, timestamped. Chunked: public endpoints cap log ranges."""
    points: list[SwapPoint] = []
    start = from_block
    while start <= to_block:
        end = min(start + chunk - 1, to_block)
        logs = rpc.call(
            "eth_getLogs",
            [{"address": pool, "topics": [SWAP_TOPIC], "fromBlock": hex(start), "toBlock": hex(end)}],
        )
        for log in logs:
            data = log["data"][2:]
            block = int(log["blockNumber"], 16)
            # amount0, amount1, sqrtPriceX96, liquidity, tick — tick is the last word.
            # Base produces a block every 2 seconds, which makes timestamps derivable without
            # one RPC round trip per block.
            points.append(
                SwapPoint(block, to_int24("0x" + data[-64:]), end_ts - 2 * (to_block - block))
            )
        start = end + 1
    points.sort(key=lambda p: p.timestamp)
    return points


def spot_at_boundaries(swaps: list[SwapPoint], start_ts: int, window: int, samples: int) -> list[int]:
    """The tick in force at each grid boundary: the reference the protocol is compared against."""
    step = window // samples
    series, idx, last = [], 0, swaps[0].tick if swaps else 0
    for i in range(samples + 1):
        boundary = start_ts + i * step
        while idx < len(swaps) and swaps[idx].timestamp <= boundary:
            last = swaps[idx].tick
            idx += 1
        series.append(last)
    return series


def observe_grid(rpc: Rpc, pool: str, block: int, window: int, samples: int) -> list[int]:
    """Reconstructs the same series `UniV3Observer.sampleTicks` would, via eth_call."""
    step = window // samples
    points = samples + 1
    seconds_agos = [window if i == 0 else (samples - i) * step for i in range(points)]

    head = OBSERVE_SELECTOR + f"{32:064x}" + f"{points:064x}"
    body = "".join(f"{ago:064x}" for ago in seconds_agos)
    raw = rpc.eth_call(pool, head + body, block)[2:]

    # Two dynamic arrays returned; the first is tickCumulatives.
    arr_offset = int(raw[0:64], 16) * 2
    length = int(raw[arr_offset : arr_offset + 64], 16)
    cumulatives = []
    for i in range(length):
        word = raw[arr_offset + 64 + i * 64 : arr_offset + 128 + i * 64]
        v = int(word, 16)
        cumulatives.append(v - (1 << 256) if v >= (1 << 255) else v)

    ticks = []
    for i in range(samples):
        dt = window - (samples - 1) * step if i == 0 else step
        ticks.append((cumulatives[i + 1] - cumulatives[i]) // dt)
    return ticks


def realized_variance(ticks: list[int], window_seconds: int) -> Decimal:
    """Same formula as VarianceMath.fromTicks."""
    if len(ticks) < 2:
        return Decimal(0)
    total = sum((ticks[i] - ticks[i - 1]) ** 2 for i in range(1, len(ticks)))
    return Decimal(total) * LN_TICK * LN_TICK * SECONDS_PER_YEAR / Decimal(window_seconds)


def annual_vol_pct(variance: Decimal) -> float:
    return float(variance.sqrt() * 100)


def measure(rpc: Rpc, pool: str, label: str, end_block: int, window: int, grids: list[int]) -> dict:
    end_ts = rpc.block_timestamp(end_block)
    start_ts = end_ts - window
    # Base produces a block every 2 seconds; the margin covers drift and pre-window context.
    from_block = end_block - (window // 2) - 200

    swaps = fetch_swap_ticks(rpc, pool, from_block, end_block, end_ts)
    in_window = [p for p in swaps if start_ts <= p.timestamp <= end_ts]
    unmoved = sum(1 for i in range(1, len(in_window)) if in_window[i].tick == in_window[i - 1].tick)

    print(f"\n=== {label} ===")
    print(f"pool             {pool}")
    print(f"window           {window}s ({window / 3600:.1f}h) ending at block {end_block}")
    gap = window / max(len(in_window), 1)
    print(f"swaps in window  {len(in_window)}  ({gap:.1f}s apart)")
    if in_window:
        print(f"swaps not moving the tick  {unmoved} of {len(in_window) - 1} "
              f"({100 * unmoved / max(len(in_window) - 1, 1):.0f}%)")
    print()
    print(f"{'grid':>6} {'step':>8} {'spot RV':>10} {'twap RV':>10} {'twap/spot':>10} {'spot vol':>9} {'twap vol':>9}")

    rows = []
    for n in grids:
        spot = spot_at_boundaries(swaps, start_ts, window, n)
        twap = observe_grid(rpc, pool, end_block, window, n)

        rv_spot = realized_variance(spot, window)
        rv_twap = realized_variance(twap, window)
        ratio = float(rv_twap / rv_spot) if rv_spot else float("nan")

        step = window / n
        step_s = f"{step:.0f}s" if step < 120 else f"{step / 60:.0f}m"
        print(
            f"{n:>6} {step_s:>8} {float(rv_spot):>10.5f} {float(rv_twap):>10.5f} "
            f"{ratio:>9.0%} {annual_vol_pct(rv_spot):>8.1f}% {annual_vol_pct(rv_twap):>8.1f}%"
        )
        rows.append({
            "grid": n,
            "stepSeconds": step,
            "spotVariance": float(rv_spot),
            "twapVariance": float(rv_twap),
            "twapOverSpot": ratio,
        })

    ratios = [r["twapOverSpot"] for r in rows if r["twapOverSpot"] == r["twapOverSpot"]]
    if ratios:
        print(f"\nmean twap/spot   {sum(ratios) / len(ratios):.0%}  "
              f"(range {min(ratios):.0%}-{max(ratios):.0%})")

    return {
        "label": label,
        "pool": pool,
        "endBlock": end_block,
        "endTimestamp": end_ts,
        "windowSeconds": window,
        "swapCount": len(in_window),
        "swapsNotMovingTick": unmoved,
        "grids": rows,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", default=DEFAULT_RPC)
    ap.add_argument("--end-block", type=int, default=49_000_000)
    ap.add_argument("--window", type=int, default=6 * 3600)
    ap.add_argument("--out", default="docs/measurements/bias_data.json")
    args = ap.parse_args()

    rpc = Rpc(args.rpc)
    grids = [6, 12, 24, 48, 96, 192, 256]

    results = [
        measure(rpc, POOL_ACTIVE, "active pool (WETH/USDC 0.05%)", args.end_block, args.window, grids),
        measure(rpc, POOL_THIN, "thin pool (WETH/USDC 1.00%)", args.end_block, args.window, grids),
    ]

    # Same pool, shorter window: does the effect depend on window length or only on step?
    results.append(
        measure(rpc, POOL_ACTIVE, "active pool, 1h window", args.end_block, 3600, [6, 12, 24, 48, 96])
    )

    with open(args.out, "w") as f:
        json.dump({"results": results}, f, indent=2)
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()

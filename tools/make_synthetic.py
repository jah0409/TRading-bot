#!/usr/bin/env python3
"""
make_synthetic.py - OHLC series with KNOWN regime segments.

Used to prove the calibration pipeline works end to end without needing broker
data. Because every bar carries the regime it was generated from, you can
cross-tabulate what the classifier said against the truth - something real
market data can never give you.

This is a test fixture, not a market model. Do not calibrate production
thresholds on it.

  python3 tools/make_synthetic.py --bars 20000 --out /tmp/synth.csv
"""
from __future__ import annotations

import argparse

import numpy as np
import pandas as pd

SEGMENTS = ["TREND_UP", "TREND_DOWN", "RANGE", "BREAKOUT", "CHOP_HIVOL"]


def make_segment(kind: str, n: int, price: float, base_vol: float, rng: np.random.Generator):
    """Return (sub-step log-returns, label per sub-step). 20 sub-steps per bar."""
    sub = 20
    steps = n * sub

    if kind == "TREND_UP":
        # persistent drift, modest noise -> high efficiency ratio
        drift = base_vol * 0.09
        r = rng.normal(drift, base_vol, steps)
    elif kind == "TREND_DOWN":
        drift = -base_vol * 0.09
        r = rng.normal(drift, base_vol, steps)
    elif kind == "RANGE":
        # Ornstein-Uhlenbeck pull back to the segment's starting level
        r = np.zeros(steps)
        dev = 0.0
        for i in range(steps):
            shock = rng.normal(0, base_vol * 0.6)
            pull = -0.06 * dev
            step = pull + shock
            dev += step
            r[i] = step
    elif kind == "CHOP_HIVOL":
        # big bars, no direction: the account killer
        r = rng.normal(0, base_vol * 2.6, steps)
        r -= r.mean()
    elif kind == "BREAKOUT":
        # first 60% compressed, then expansion with follow-through
        quiet = int(steps * 0.6)
        r = np.concatenate([
            rng.normal(0, base_vol * 0.25, quiet),
            rng.normal(base_vol * 0.18 * rng.choice([-1, 1]), base_vol * 1.9, steps - quiet),
        ])
    else:
        raise ValueError(kind)

    return r, sub


def build(bars: int, seed: int) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    price = 2000.0
    base_vol = 0.0006

    rows = []
    produced = 0
    while produced < bars:
        kind = SEGMENTS[rng.integers(0, len(SEGMENTS))]
        n = int(rng.integers(60, 220))
        n = min(n, bars - produced)
        if n < 30:
            break

        r, sub = make_segment(kind, n, price, base_vol, rng)
        path = price * np.exp(np.cumsum(r))

        for b in range(n):
            chunk = path[b * sub:(b + 1) * sub]
            if len(chunk) == 0:
                continue
            rows.append({
                "open": chunk[0],
                "high": chunk.max(),
                "low": chunk.min(),
                "close": chunk[-1],
                "planted": kind,
            })
        price = path[-1]
        produced += n

    df = pd.DataFrame(rows)
    df.insert(0, "time", pd.date_range("2020-01-01", periods=len(df), freq="h").strftime("%Y.%m.%d %H:%M"))
    return df


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bars", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    df = build(a.bars, a.seed)
    df.to_csv(a.out, index=False)
    print(f"wrote {len(df)} bars to {a.out}")
    print(df["planted"].value_counts(normalize=True).to_string())


if __name__ == "__main__":
    main()

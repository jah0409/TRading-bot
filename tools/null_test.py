#!/usr/bin/env python3
"""
null_test.py - the most important test in this directory.

Runs every strategy, with DEFAULT parameters and no optimisation, over several
pure geometric random walks. Random walk data contains no edge by construction,
so a correct simulator must report an expectancy indistinguishable from zero.

If a strategy shows a significantly POSITIVE edge here, the simulator is
lying: something is peeking at data the live EA would not have. That is
exactly how the collapsing-stop bug was found - mean_rev_bb was reporting
+0.98R per trade on random data, because its stop is anchored to a Bollinger
band while the fill happens at market, and when price closes far past the band
the two collide, risk collapses toward zero and R explodes.

A significantly NEGATIVE result is NOT a bug. It means the strategy has a
structural cost on random data - an adverse reward:risk ratio, or it simply
pays the spread often enough to bleed. That is a finding about the strategy,
not about the harness.

  python3 tools/null_test.py
  python3 tools/null_test.py --walks 10 --bars 60000
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backtest as BT      # noqa: E402
import regime_lib as R     # noqa: E402
import strategy_lib as S   # noqa: E402


def random_walk(seed: int, bars: int, sub: int = 20, vol: float = 0.0006) -> pd.DataFrame:
    g = np.random.default_rng(seed)
    path = 2000.0 * np.exp(np.cumsum(g.normal(0.0, vol, bars * sub))).reshape(bars, sub)
    return pd.DataFrame({"open": path[:, 0], "high": path.max(1),
                         "low": path.min(1), "close": path[:, -1]})


def run_one(cls, df: pd.DataFrame, cost_r: float) -> np.ndarray:
    feats = R.build_features(df, 14, 14, 100, 10)
    scores = R.compute_scores(feats, R.DEFAULT_PARAMS)
    regime, _ = R.classify(scores, R.DEFAULT_PARAMS)

    warm = 150
    df = df.iloc[warm:].reset_index(drop=True)
    feats = feats.iloc[warm:].reset_index(drop=True)
    regime = regime[warm:]

    kwargs = {}
    if cls is S.MomentumPullback:
        kwargs["aligned"] = pd.Series(regime).rolling(4, min_periods=1).apply(
            lambda w: float(len(set(w)) == 1), raw=True).to_numpy() > 0.5
    if cls is S.RangeFadeRsi:
        t = pd.Series(np.isin(regime, (R.TREND_UP, R.TREND_DOWN)).astype(float))
        kwargs["h4_trending"] = (t.rolling(16, min_periods=1).mean() > 0.5).to_numpy()

    sig = cls().build(df, feats, regime, **kwargs)
    return BT.run(df, sig, regime, cost_r=cost_r).r_series


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--walks", type=int, default=6)
    ap.add_argument("--bars", type=int, default=40000)
    ap.add_argument("--cost-r", type=float, default=0.0,
                    help="keep at 0 so costs cannot mask a positive bias")
    ap.add_argument("--seed0", type=int, default=200)
    args = ap.parse_args()

    print(f"\n=== Null test: {args.walks} random walks x {args.bars} bars, "
          f"default params, no optimisation ===")
    print("A significantly POSITIVE edge means look-ahead bias in the simulator.")
    print("A significantly NEGATIVE edge is a property of the strategy, not a bug.\n")
    print(f"  {'strategy':<16}{'trades':>8}{'exp R':>10}{'t':>8}   result")
    print("  " + "-" * 56)

    failures = 0
    for cls in S.ALL_STRATEGIES:
        pooled = []
        for k in range(args.walks):
            pooled.extend(run_one(cls, random_walk(args.seed0 + k, args.bars), args.cost_r))
        r = np.asarray(pooled, dtype=float)

        if len(r) < 30:
            print(f"  {cls.id:<16}{len(r):>8}{'':>10}{'':>8}   too few trades to test")
            continue

        sd = r.std(ddof=1)
        t = r.mean() / sd * np.sqrt(len(r)) if sd > 1e-12 else 0.0

        if t > 2.0:
            verdict, bad = "*** LOOK-AHEAD BIAS ***", True
        elif t < -2.0:
            verdict, bad = "negative edge (structural, not a bug)", False
        else:
            verdict, bad = "OK - no edge, as expected", False
        failures += bad
        print(f"  {cls.id:<16}{len(r):>8}{r.mean():>+10.4f}{t:>+8.2f}   {verdict}")

    print(f"\n  |t| < 2 means the measured edge is not distinguishable from zero.")
    if failures:
        print(f"\n  {failures} strategy(ies) show a positive edge on random data. "
              f"Fix the simulator before trusting any walk-forward result.")
        sys.exit(1)
    print("\n  No look-ahead bias detected.")


if __name__ == "__main__":
    main()

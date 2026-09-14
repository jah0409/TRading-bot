#!/usr/bin/env python3
"""
walkforward.py - out-of-sample validation for the strategy library.

No strategy joins the live mix without passing this. Per docs/WALKFORWARD.md:
anchored windows, optimise in-sample, score out-of-sample, accept only if the
edge survives the fold boundary.

  python3 tools/walkforward.py --ohlc bars.csv --symbol XAUUSD
  python3 tools/walkforward.py --ohlc bars.csv --strategy trend_ema --folds 5

What it optimises
  The t-statistic of mean R per trade. Not total profit (which rewards
  overtrading) and not expectancy alone (which lets a 4-trade fluke outrank a
  200-trade edge). t = mean/sd * sqrt(n) prices edge and sample together.

What it reports
  Per fold: in-sample and out-of-sample expectancy, trade count, verdict.
  Per strategy: an ACCEPT / REJECT verdict against the criteria in
  docs/WALKFORWARD.md, and a per-regime expectancy table that becomes the
  suitability prior in config.json.

Everything is measured in R. Position sizing is CRiskManager's job and changes
with the risk phase - a harness reporting dollars would be grading the sizing
rules, not the strategy.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backtest as BT          # noqa: E402
import regime_lib as R         # noqa: E402
import strategy_lib as S       # noqa: E402

REGIME_COLS = ["TREND_UP", "TREND_DOWN", "RANGE", "BREAKOUT", "CHOP_HIVOL"]


# ---------------------------------------------------------------------------
def prepare(df: pd.DataFrame, args) -> tuple[pd.DataFrame, pd.DataFrame, np.ndarray, np.ndarray]:
    """OHLC -> (bars, features, regime codes, h4-trending mask)."""
    feats = R.build_features(df, args.atr_period, args.adx_period,
                             args.pct_lookback, args.compression_lookback)
    params = dict(R.DEFAULT_PARAMS)
    if args.regime_config:
        blob = json.loads(Path(args.regime_config).read_text())
        per = blob.get("regime", {}).get("per_symbol", {})
        block = per.get(args.symbol) or next((v for k, v in per.items()
                                              if not k.startswith("_")), {})
        params.update({k: v for k, v in block.items() if k in params})
        print(f"regime thresholds loaded from {args.regime_config}")

    scores = R.compute_scores(feats, params)
    regime, _conf = R.classify(scores, params)

    # a crude higher-timeframe view: resample the regime over a 4x window so
    # RangeFadeRsi's "never fade into an H4 trend" filter has something to read
    win = args.htf_window
    trending = pd.Series(np.isin(regime, (R.TREND_UP, R.TREND_DOWN)).astype(float))
    h4_trending = (trending.rolling(win, min_periods=1).mean() > 0.5).to_numpy()

    return df, feats, regime, h4_trending


def build_signals(cls, params, df, feats, regime, h4_trending):
    strat = cls(params)
    kwargs = {}
    if cls is S.MomentumPullback:
        # Filter() demands multi-timeframe alignment; approximate it with a
        # run of the same regime rather than pretending we have three feeds
        same = pd.Series(regime).rolling(4, min_periods=1).apply(
            lambda w: float(len(set(w)) == 1), raw=True).to_numpy() > 0.5
        kwargs["aligned"] = same
    if cls is S.RangeFadeRsi:
        kwargs["h4_trending"] = h4_trending
    return strat.build(df, feats, regime, **kwargs)


def score(cls, params, df, feats, regime, h4, args) -> tuple[float, dict, BT.BacktestResult]:
    sig = build_signals(cls, params, df, feats, regime, h4)
    res = BT.run(df, sig, regime, cost_r=args.cost_r, spread=args.spread)
    st = res.stats()
    if st["trades"] < args.min_trades:
        return -99.0, st, res          # too few trades to mean anything
    return st["t_stat"], st, res


# ---------------------------------------------------------------------------
def optimise(cls, df, feats, regime, h4, args, verbose=False):
    """Coordinate descent over the strategy's own grid.

    Same search as the regime tool: a full grid over 6-7 parameters is
    hopeless, and sweeping one at a time converges fast and stays readable -
    you can see which parameter actually moved the result.
    """
    params = dict(cls.DEFAULTS)
    best, _, _ = score(cls, params, df, feats, regime, h4, args)

    for rnd in range(args.rounds):
        improved = False
        for key, grid in cls.GRID.items():
            base = params[key]
            best_v = base
            for cand in grid:
                trial = dict(params)
                trial[key] = cand
                s, _, _ = score(cls, trial, df, feats, regime, h4, args)
                if s > best + 1e-9:
                    best, best_v = s, cand
            if best_v != base:
                params[key] = best_v
                improved = True
                if verbose:
                    print(f"      {key}: {base} -> {best_v}  (t={best:+.3f})")
        if not improved:
            break
    return params, best


def repair_order(cls, p: dict) -> dict:
    """Median-across-folds can invert an ordered pair; put it back."""
    p = dict(p)
    if cls is S.TrendFollowEma and p["ema_fast"] >= p["ema_slow"]:
        p["ema_slow"] = p["ema_fast"] * 2
    if cls is S.MeanReversionBB and p["rsi_oversold"] >= p["rsi_overbought"]:
        p["rsi_oversold"], p["rsi_overbought"] = 30.0, 70.0
    if cls is S.RangeFadeRsi and p["rsi_low"] >= p["rsi_high"]:
        p["rsi_low"], p["rsi_high"] = 10.0, 90.0
    if cls is S.MomentumPullback and p["stoch_oversold"] >= p["stoch_overbought"]:
        p["stoch_oversold"], p["stoch_overbought"] = 25.0, 75.0
    return p


# ---------------------------------------------------------------------------
def walk_forward(cls, df, feats, regime, h4, args):
    n = len(df)
    blocks = args.folds + 1
    edges = [int(n * i / blocks) for i in range(blocks + 1)]

    rows, fold_params, oos_results = [], [], []

    for k in range(1, blocks):
        tr_hi, te_hi = edges[k], edges[k + 1]
        sl_tr, sl_te = slice(0, tr_hi), slice(tr_hi, te_hi)

        d_tr, f_tr = df.iloc[sl_tr].reset_index(drop=True), feats.iloc[sl_tr].reset_index(drop=True)
        d_te, f_te = df.iloc[sl_te].reset_index(drop=True), feats.iloc[sl_te].reset_index(drop=True)
        r_tr, r_te = regime[sl_tr], regime[sl_te]
        h_tr, h_te = h4[sl_tr], h4[sl_te]

        if len(d_tr) < 500 or len(d_te) < 200:
            continue

        p, _ = optimise(cls, d_tr, f_tr, r_tr, h_tr, args, verbose=args.verbose)
        _, is_st, _ = score(cls, p, d_tr, f_tr, r_tr, h_tr, args)
        _, oos_st, oos_res = score(cls, p, d_te, f_te, r_te, h_te, args)

        fold_params.append(p)
        oos_results.append(oos_res)
        rows.append({"fold": k, "is_trades": is_st["trades"], "is_exp": is_st["expectancy_r"],
                     "oos_trades": oos_st["trades"], "oos_exp": oos_st["expectancy_r"],
                     "oos_total": oos_st["total_r"], "oos_pf": oos_st["profit_factor"]})

    return rows, fold_params, oos_results


def verdict(rows, args) -> tuple[bool, str]:
    """The acceptance rule from docs/WALKFORWARD.md, applied literally."""
    if not rows:
        return False, "no usable folds"

    scored = [r for r in rows if r["oos_trades"] >= args.min_trades]
    if len(scored) < max(2, len(rows) // 2):
        return False, f"only {len(scored)}/{len(rows)} folds reached {args.min_trades} trades"

    positive = sum(1 for r in scored if r["oos_exp"] > 0)
    if positive <= len(scored) / 2:
        return False, f"out-of-sample expectancy positive in only {positive}/{len(scored)} folds"

    is_mean = float(np.mean([r["is_exp"] for r in scored]))
    oos_mean = float(np.mean([r["oos_exp"] for r in scored]))
    if is_mean <= 0:
        return False, "no in-sample edge to begin with"

    degr = (is_mean - oos_mean) / abs(is_mean)
    if degr > 0.5:
        return False, f"in->out degradation {degr:+.0%} exceeds 50%"

    return True, (f"positive in {positive}/{len(scored)} folds, "
                  f"degradation {degr:+.0%}, oos expectancy {oos_mean:+.3f}R")


def regime_expectancy(results) -> dict:
    """Pooled out-of-sample expectancy per regime -> the suitability prior."""
    by = {}
    for res in results:
        for t in res.trades:
            by.setdefault(R.REGIME_NAMES.get(t.regime, "UNKNOWN"), []).append(t.r)
    return {k: {"trades": len(v), "expectancy_r": float(np.mean(v))} for k, v in by.items()}


def suitability(reg_exp: dict) -> dict:
    """Expectancy per regime -> 0..1, self-scaled so nothing saturates."""
    vals = [reg_exp.get(rn, {}).get("expectancy_r") for rn in REGIME_COLS]
    finite = [v for v in vals if v is not None and np.isfinite(v)]
    scale = float(np.std(finite)) if len(finite) > 1 else 1.0
    if scale < 1e-6:
        scale = 1.0
    out = {}
    for rn, v in zip(REGIME_COLS, vals):
        n_tr = reg_exp.get(rn, {}).get("trades", 0)
        if v is None or not np.isfinite(v) or n_tr < 5:
            out[rn] = 0.0          # no evidence -> no claim
        else:
            out[rn] = round(float(1.0 / (1.0 + np.exp(-v / scale))), 2)
    out["UNKNOWN"] = 0.0
    return out


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ohlc", required=True, help="OHLC CSV (time,open,high,low,close)")
    ap.add_argument("--symbol", default="SYMBOL")
    ap.add_argument("--strategy", help="one strategy id; default = all")
    ap.add_argument("--folds", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--min-trades", type=int, default=20,
                    help="a fold with fewer trades than this is not evidence")
    ap.add_argument("--cost-r", type=float, default=0.05,
                    help="round-trip cost as a fraction of 1R")
    ap.add_argument("--spread", type=float, default=0.0, help="spread in price units")
    ap.add_argument("--regime-config", help="JSON from calibrate_regime.py")
    ap.add_argument("--atr-period", type=int, default=14)
    ap.add_argument("--adx-period", type=int, default=14)
    ap.add_argument("--pct-lookback", type=int, default=100)
    ap.add_argument("--compression-lookback", type=int, default=10)
    ap.add_argument("--htf-window", type=int, default=16)
    ap.add_argument("--emit-config", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    raw = pd.read_csv(args.ohlc)
    raw.columns = [c.strip().lower() for c in raw.columns]
    for c in ("open", "high", "low", "close"):
        if c not in raw.columns:
            sys.exit(f"OHLC file needs an '{c}' column; got {list(raw.columns)}")

    df, feats, regime, h4 = prepare(raw, args)

    warm = max(args.pct_lookback, 150)
    df = df.iloc[warm:].reset_index(drop=True)
    feats = feats.iloc[warm:].reset_index(drop=True)
    regime, h4 = regime[warm:], h4[warm:]

    print(f"\n=== Strategy walk-forward: {args.symbol} ===")
    print(f"bars={len(df)}  folds={args.folds}  cost={args.cost_r:.3f}R/trade  "
          f"min_trades={args.min_trades}")
    shares = pd.Series([R.REGIME_NAMES[r] for r in regime]).value_counts(normalize=True)
    print("regime mix: " + "  ".join(f"{k} {v:.0%}" for k, v in shares.items()))

    chosen = [S.BY_ID[args.strategy]] if args.strategy else S.ALL_STRATEGIES
    emitted = {}

    for cls in chosen:
        print(f"\n--- {cls.id}  ({cls.mql}) ---")
        rows, fold_params, oos_results = walk_forward(cls, df, feats, regime, h4, args)
        if not rows:
            print("  not enough data for the requested folds")
            continue

        print(f"  {'fold':>4} {'IS trades':>10} {'IS exp':>9} "
              f"{'OOS trades':>11} {'OOS exp':>9} {'OOS total':>10} {'PF':>6}")
        print("  " + "-" * 64)
        for r in rows:
            print(f"  {r['fold']:>4} {r['is_trades']:>10} {r['is_exp']:>+9.3f} "
                  f"{r['oos_trades']:>11} {r['oos_exp']:>+9.3f} "
                  f"{r['oos_total']:>+10.2f} {r['oos_pf']:>6.2f}")

        ok, why = verdict(rows, args)
        print(f"\n  VERDICT: {'ACCEPT' if ok else 'REJECT'} - {why}")

        # median parameters across folds, with a stability read
        med = repair_order(cls, {k: (float(np.median([fp[k] for fp in fold_params]))
                                     if isinstance(cls.DEFAULTS[k], float)
                                     else int(np.median([fp[k] for fp in fold_params])))
                                 for k in cls.GRID})
        print(f"\n  {'parameter':<22}{'median':>9}{'min':>8}{'max':>8}   stability")
        print("  " + "-" * 56)
        for k in cls.GRID:
            vals = [fp[k] for fp in fold_params]
            lo, hi = min(vals), max(vals)
            g = cls.GRID[k]
            span = (hi - lo) / (max(g) - min(g)) if max(g) > min(g) else 0.0
            tag = "stable" if span <= 0.2 else ("loose" if span <= 0.5 else "NOISE - keep default")
            print(f"  {k:<22}{med[k]:>9g}{lo:>8g}{hi:>8g}   {tag}")

        reg_exp = regime_expectancy(oos_results)
        if reg_exp:
            print(f"\n  out-of-sample expectancy by regime at entry")
            print(f"  {'regime':<14}{'trades':>8}{'exp R':>9}")
            print("  " + "-" * 31)
            for rn in REGIME_COLS + ["UNKNOWN"]:
                if rn in reg_exp:
                    print(f"  {rn:<14}{reg_exp[rn]['trades']:>8}"
                          f"{reg_exp[rn]['expectancy_r']:>+9.3f}")

        emitted[cls.id] = {
            "accepted": ok, "verdict": why,
            "params": med, "suitability": suitability(reg_exp),
        }

    if args.emit_config or args.out:
        block = {
            "_README": [
                "Generated by tools/walkforward.py. For each ACCEPTED strategy, copy",
                "params into strategies[].params and suitability into",
                "strategies[].suitability in config.json.",
                "REJECTED strategies should ship with \"enabled\": false - the harness",
                "found no edge that survived the fold boundary.",
                "Parameters marked NOISE in the stability table should be left at",
                "their defaults rather than pasted.",
            ],
            "strategies": emitted,
        }
        text = json.dumps(block, indent=2)
        print("\n=== paste into config.json ===\n")
        print(text)
        if args.out:
            Path(args.out).write_text(text + "\n")
            print(f"\nwritten to {args.out}")

    n_ok = sum(1 for v in emitted.values() if v["accepted"])
    print(f"\n{n_ok}/{len(emitted)} strategies accepted")


if __name__ == "__main__":
    main()

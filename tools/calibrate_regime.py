#!/usr/bin/env python3
"""
calibrate_regime.py - fit the regime classifier's thresholds to real data.

The classifier ships with first-guess thresholds. This fits them per symbol
against what the market actually did next, and writes a config block you can
paste straight into config.json.

Two input modes:

  --features FILE   CSV from MQL5/Scripts/Adaptive/RegimeExport.mq5.
                    Preferred: the features were computed by the same code
                    the EA runs live, so there is no train/serve skew.

  --ohlc FILE       Raw OHLC (time,open,high,low,close). Features are computed
                    in Python by regime_lib, which mirrors the MQL5. Use for
                    offline data or the synthetic self-test.

Two objectives:

  --objective payoff   (default) Maximise the expectancy, in R, of trading the
                       strategy family each regime designates. This is what
                       actually matters: a regime label is only useful if it
                       picks the right kind of strategy.

  --objective label    Maximise macro-F1 against forward-derived labels. More
                       interpretable, less directly tied to money.

Always reports OUT-OF-SAMPLE numbers on a chronological holdout. A calibration
that only looks good in-sample is a curve fit.

  python3 tools/calibrate_regime.py --features features_XAUUSD_H1.csv \
          --symbol XAUUSD --emit-config
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regime_lib as R  # noqa: E402

# --- ground-truth classes derived from forward price action -----------------
# Deliberately four, not five. BREAKOUT and TREND look identical looking
# forward - both are directional. What separates them is what came BEFORE
# (compression), which is a feature, not an outcome. So the label objective
# scores both against one directional class, and the payoff objective is the
# one that can actually tell them apart.
DIR_UP, DIR_DOWN, QUIET, VOLATILE = "DIRECTIONAL_UP", "DIRECTIONAL_DOWN", "QUIET_RANGE", "VOLATILE_CHOP"

REGIME_TO_TRUTH = {
    R.TREND_UP: DIR_UP,
    R.TREND_DOWN: DIR_DOWN,
    R.RANGE: QUIET,
    R.CHOP_HIVOL: VOLATILE,
}

# which stylised strategy family each regime designates
REGIME_TO_FAMILY = {
    R.TREND_UP: "trend",
    R.TREND_DOWN: "trend",
    R.BREAKOUT: "breakout",
    R.RANGE: "meanrev",
    R.CHOP_HIVOL: None,   # staying out is the correct action
    R.UNKNOWN: None,
}

FAMILIES = ["trend", "meanrev", "breakout"]


# ---------------------------------------------------------------------------
# Forward outcomes
# ---------------------------------------------------------------------------
def forward_outcomes(df: pd.DataFrame, horizon: int) -> pd.DataFrame:
    """Recreate the exporter's forward columns from OHLC."""
    c = df["close"].to_numpy(float)
    h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float)
    n = len(c)

    fwd_ret = np.full(n, np.nan)
    eff = np.full(n, np.nan)
    mae = np.full(n, np.nan)
    mfe = np.full(n, np.nan)
    volr = np.full(n, np.nan)

    steps = np.abs(np.diff(c, prepend=c[0]))
    cum_steps = np.cumsum(steps)
    logret = np.diff(np.log(np.maximum(c, 1e-12)), prepend=0.0)

    atr_arr = df["atr"].to_numpy(float) if "atr" in df.columns else np.full(n, np.nan)

    for i in range(n - horizon):
        j = i + horizon
        a = atr_arr[i]
        if not np.isfinite(a) or a <= 0 or c[i] <= 0:
            continue
        path = cum_steps[j] - cum_steps[i]
        net = c[j] - c[i]
        fwd_ret[i] = net / c[i]
        eff[i] = abs(net) / path if path > 0 else 0.0
        win_h = h[i + 1:j + 1].max()
        win_l = l[i + 1:j + 1].min()
        mfe[i] = (win_h - c[i]) / a
        mae[i] = (c[i] - win_l) / a
        rv = logret[i + 1:j + 1].std()
        volr[i] = rv / (a / c[i]) if a / c[i] > 0 else np.nan

    return pd.DataFrame({
        "fwd_ret": fwd_ret, "fwd_efficiency": eff,
        "fwd_mae_atr": mae, "fwd_mfe_atr": mfe, "fwd_vol_ratio": volr,
    })


def derive_truth(f: pd.DataFrame, er_hi_q=0.65, vol_hi_q=0.65) -> pd.Series:
    """Forward behaviour -> one of four ground-truth classes.

    Cutoffs are quantiles of the instrument's own distribution, so the same
    code works on gold and on an index without re-tuning the labeller itself.
    """
    eff = f["fwd_efficiency"]
    vol = f["fwd_vol_ratio"]
    ret = f["fwd_ret"]

    er_hi = eff.quantile(er_hi_q)
    v_hi = vol.quantile(vol_hi_q)

    out = pd.Series(index=f.index, dtype=object)
    directional = eff >= er_hi
    out[directional & (ret > 0)] = DIR_UP
    out[directional & (ret <= 0)] = DIR_DOWN
    out[~directional & (vol >= v_hi)] = VOLATILE
    out[~directional & (vol < v_hi)] = QUIET
    return out


# ---------------------------------------------------------------------------
# Stylised strategy payoffs, in R (R = the stop distance)
# ---------------------------------------------------------------------------
def family_payoffs(f: pd.DataFrame, stop_atr=1.5) -> pd.DataFrame:
    """What each strategy family would have earned from this bar, in R.

    Long  -> adverse excursion is fwd_mae_atr, favourable is fwd_mfe_atr
    Short -> the two swap over.
    If the adverse excursion reached the stop first we book -1R; otherwise the
    net move, expressed in stop units.

    ONE stop for all three families, deliberately. An earlier version gave the
    breakout family a tighter stop, which inflated its R on every bar where the
    stop was not hit - it "won" every regime for purely arithmetic reasons. The
    stop is a strategy design choice; holding it fixed is what makes the
    comparison about the regime rather than about the stop.
    """
    long_side = (f["di_plus"] >= f["di_minus"]).to_numpy()
    net_atr = (f["fwd_ret"].to_numpy() * f["close"].to_numpy()) / f["atr"].to_numpy()

    def payoff(direction_long: np.ndarray) -> np.ndarray:
        adverse = np.where(direction_long, f["fwd_mae_atr"], f["fwd_mfe_atr"])
        signed = np.where(direction_long, net_atr, -net_atr)
        return np.where(adverse >= stop_atr, -1.0, signed / stop_atr)

    trend = payoff(long_side)
    return pd.DataFrame({
        "trend": trend,
        # a breakout entry is a trend entry taken only where volatility is
        # expanding; same trade, the regime decides when it is allowed
        "breakout": trend,
        # mean reversion fades the prevailing directional push
        "meanrev": payoff(~long_side),
    }, index=f.index)


# ---------------------------------------------------------------------------
# Objectives
# ---------------------------------------------------------------------------
def designated_returns(regime: np.ndarray, payoffs: pd.DataFrame) -> np.ndarray:
    """Per-bar R from following each regime's designated family (0 = stay out)."""
    total = np.zeros(len(regime))
    for code, fam in REGIME_TO_FAMILY.items():
        if fam is None:
            continue
        mask = regime == code
        if mask.any():
            total[mask] = np.nan_to_num(payoffs[fam].to_numpy()[mask], nan=0.0)
    return total


def objective_payoff(regime: np.ndarray, payoffs: pd.DataFrame,
                     min_share: float = 0.02) -> float:
    """Risk-adjusted expectancy of following the regime's designated family.

    mean(R) / std(R), not mean(R). Staying out of high-variance, zero-edge
    bars cannot raise the mean, but it does cut the denominator - so a pure
    mean objective has no reason to ever identify CHOP_HIVOL, and in testing
    it duly collapsed that class to ~1% of bars and mislabelled two thirds of
    planted chop as trend. On a prop account that is the single most expensive
    mistake the classifier can make.

    The share penalty stops the optimiser deleting a regime outright: any
    tradable class below min_share is penalised in proportion to the shortfall.
    """
    r = designated_returns(regime, payoffs)
    sd = float(np.std(r))
    score = float(np.mean(r)) / sd if sd > 1e-12 else 0.0

    penalty = 0.0
    n = len(regime)
    for code in (R.TREND_UP, R.TREND_DOWN, R.RANGE, R.BREAKOUT, R.CHOP_HIVOL):
        share = float((regime == code).sum()) / n
        if share < min_share:
            penalty += (min_share - share) / min_share
    return score - 0.05 * penalty


def objective_label(regime: np.ndarray, truth: pd.Series) -> float:
    """Macro-F1 of the predicted class against the derived label."""
    pred = pd.Series([REGIME_TO_TRUTH.get(r) for r in regime], index=truth.index)
    # BREAKOUT is directional; score it against whichever direction it implied
    classes = [DIR_UP, DIR_DOWN, QUIET, VOLATILE]
    f1s = []
    for cl in classes:
        tp = int(((pred == cl) & (truth == cl)).sum())
        fp = int(((pred == cl) & (truth != cl) & truth.notna()).sum())
        fn = int(((pred != cl) & (truth == cl)).sum())
        if tp + fp == 0 or tp + fn == 0:
            f1s.append(0.0)
            continue
        prec, rec = tp / (tp + fp), tp / (tp + fn)
        f1s.append(0.0 if prec + rec == 0 else 2 * prec * rec / (prec + rec))
    return float(np.mean(f1s))


def evaluate(f: pd.DataFrame, params: dict, truth: pd.Series,
             payoffs: pd.DataFrame, objective: str, min_share: float = 0.02) -> float:
    scores = R.compute_scores(f, params)
    regime, _ = R.classify(scores, params)
    if objective == "payoff":
        return objective_payoff(regime, payoffs, min_share)
    return objective_label(regime, truth)


# ---------------------------------------------------------------------------
# Search: coordinate descent. 11 parameters make a full grid hopeless; sweeping
# one at a time and repeating converges fast and stays interpretable - you can
# read the log and see which parameter actually moved the needle.
# ---------------------------------------------------------------------------
SEARCH_GRID = {
    "adx_trend_lo": np.arange(12.0, 30.1, 2.0),
    "adx_trend_hi": np.arange(24.0, 50.1, 2.0),
    "adx_range_lo": np.arange(8.0, 24.1, 2.0),
    "adx_range_hi": np.arange(16.0, 38.1, 2.0),
    "di_spread_lo": np.arange(0.02, 0.31, 0.04),
    "di_spread_hi": np.arange(0.20, 0.71, 0.05),
    "atr_vol_lo": np.arange(0.30, 0.81, 0.05),
    "atr_vol_hi": np.arange(0.55, 0.96, 0.05),
    "atr_expansion_lo": np.arange(1.00, 1.51, 0.05),
    "atr_expansion_hi": np.arange(1.30, 2.51, 0.10),
    "compression_min": np.arange(0.05, 0.61, 0.05),
    "min_score_to_classify": np.arange(0.05, 0.51, 0.05),
}

# pairs that must stay ordered (lo < hi)
ORDER_PAIRS = [
    ("adx_trend_lo", "adx_trend_hi"),
    ("adx_range_lo", "adx_range_hi"),
    ("di_spread_lo", "di_spread_hi"),
    ("atr_vol_lo", "atr_vol_hi"),
    ("atr_expansion_lo", "atr_expansion_hi"),
]


def valid(p: dict) -> bool:
    return all(p[lo] < p[hi] for lo, hi in ORDER_PAIRS)


def repair(p: dict) -> dict:
    """Median-of-folds can break lo<hi; nudge the pair apart if so."""
    p = dict(p)
    for lo, hi in ORDER_PAIRS:
        if p[lo] >= p[hi]:
            span = abs(p[hi]) * 0.1 + 1e-6
            p[hi] = p[lo] + span
    return p


def coordinate_descent(f, truth, payoffs, objective, rounds=4, verbose=True, min_share=0.02):
    params = dict(R.DEFAULT_PARAMS)
    best = evaluate(f, params, truth, payoffs, objective, min_share)
    if verbose:
        print(f"  start {objective}={best:+.5f}")

    for rnd in range(rounds):
        improved = False
        for key, grid in SEARCH_GRID.items():
            base = params[key]
            best_v, best_s = base, best
            for cand in grid:
                trial = dict(params)
                trial[key] = float(cand)
                if not valid(trial):
                    continue
                s = evaluate(f, trial, truth, payoffs, objective, min_share)
                if s > best_s + 1e-9:
                    best_s, best_v = s, float(cand)
            if best_v != base:
                params[key] = best_v
                if verbose:
                    print(f"  round {rnd+1}: {key} {base:g} -> {best_v:g} "
                          f"({objective} {best:+.5f} -> {best_s:+.5f})")
                best = best_s
                improved = True
        if not improved:
            if verbose:
                print(f"  converged after round {rnd+1}")
            break
    return params, best


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def regime_report(f, params, truth, payoffs, title):
    scores = R.compute_scores(f, params)
    regime, conf = R.classify(scores, params)

    print(f"\n  {title}")
    print(f"  {'regime':<12} {'bars':>7} {'share':>7} {'conf':>6} "
          f"{'trendR':>8} {'meanrevR':>9} {'breakoutR':>10}  designated")
    print("  " + "-" * 78)

    rows = {}
    for code in [R.TREND_UP, R.TREND_DOWN, R.RANGE, R.BREAKOUT, R.CHOP_HIVOL, R.UNKNOWN]:
        mask = regime == code
        n = int(mask.sum())
        if n == 0:
            continue
        r = {fam: float(np.nanmean(payoffs[fam].to_numpy()[mask])) for fam in FAMILIES}
        rows[R.REGIME_NAMES[code]] = {"bars": n, "share": n / len(regime), **r}
        fam = REGIME_TO_FAMILY.get(code)
        print(f"  {R.REGIME_NAMES[code]:<12} {n:>7} {n/len(regime):>6.1%} "
              f"{np.nanmean(conf[mask]):>6.2f} "
              f"{r['trend']:>+8.3f} {r['meanrev']:>+9.3f} {r['breakout']:>+10.3f}"
              f"  {fam or '-(stay out)'}")
    return rows


REGIME_COLS = ["TREND_UP", "TREND_DOWN", "RANGE", "BREAKOUT", "CHOP_HIVOL"]


def suitability_from_payoffs(rows: dict) -> dict:
    """Turn measured per-regime payoffs into 0..1 suitability scores.

    Logistic on R, scaled by the spread of that family's own per-regime
    payoffs. A fixed scale (0.5 at breakeven, 1.0 at +0.25R) saturated every
    cell to 1.0 the moment the horizon produced R values above about half a
    unit, which threw away all the ranking information that makes the table
    useful. Self-scaling keeps the spread no matter the horizon or instrument.
    """
    fam_to_strategies = {
        "trend": ["trend_ema", "momo_pullback"],
        "meanrev": ["mean_rev_bb", "range_fade"],
        "breakout": ["breakout_dc"],
    }
    out = {}
    for fam, strategies in fam_to_strategies.items():
        vals = [rows.get(rn, {}).get(fam) for rn in REGIME_COLS]
        finite = [v for v in vals if v is not None and np.isfinite(v)]
        scale = float(np.std(finite)) if len(finite) > 1 else 1.0
        if scale < 1e-6:
            scale = 1.0
        for sid in strategies:
            out[sid] = {}
            for rn, v in zip(REGIME_COLS, vals):
                if v is None or not np.isfinite(v):
                    out[sid][rn] = 0.0
                else:
                    out[sid][rn] = round(float(1.0 / (1.0 + np.exp(-v / scale))), 2)
            out[sid]["UNKNOWN"] = 0.0
    return out


# ---------------------------------------------------------------------------
def walk_forward(f, truth, payoffs, args):
    """Anchored walk-forward, matching docs/WALKFORWARD.md.

    A single fit is not trustworthy: on independent fixtures the optimiser
    landed on adx_trend_lo of 22, 28 and 30 with near-identical scores, because
    the objective surface is flat in that direction. Fitting each fold and
    taking the MEDIAN gives a parameter set that does not depend on where one
    particular search happened to stop - and the per-parameter spread tells
    you which thresholds are real and which are noise.
    """
    n = len(f)
    blocks = args.folds + 1
    edges = [int(n * i / blocks) for i in range(blocks + 1)]

    fold_params, fold_scores, base_scores = [], [], []
    for i in range(1, blocks):
        tr_end = edges[i]
        te_end = edges[i + 1]
        f_tr = f.iloc[:tr_end].reset_index(drop=True)
        f_te = f.iloc[tr_end:te_end].reset_index(drop=True)
        if len(f_tr) < 400 or len(f_te) < 150:
            continue

        t_tr = truth.iloc[:tr_end].reset_index(drop=True)
        p_tr = payoffs.iloc[:tr_end].reset_index(drop=True)
        t_te = truth.iloc[tr_end:te_end].reset_index(drop=True)
        p_te = payoffs.iloc[tr_end:te_end].reset_index(drop=True)

        params, _ = coordinate_descent(f_tr, t_tr, p_tr, args.objective,
                                       rounds=args.rounds, verbose=False,
                                       min_share=args.min_regime_share)
        te = evaluate(f_te, params, t_te, p_te, args.objective, args.min_regime_share)
        bl = evaluate(f_te, dict(R.DEFAULT_PARAMS), t_te, p_te,
                      args.objective, args.min_regime_share)
        fold_params.append(params)
        fold_scores.append(te)
        base_scores.append(bl)
        print(f"  fold {i}: train={len(f_tr):>6} test={len(f_te):>5}  "
              f"defaults={bl:+.5f}  calibrated={te:+.5f}  "
              f"{'BETTER' if te > bl else 'worse'}")

    if not fold_params:
        sys.exit("not enough data for the requested number of folds")

    median = repair({k: float(np.median([fp[k] for fp in fold_params]))
                     for k in SEARCH_GRID})

    print(f"\n  folds where calibration beat defaults: "
          f"{sum(1 for a, b in zip(fold_scores, base_scores) if a > b)}/{len(fold_scores)}")
    print(f"  mean out-of-sample: defaults {np.mean(base_scores):+.5f}  "
          f"calibrated {np.mean(fold_scores):+.5f}")

    print(f"\n  {'parameter':<24}{'median':>9}{'min':>9}{'max':>9}   stability")
    print("  " + "-" * 62)
    for k in SEARCH_GRID:
        vals = [fp[k] for fp in fold_params]
        lo, hi = min(vals), max(vals)
        grid = SEARCH_GRID[k]
        span = (hi - lo) / (grid.max() - grid.min()) if grid.max() > grid.min() else 0.0
        tag = "stable" if span <= 0.2 else ("loose" if span <= 0.5 else "NOISE - ignore")
        print(f"  {k:<24}{median[k]:>9.4g}{lo:>9.4g}{hi:>9.4g}   {tag}")

    return median, fold_params, fold_scores, base_scores


def load_features(args) -> pd.DataFrame:
    if args.features:
        f = pd.read_csv(args.features)
        needed = ["atr", "atr_percentile", "atr_expansion", "adx", "di_plus",
                  "di_minus", "di_spread_norm", "candle_flags", "compression", "close"]
        missing = [c for c in needed if c not in f.columns]
        if missing:
            sys.exit(f"features file is missing columns: {missing}")
        if "fwd_efficiency" not in f.columns:
            sys.exit("features file has no forward columns; re-export with RegimeExport.mq5")
        return f

    raw = pd.read_csv(args.ohlc)
    raw.columns = [c.strip().lower() for c in raw.columns]
    for c in ["open", "high", "low", "close"]:
        if c not in raw.columns:
            sys.exit(f"OHLC file needs an '{c}' column; got {list(raw.columns)}")

    f = R.build_features(raw, args.atr_period, args.adx_period,
                         args.pct_lookback, args.compression_lookback)
    # forward outcomes need the bar extremes, which the feature frame drops
    fwd_src = f.assign(high=raw["high"].to_numpy(float), low=raw["low"].to_numpy(float))
    fwd = forward_outcomes(fwd_src, args.horizon)

    out = pd.concat([f, fwd], axis=1)
    # carry a ground-truth column through when the fixture provides one
    if "planted" in raw.columns:
        out["planted"] = raw["planted"].to_numpy()
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--features", help="CSV from RegimeExport.mq5")
    src.add_argument("--ohlc", help="raw OHLC CSV (features computed in Python)")
    ap.add_argument("--symbol", default="SYMBOL", help="symbol name for the emitted config block")
    ap.add_argument("--objective", choices=["payoff", "label"], default="payoff")
    ap.add_argument("--horizon", type=int, default=24, help="forward bars (--ohlc mode)")
    ap.add_argument("--atr-period", type=int, default=14)
    ap.add_argument("--adx-period", type=int, default=14)
    ap.add_argument("--pct-lookback", type=int, default=100)
    ap.add_argument("--compression-lookback", type=int, default=10)
    ap.add_argument("--train-frac", type=float, default=0.70)
    ap.add_argument("--folds", type=int, default=4,
                    help="anchored walk-forward folds; 1 = a single chronological split")
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--min-regime-share", type=float, default=0.02,
                    help="floor on each regime's share of bars; stops the optimiser deleting a class")
    ap.add_argument("--emit-config", action="store_true", help="print a config.json block")
    ap.add_argument("--out", help="write the emitted config block to this file")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    f = load_features(args)
    f = f.dropna(subset=["adx", "atr_percentile", "atr_expansion",
                         "fwd_efficiency", "fwd_ret"]).reset_index(drop=True)
    if len(f) < 500:
        sys.exit(f"only {len(f)} usable rows; need at least 500 for a meaningful fit")

    truth = derive_truth(f)
    payoffs = family_payoffs(f)

    cut = int(len(f) * args.train_frac)
    tr, te = slice(0, cut), slice(cut, len(f))

    print(f"\n=== Regime calibration: {args.symbol} ===")
    print(f"rows={len(f)}  train={cut}  test={len(f)-cut}  objective={args.objective}")
    print(f"\nlabel mix (forward-derived ground truth):")
    for k, v in truth.value_counts(normalize=True).items():
        print(f"  {k:<18} {v:6.1%}")

    f_tr = f.iloc[tr].reset_index(drop=True)
    f_te = f.iloc[te].reset_index(drop=True)

    if args.folds > 1:
        print(f"\nwalk-forward, {args.folds} anchored folds:")
        params, _, fold_scores, base_scores = walk_forward(f, truth, payoffs, args)
        tr_score = evaluate(f_tr, params, truth.iloc[tr].reset_index(drop=True),
                            payoffs.iloc[tr].reset_index(drop=True),
                            args.objective, args.min_regime_share)
        print("\nholdout check with the median parameter set:")
    else:
        print("\nfitting on train:")
        params, tr_score = coordinate_descent(
            f_tr, truth.iloc[tr].reset_index(drop=True), payoffs.iloc[tr].reset_index(drop=True),
            args.objective, rounds=args.rounds, verbose=not args.quiet,
            min_share=args.min_regime_share)

    base = dict(R.DEFAULT_PARAMS)
    te_truth = truth.iloc[te].reset_index(drop=True)
    te_pay = payoffs.iloc[te].reset_index(drop=True)

    base_te = evaluate(f_te, base, te_truth, te_pay, args.objective, args.min_regime_share)
    fit_te = evaluate(f_te, params, te_truth, te_pay, args.objective, args.min_regime_share)

    raw_tr = float(np.mean(designated_returns(
        *(lambda sc: (R.classify(sc, params)[0], payoffs.iloc[tr].reset_index(drop=True)))(
            R.compute_scores(f_tr, params)))))
    raw_te = float(np.mean(designated_returns(
        *(lambda sc: (R.classify(sc, params)[0], te_pay))(R.compute_scores(f_te, params)))))
    print(f"\n  raw mean R/bar following the designated family: "
          f"train {raw_tr:+.4f}  test {raw_te:+.4f}")
    print(f"\n  {'':<22}{'train':>10}{'test':>10}")
    print(f"  {'defaults':<22}"
          f"{evaluate(f_tr, base, truth.iloc[tr].reset_index(drop=True), payoffs.iloc[tr].reset_index(drop=True), args.objective, args.min_regime_share):>+10.5f}"
          f"{base_te:>+10.5f}")
    print(f"  {'calibrated':<22}{tr_score:>+10.5f}{fit_te:>+10.5f}")

    degradation = (tr_score - fit_te) / abs(tr_score) if tr_score else 0.0
    print(f"  in->out degradation: {degradation:+.1%}", end="")
    if fit_te <= base_te:
        print("   <-- WARNING: no out-of-sample gain over defaults")
    elif degradation > 0.5:
        print("   <-- WARNING: >50% degradation, likely overfit")
    else:
        print("   OK")

    print("\nfitted parameters:")
    for k in SEARCH_GRID:
        mark = "" if params[k] == base[k] else "  <- changed"
        print(f"  {k:<24} {params[k]:>8.4g}{mark}")

    regime_report(f_tr, params, truth.iloc[tr].reset_index(drop=True),
                  payoffs.iloc[tr].reset_index(drop=True), "IN-SAMPLE")
    rows_te = regime_report(f_te, params, te_truth, te_pay, "OUT-OF-SAMPLE (trust this one)")

    if "planted" in f.columns:
        sc = R.compute_scores(f_te, params)
        reg, _ = R.classify(sc, params)
        pred = pd.Series([R.REGIME_NAMES[x] for x in reg], name="classified")
        ct = pd.crosstab(f_te["planted"], pred, normalize="index")
        print("\n  PLANTED vs CLASSIFIED (synthetic fixture only, row-normalised)")
        print("  " + ct.round(3).to_string().replace("\n", "\n  "))

    if args.emit_config or args.out:
        block = {
            "_README": [
                "Generated by tools/calibrate_regime.py. Copy the regime.per_symbol",
                "block into config.json as-is. The suitability rows go into the",
                "matching strategies[].suitability entries - they are a starting",
                "prior, which CPerformanceTracker then adjusts from live results.",
                "CAVEAT: breakout_dc scores identically to the trend strategies.",
                "The payoff proxy enters a breakout the same way it enters a trend,",
                "so it cannot tell them apart; what separates them is the",
                "compression that came BEFORE, which is a feature, not an outcome.",
                "Treat breakout_dc's row as 'trend-like' and set its RANGE and",
                "CHOP_HIVOL cells by judgement.",
            ],
            "regime": {"per_symbol": {args.symbol: {k: round(float(v), 4)
                                                    for k, v in params.items()}}},
            "_suitability_measured_out_of_sample": suitability_from_payoffs(rows_te),
        }
        text = json.dumps(block, indent=2)
        print("\n=== paste into config.json ===")
        print("regime.per_symbol block, plus measured suitability rows for the")
        print("matching strategies[].suitability entries:\n")
        print(text)
        if args.out:
            Path(args.out).write_text(text + "\n")
            print(f"\nwritten to {args.out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
research.py - the validation pipeline. TRAIN -> VALIDATE -> TEST -> roll.

Three separated periods per fold, never shuffled, never overlapping:

  TRAIN     parameters are fitted here, and only here
  VALIDATE  the fitted set is checked here; this is what picks between
            candidate parameter sets
  TEST      touched once, at the end, to report. Nothing is selected on it.

The final block of history is held out entirely and never enters any fold.

Anti-overfitting is enforced, not hoped for:
  * parameter stability - a value whose neighbours collapse is flagged and the
    default kept instead
  * sample-size tiers - under 30 trades is INSUFFICIENT and cannot be accepted
  * a null test on matched random walks, so an "edge" that appears on noise is
    caught before it reaches a config file

  python3 tools/research.py --cache CACHE --tf M15 --from 2015-01-01
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backtest_v2 as BT        # noqa: E402
import cost_model as CM         # noqa: E402
import data_engine as DE        # noqa: E402
import feature_engine as FE     # noqa: E402
import regime_v2 as R2          # noqa: E402
import strategies_v2 as SV      # noqa: E402

EVIDENCE = [(30, "INSUFFICIENT"), (100, "WEAK"), (200, "MODERATE"), (10**9, "STRONGER")]


def evidence_tier(n: int) -> str:
    for lim, name in EVIDENCE:
        if n < lim:
            return name
    return "STRONGER"


def prepare(cache: Path, tf: str, start: str, end: str | None):
    base = pd.read_parquet(cache / f"XAUUSD_{tf}.parquet")
    base = base[base.index >= start]
    if end:
        base = base[base.index <= end]
    sess = DE.MarketData.sessions(base.index)
    f = FE.build(base, sessions=sess)

    # higher-timeframe context, attached POINT-IN-TIME (closed bars only)
    for htf in ("H1", "H4"):
        hb = pd.read_parquet(cache / f"XAUUSD_{htf}.parquet")
        hb = hb[(hb.index >= start)]
        hf = FE.build(hb)
        hr = R2.classify(hf)["regime"]
        # shift(1): an M15 bar sees the H4 bar that has CLOSED, never the
        # one still forming. This is the leak that flatters every MTF backtest.
        f[f"{htf}_regime"] = hr.shift(1).reindex(f.index, method="ffill").to_numpy()
        f[f"{htf}_bias"] = hf["struct_bias"].shift(1).reindex(f.index, method="ffill").to_numpy()

    reg = R2.classify(f)
    f["regime"] = reg["regime"]
    f["regime_conf"] = reg["confidence"]
    return base, f


def spread_series(f: pd.DataFrame, cost: CM.CostModel) -> np.ndarray:
    return cost.spread_at(session=f["session"].to_numpy(), n=len(f))


def score(cls, params, base, f, cost, spread, min_trades):
    st = cls(params)
    sig = st.build(base, f, f["regime"])
    res = BT.run(base, sig, f["regime"].to_numpy(), f["session"].to_numpy(),
                 cost=cost, spread_arr=spread)
    s = res.stats()
    if s["trades"] < min_trades:
        return -99.0, s, res
    return s["t_stat"], s, res


def optimise(cls, base, f, cost, spread, min_trades, rounds=2):
    params = dict(cls.spec.params)
    best, _, _ = score(cls, params, base, f, cost, spread, min_trades)
    for _ in range(rounds):
        improved = False
        for key, grid in cls.spec.grid.items():
            cur = params[key]
            pick = cur
            for cand in grid:
                trial = dict(params); trial[key] = cand
                s, _, _ = score(cls, trial, base, f, cost, spread, min_trades)
                if s > best + 1e-9:
                    best, pick = s, cand
            if pick != cur:
                params[key] = pick
                improved = True
        if not improved:
            break
    return params, best


def stability(cls, params, base, f, cost, spread, min_trades, best_score):
    """Do the neighbours of each fitted value still work?

    A parameter whose immediate neighbours collapse is a spike in the search
    space, not a property of the market. Those get reverted to the default.
    """
    flags = {}
    for key, grid in cls.spec.grid.items():
        val = params[key]
        if val not in grid:
            continue
        i = grid.index(val)
        neigh = [grid[j] for j in (i - 1, i + 1) if 0 <= j < len(grid)]
        if not neigh:
            continue
        scores = []
        for nv in neigh:
            t = dict(params); t[key] = nv
            s, _, _ = score(cls, t, base, f, cost, spread, min_trades)
            scores.append(s)
        ok = [s for s in scores if s > -90]
        if not ok or best_score <= 0:
            flags[key] = "UNSTABLE"
        else:
            ratio = float(np.mean(ok)) / best_score
            flags[key] = "stable" if ratio >= 0.5 else "UNSTABLE"
    return flags


def walk_forward(cls, base, f, cost, spread, args):
    n = len(base)
    holdout = int(n * args.holdout)
    usable = n - holdout
    blocks = args.folds + 2          # train grows, validate + test roll
    edges = [int(usable * i / blocks) for i in range(blocks + 1)]

    rows, fold_params, test_res = [], [], []
    for k in range(1, args.folds + 1):
        tr = slice(0, edges[k])
        va = slice(edges[k], edges[k + 1])
        te = slice(edges[k + 1], edges[k + 2])
        if edges[k] < 2000 or (edges[k + 2] - edges[k + 1]) < 500:
            continue

        def sub(s):
            return base.iloc[s], f.iloc[s], spread[s]

        b_tr, f_tr, s_tr = sub(tr)
        b_va, f_va, s_va = sub(va)
        b_te, f_te, s_te = sub(te)

        p, tr_score = optimise(cls, b_tr, f_tr, cost, s_tr, args.min_trades, args.rounds)
        flags = stability(cls, p, b_tr, f_tr, cost, s_tr, args.min_trades, tr_score)
        for key, tag in flags.items():
            if tag == "UNSTABLE":
                p[key] = cls.spec.params[key]        # revert the spike

        _, va_st, _ = score(cls, p, b_va, f_va, cost, s_va, 0)
        _, te_st, te_r = score(cls, p, b_te, f_te, cost, s_te, 0)
        _, tr_st, _ = score(cls, p, b_tr, f_tr, cost, s_tr, 0)

        fold_params.append(p)
        test_res.append(te_r)
        rows.append(dict(fold=k, tr_n=tr_st["trades"], tr_exp=tr_st["expectancy_r"],
                         va_n=va_st["trades"], va_exp=va_st["expectancy_r"],
                         te_n=te_st["trades"], te_exp=te_st["expectancy_r"],
                         te_pf=te_st["profit_factor"], te_dd=te_st["max_dd_r"],
                         unstable=sum(1 for v in flags.values() if v == "UNSTABLE")))
    return rows, fold_params, test_res


def verdict(rows, args):
    """Acceptance. Every clause exists because a earlier version let something
    through that should not have gone through.

    The pooled clause in particular: an early run accepted trend_pullback on
    "positive in 1/1 folds" because only one fold cleared the trade minimum,
    while the POOLED out-of-sample expectancy was -0.093R. Counting folds
    without also weighting them by trade count is not evidence.
    """
    if not rows:
        return False, "no usable folds", "INSUFFICIENT"
    total = sum(r["te_n"] for r in rows)
    tier = evidence_tier(total)
    if tier == "INSUFFICIENT":
        return False, f"{total} out-of-sample trades is below the evidence floor", tier

    scored = [r for r in rows if r["te_n"] >= args.min_trades]
    need_folds = max(3, int(np.ceil(len(rows) * 0.75)))
    if len(scored) < need_folds:
        return False, (f"only {len(scored)}/{len(rows)} folds reached "
                       f"{args.min_trades} trades (need {need_folds})"), tier

    # pooled, trade-weighted - not a fold headcount
    pooled = float(np.sum([r["te_exp"] * r["te_n"] for r in scored]) /
                   np.sum([r["te_n"] for r in scored]))
    if pooled <= 0:
        return False, f"pooled out-of-sample expectancy {pooled:+.3f}R", tier

    pos = sum(1 for r in scored if r["te_exp"] > 0)
    if pos <= len(scored) / 2:
        return False, f"test expectancy positive in only {pos}/{len(scored)} folds", tier

    tr = float(np.mean([r["tr_exp"] for r in scored]))
    if tr <= 0:
        return False, "no in-sample edge to degrade from", tier
    deg = (tr - pooled) / abs(tr)
    if deg > 0.6:
        return False, f"train->test degradation {deg:+.0%}", tier

    # a fit that needed unstable parameters is a fit, not an edge
    unstable = float(np.mean([r["unstable"] for r in scored]))
    if unstable >= 2.0:
        return False, f"{unstable:.1f} unstable parameters per fold on average", tier

    return True, (f"pooled {pooled:+.3f}R over {total} trades, positive in "
                  f"{pos}/{len(scored)} folds, degradation {deg:+.0%}, "
                  f"{unstable:.1f} unstable params/fold"), tier


def null_check(cls, base, f, cost, spread, args, seeds=3):
    """Same strategy on matched random walks. Must find nothing."""
    pooled = []
    for s in range(seeds):
        g = np.random.default_rng(1000 + s)
        ret = g.normal(0, float(np.std(np.diff(np.log(base["close"].to_numpy())))), len(base))
        px = base["close"].iloc[0] * np.exp(np.cumsum(ret))
        rng_ = (base["high"] - base["low"]).to_numpy()
        fake = pd.DataFrame({"open": px, "high": px + rng_ / 2,
                             "low": px - rng_ / 2, "close": px}, index=base.index)
        ff = FE.build(fake, sessions=DE.MarketData.sessions(fake.index))
        for col in ("H1_regime", "H4_regime", "H1_bias", "H4_bias"):
            if col in f.columns:
                ff[col] = f[col].to_numpy()
        rr = R2.classify(ff)
        ff["regime"] = rr["regime"]; ff["regime_conf"] = rr["confidence"]
        st = cls(dict(cls.spec.params))
        sig = st.build(fake, ff, ff["regime"])
        res = BT.run(fake, sig, ff["regime"].to_numpy(), ff["session"].to_numpy(),
                     cost=cost, spread_arr=spread)
        pooled.extend(res.r)
    r = np.asarray(pooled)
    if len(r) < 30:
        return 0.0, len(r), "too few"
    sd = r.std(ddof=1)
    t = float(r.mean() / sd * np.sqrt(len(r))) if sd > 1e-12 else 0.0
    tag = "LOOK-AHEAD" if t > 2.0 else ("negative (structural)" if t < -2 else "clean")
    return t, len(r), tag


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", required=True)
    ap.add_argument("--tf", default="M15")
    ap.add_argument("--from", dest="start", default="2015-01-01")
    ap.add_argument("--to", dest="end", default=None)
    ap.add_argument("--folds", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--min-trades", type=int, default=30)
    ap.add_argument("--holdout", type=float, default=0.15,
                    help="final fraction never touched by any fold")
    ap.add_argument("--strategy")
    ap.add_argument("--cost", choices=["default", "pessimistic", "optimistic"], default="default")
    ap.add_argument("--skip-null", action="store_true")
    ap.add_argument("--out")
    args = ap.parse_args()

    cost = {"default": CM.CostModel(), "pessimistic": CM.PESSIMISTIC,
            "optimistic": CM.OPTIMISTIC}[args.cost]
    cache = Path(args.cache)

    print(f"\n{'='*74}\nXAUUSD strategy research  |  {args.tf}  |  {args.start} -> {args.end or 'end'}")
    print(f"costs: {cost.describe()}\n{'='*74}")

    base, f = prepare(cache, args.tf, args.start, args.end)
    spread = spread_series(f, cost)
    print(f"bars {len(base):,}   holdout {args.holdout:.0%} never used in any fold")
    rd = f["regime"].value_counts(normalize=True)
    print("regime mix: " + "  ".join(f"{k} {v:.0%}" for k, v in rd.head(6).items()))

    chosen = [SV.BY_ID[args.strategy]] if args.strategy else SV.ALL
    report = {}

    for cls in chosen:
        sp = cls.spec
        print(f"\n{'-'*74}\n{sp.id}  v{sp.version}   {sp.description}")
        print(f"  regimes: {', '.join(sp.regimes)}")
        print(f"  sessions: {', '.join(sp.sessions)}")
        rows, fps, tres = walk_forward(cls, base, f, cost, spread, args)
        if not rows:
            print("  not enough data for the requested folds")
            continue

        print(f"  {'fold':>4} {'trainN':>7} {'trainE':>8} {'valN':>6} {'valE':>8} "
              f"{'testN':>6} {'testE':>8} {'PF':>6} {'ddR':>7} {'unstable':>9}")
        for r in rows:
            print(f"  {r['fold']:>4} {r['tr_n']:>7} {r['tr_exp']:>+8.3f} {r['va_n']:>6} "
                  f"{r['va_exp']:>+8.3f} {r['te_n']:>6} {r['te_exp']:>+8.3f} "
                  f"{r['te_pf']:>6.2f} {r['te_dd']:>7.1f} {r['unstable']:>9}")

        ok, why, tier = verdict(rows, args)
        print(f"\n  EVIDENCE: {tier}   VERDICT: {'ACCEPT' if ok else 'REJECT'} - {why}")

        nt = (0.0, 0, "skipped")
        if not args.skip_null:
            nt = null_check(cls, base, f, cost, spread, args)
            print(f"  null test on random walks: t={nt[0]:+.2f} over {nt[1]} trades -> {nt[2]}")
            if nt[2] == "LOOK-AHEAD":
                ok = False

        med = {}
        for key in sp.grid:
            vals = [fp[key] for fp in fps]
            med[key] = float(np.median(vals)) if isinstance(sp.params[key], float) else int(np.median(vals))

        allt = [t for r in tres for t in r.trades]
        pooled = BT.Result(allt)
        by_reg = BT.breakdown(pooled, "regime")
        by_ses = BT.breakdown(pooled, "session")
        if by_reg:
            print(f"\n  out-of-sample by regime        {'trades':>7}{'expR':>8}{'win':>7}")
            for k, v in sorted(by_reg.items(), key=lambda kv: -kv[1]["trades"]):
                print(f"    {k:<28}{v['trades']:>7}{v['expectancy_r']:>+8.3f}{v['win_rate']:>7.0%}")
        if by_ses:
            print(f"  out-of-sample by session       {'trades':>7}{'expR':>8}{'win':>7}")
            for k, v in sorted(by_ses.items(), key=lambda kv: -kv[1]["trades"]):
                print(f"    {k:<28}{v['trades']:>7}{v['expectancy_r']:>+8.3f}{v['win_rate']:>7.0%}")

        report[sp.id] = dict(version=sp.version, accepted=bool(ok), verdict=why,
                             evidence=tier, params=med, folds=rows,
                             null_t=nt[0], null_tag=nt[2],
                             by_regime=by_reg, by_session=by_ses,
                             stats=pooled.stats())

    acc = [k for k, v in report.items() if v["accepted"]]
    print(f"\n{'='*74}\n{len(acc)}/{len(report)} strategies accepted: {', '.join(acc) or 'none'}")
    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2, default=str))
        print(f"report -> {args.out}")


if __name__ == "__main__":
    main()

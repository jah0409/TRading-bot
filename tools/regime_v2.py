#!/usr/bin/env python3
"""
regime_v2.py - eight regimes, scored from the causal feature set.

Extends the original five with the three the live system was missing:

  TRANSITION  structure is changing hands. A CHoCH has fired, or the top two
              regime scores are too close to separate. Most strategies should
              stand aside here rather than guess which side wins.
  HIGH_VOL /  volatility as its own axis, because "trending" at 3x normal ATR
  LOW_VOL     is a different trade from "trending" at 0.6x.
  ABNORMAL    the market is not behaving like a market: volatility far outside
              anything in the lookback, a single bar moving many ATR, or a
              feed gap. This one is not a trading regime, it is a STOP.

Still an argmax over soft ramps - every threshold moves continuously, so the
classifier is fittable and a bar one tick either side of a boundary does not
flip the whole strategy mix.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

TRENDING_BULL, TRENDING_BEAR, RANGING, BREAKOUT = "TRENDING_BULL", "TRENDING_BEAR", "RANGING", "BREAKOUT"
HIGH_VOLATILITY, LOW_VOLATILITY = "HIGH_VOLATILITY", "LOW_VOLATILITY"
TRANSITION, ABNORMAL, UNKNOWN = "TRANSITION", "ABNORMAL", "UNKNOWN"

REGIMES = [TRENDING_BULL, TRENDING_BEAR, RANGING, BREAKOUT,
           HIGH_VOLATILITY, LOW_VOLATILITY, TRANSITION, ABNORMAL]

DEFAULTS = {
    "adx_trend_lo": 20.0, "adx_trend_hi": 32.0,
    "adx_range_lo": 14.0, "adx_range_hi": 26.0,
    "di_spread_lo": 0.10, "di_spread_hi": 0.38,
    "atr_vol_lo": 0.55, "atr_vol_hi": 0.85,
    "atr_quiet_lo": 0.15, "atr_quiet_hi": 0.40,
    "atr_expansion_lo": 1.15, "atr_expansion_hi": 1.75,
    "min_score": 0.18,
    "transition_margin": 0.12,      # top two scores this close => TRANSITION
    "abnormal_atr_expansion": 3.0,  # ATR this many x its own mean => ABNORMAL
    "abnormal_bar_atr": 6.0,        # single bar this many ATR => ABNORMAL
    "choch_transition_bars": 5,     # bars a CHoCH keeps the market in TRANSITION
}


def ramp(x, lo, hi):
    x = np.asarray(x, float)
    if hi <= lo:
        return (x >= hi).astype(float)
    return np.clip((x - lo) / (hi - lo), 0.0, 1.0)


def classify(f: pd.DataFrame, p: dict | None = None) -> pd.DataFrame:
    """Returns regime, confidence and the individual scores, per bar."""
    p = {**DEFAULTS, **(p or {})}
    n = len(f)

    adx_strength = ramp(f["adx"], p["adx_trend_lo"], p["adx_trend_hi"])
    adx_weak = 1.0 - ramp(f["adx"], p["adx_range_lo"], p["adx_range_hi"])
    directional = ramp(f["di_spread_norm"], p["di_spread_lo"], p["di_spread_hi"])
    vol_high = ramp(f["atr_percentile"], p["atr_vol_lo"], p["atr_vol_hi"])
    vol_low = 1.0 - ramp(f["atr_percentile"], p["atr_quiet_lo"], p["atr_quiet_hi"])
    expansion = ramp(f["atr_expansion"], p["atr_expansion_lo"], p["atr_expansion_hi"])

    up = (f["di_plus"] > f["di_minus"]).to_numpy()
    struct_up = (f["struct_bias"] > 0).to_numpy()
    struct_dn = (f["struct_bias"] < 0).to_numpy()
    ema_bull = f["ema_stack_bull"].to_numpy().astype(float)
    ema_bear = f["ema_stack_bear"].to_numpy().astype(float)

    # trend needs ADX, DI agreement AND structure/EMA confirmation. Requiring
    # three independent reads is what stops a single noisy ADX spike from
    # relabelling a range as a trend.
    trend = adx_strength * directional
    bull = trend * (0.5 + 0.25 * struct_up + 0.25 * ema_bull)
    bear = trend * (0.5 + 0.25 * struct_dn + 0.25 * ema_bear)

    s = pd.DataFrame(index=f.index)
    s[TRENDING_BULL] = np.where(up, bull, 0.0)
    s[TRENDING_BEAR] = np.where(~up, bear, 0.0)
    s[RANGING] = adx_weak * (1.0 - vol_high) * (1.0 - expansion * 0.5)
    s[BREAKOUT] = expansion * (1.0 - adx_strength) * \
        (0.5 + 0.5 * f["displacement"].to_numpy().astype(float))
    s[HIGH_VOLATILITY] = vol_high * (1.0 - directional)
    s[LOW_VOLATILITY] = vol_low * adx_weak
    s[TRANSITION] = 0.0
    s[ABNORMAL] = 0.0

    arr = s[REGIMES].to_numpy()
    arr = np.nan_to_num(arr)
    order = np.argsort(arr, axis=1)
    best_i = order[:, -1]
    best_v = arr[np.arange(n), best_i]
    second = arr[np.arange(n), order[:, -2]]

    label = np.array(REGIMES, dtype=object)[best_i]
    with np.errstate(divide="ignore", invalid="ignore"):
        margin = np.where(best_v > 0, (best_v - second) / best_v, 0.0)
    conf = np.clip(0.5 * best_v + 0.5 * margin, 0.0, 1.0)

    # --- TRANSITION overrides a weak-margin call, or a recent CHoCH ---------
    choch = (f["choch_up"] | f["choch_down"]).to_numpy()
    recent_choch = pd.Series(choch).rolling(
        p["choch_transition_bars"], min_periods=1).max().to_numpy().astype(bool)
    ambiguous = (best_v > 0) & ((best_v - second) < p["transition_margin"] * best_v)
    trans = recent_choch | ambiguous
    label = np.where(trans, TRANSITION, label)
    conf = np.where(trans, np.minimum(conf, 0.4), conf)

    # --- ABNORMAL overrides everything. Not a regime, a stop. ---------------
    bar_atr = np.where(f["atr"].to_numpy() > 0,
                       f["bar_range"].to_numpy() / f["atr"].to_numpy(), 0.0)
    abnormal = ((f["atr_expansion"].to_numpy() > p["abnormal_atr_expansion"]) |
                (bar_atr > p["abnormal_bar_atr"]) |
                ~np.isfinite(f["atr"].to_numpy()))
    label = np.where(abnormal, ABNORMAL, label)
    conf = np.where(abnormal, 1.0, conf)

    weak = (best_v < p["min_score"]) & ~abnormal & ~trans
    label = np.where(weak, UNKNOWN, label)
    conf = np.where(weak, 0.0, conf)

    out = s.copy()
    out["regime"] = label
    out["confidence"] = conf
    return out


def multi_timeframe(regimes: dict[str, pd.Series], weights: dict[str, float]) -> pd.Series:
    """Blend per-timeframe labels, with the higher timeframe holding a veto.

    A lower timeframe cannot claim TRENDING_BULL while H4 says TRENDING_BEAR;
    that combination becomes TRANSITION. This is the "do not let one timeframe
    override the larger context without validation" rule, made explicit.
    """
    base = next(iter(regimes.values())).index
    votes = pd.DataFrame(index=base)
    for tf, r in regimes.items():
        votes[tf] = r.reindex(base, method="ffill")

    htf = votes.columns[-1]
    out = []
    for _, row in votes.iterrows():
        if ABNORMAL in row.values:
            out.append(ABNORMAL); continue
        score: dict[str, float] = {}
        for tf, lab in row.items():
            if lab in (UNKNOWN,):
                continue
            score[lab] = score.get(lab, 0.0) + weights.get(tf, 1.0)
        if not score:
            out.append(UNKNOWN); continue
        best = max(score, key=score.get)
        h = row[htf]
        conflict = ((best == TRENDING_BULL and h == TRENDING_BEAR) or
                    (best == TRENDING_BEAR and h == TRENDING_BULL))
        out.append(TRANSITION if conflict else best)
    return pd.Series(out, index=base, name="regime_mtf")

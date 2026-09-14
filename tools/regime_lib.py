"""
regime_lib.py - Python mirror of MQL5/Include/Adaptive/Regime/RegimeFeatures.mqh

Every function here must behave identically to its MQL5 twin. When you change
one, change the other. The calibration results are only meaningful because the
thresholds are fitted against the same arithmetic the EA runs live.

Also provides Wilder ATR/ADX so calibration can run from raw OHLC when no MT5
export is available (offline data, or the synthetic self-test).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# --- regime codes, matching ENUM_REGIME -------------------------------------
UNKNOWN, TREND_UP, TREND_DOWN, RANGE, BREAKOUT, CHOP_HIVOL = 0, 1, 2, 3, 4, 5

REGIME_NAMES = {
    UNKNOWN: "UNKNOWN", TREND_UP: "TREND_UP", TREND_DOWN: "TREND_DOWN",
    RANGE: "RANGE", BREAKOUT: "BREAKOUT", CHOP_HIVOL: "CHOP_HIVOL",
}
NAME_TO_REGIME = {v: k for k, v in REGIME_NAMES.items()}

# --- candle flag bits, matching Types.mqh -----------------------------------
CANDLE_INSIDE_BAR = 1 << 0
CANDLE_OUTSIDE_BAR = 1 << 1
CANDLE_NR7 = 1 << 2
CANDLE_WIDE_RANGE = 1 << 3
CANDLE_PIN_BULL = 1 << 4
CANDLE_PIN_BEAR = 1 << 5
CANDLE_ENGULF_BULL = 1 << 6
CANDLE_ENGULF_BEAR = 1 << 7
CANDLE_DOJI = 1 << 8

# --- the tunable surface ----------------------------------------------------
DEFAULT_PARAMS = {
    "adx_trend_lo": 20.0, "adx_trend_hi": 35.0,
    "adx_range_lo": 15.0, "adx_range_hi": 28.0,
    "di_spread_lo": 0.10, "di_spread_hi": 0.40,
    "atr_vol_lo": 0.55, "atr_vol_hi": 0.85,
    "atr_expansion_lo": 1.15, "atr_expansion_hi": 1.80,
    "compression_min": 0.20,
    "min_score_to_classify": 0.20,
}


def ramp(x, lo, hi):
    """RegimeRamp(): 0 at or below lo, 1 at or above hi, linear between."""
    x = np.asarray(x, dtype=float)
    if hi <= lo:
        return (x >= hi).astype(float)
    return np.clip((x - lo) / (hi - lo), 0.0, 1.0)


# ---------------------------------------------------------------------------
# Wilder indicators. MT5's iATR and iADX both use Wilder (SMMA) smoothing.
# ---------------------------------------------------------------------------
def wilder_smooth(values: np.ndarray, period: int) -> np.ndarray:
    """First value is the simple mean of the first `period`; then SMMA.

    prev*(n-1)/n + cur/n is exactly an EWM with alpha = 1/n and adjust=False,
    so this defers to pandas' C implementation. The harness calls this tens of
    thousands of times; the Python loop it replaces was the single biggest
    cost in a walk-forward run.
    """
    v = np.asarray(values, dtype=float)
    n = len(v)
    if n < period:
        return np.full(n, np.nan)
    seeded = np.where(np.isfinite(v), v, 0.0).astype(float)
    s = pd.Series(seeded)
    s.iloc[:period - 1] = np.nan
    s.iloc[period - 1] = float(np.nanmean(v[:period]))
    return s.ewm(alpha=1.0 / period, adjust=False, ignore_na=True).mean().to_numpy()


def true_range(high, low, close) -> np.ndarray:
    h, l, c = map(lambda a: np.asarray(a, dtype=float), (high, low, close))
    pc = np.roll(c, 1)
    pc[0] = c[0]
    return np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))


def atr(high, low, close, period=14) -> np.ndarray:
    return wilder_smooth(true_range(high, low, close), period)


def adx(high, low, close, period=14):
    """Returns (adx, di_plus, di_minus), Wilder's canonical formulation."""
    h, l, c = map(lambda a: np.asarray(a, dtype=float), (high, low, close))
    n = len(h)
    up = np.zeros(n)
    dn = np.zeros(n)
    up[1:] = h[1:] - h[:-1]
    dn[1:] = l[:-1] - l[1:]

    plus_dm = np.where((up > dn) & (up > 0), up, 0.0)
    minus_dm = np.where((dn > up) & (dn > 0), dn, 0.0)

    tr_s = wilder_smooth(true_range(h, l, c), period)
    pdm_s = wilder_smooth(plus_dm, period)
    mdm_s = wilder_smooth(minus_dm, period)

    with np.errstate(divide="ignore", invalid="ignore"):
        di_p = 100.0 * np.where(tr_s > 0, pdm_s / tr_s, np.nan)
        di_m = 100.0 * np.where(tr_s > 0, mdm_s / tr_s, np.nan)
        denom = di_p + di_m
        dx = 100.0 * np.where(denom > 0, np.abs(di_p - di_m) / denom, np.nan)

    return wilder_smooth(np.nan_to_num(dx, nan=0.0), period), di_p, di_m


# ---------------------------------------------------------------------------
# Feature construction - mirrors CRegimeDetector::Evaluate and the exporter
# ---------------------------------------------------------------------------
def candle_flags(df: pd.DataFrame) -> np.ndarray:
    """ComputeCandleFlags() for every bar, vectorised. Chronological order."""
    h, l = df["high"].to_numpy(float), df["low"].to_numpy(float)
    o, c = df["open"].to_numpy(float), df["close"].to_numpy(float)
    n = len(df)
    rng = h - l
    body = np.abs(c - o)
    upper = h - np.maximum(o, c)
    lower = np.minimum(o, c) - l

    flags = np.zeros(n, dtype=np.int64)
    ph, pl = np.roll(h, 1), np.roll(l, 1)
    po, pc = np.roll(o, 1), np.roll(c, 1)

    valid = rng > 0
    flags |= np.where(valid & (h <= ph) & (l >= pl), CANDLE_INSIDE_BAR, 0)
    flags |= np.where(valid & (h > ph) & (l < pl), CANDLE_OUTSIDE_BAR, 0)

    # NR7: narrowest of the last seven (this bar plus six prior)
    prior_min = pd.Series(rng).shift(1).rolling(6).min().to_numpy()
    flags |= np.where(valid & np.isfinite(prior_min) & (rng < prior_min), CANDLE_NR7, 0)

    prior_mean = pd.Series(rng).shift(1).rolling(6).mean().to_numpy()
    flags |= np.where(valid & np.isfinite(prior_mean) & (rng > 1.5 * prior_mean),
                      CANDLE_WIDE_RANGE, 0)

    flags |= np.where(valid & (body <= 0.1 * rng), CANDLE_DOJI, 0)
    flags |= np.where(valid & (lower >= 2 * body) & (lower > upper), CANDLE_PIN_BULL, 0)
    flags |= np.where(valid & (upper >= 2 * body) & (upper > lower), CANDLE_PIN_BEAR, 0)

    pb_hi, pb_lo = np.maximum(po, pc), np.minimum(po, pc)
    flags |= np.where(valid & (c > o) & (c >= pb_hi) & (o <= pb_lo), CANDLE_ENGULF_BULL, 0)
    flags |= np.where(valid & (c < o) & (o >= pb_hi) & (c <= pb_lo), CANDLE_ENGULF_BEAR, 0)

    flags[0] = 0
    return flags


def compression(df: pd.DataFrame, lookback: int) -> np.ndarray:
    """ComputeCompression(): mean range vs median range over the PRIOR window."""
    rng = pd.Series(df["high"].to_numpy(float) - df["low"].to_numpy(float))
    prior = rng.shift(1)
    mean = prior.rolling(lookback).mean().to_numpy()
    med = prior.rolling(lookback).median().to_numpy()
    with np.errstate(divide="ignore", invalid="ignore"):
        ratio = np.where(med > 0, mean / med, np.nan)
    return np.clip(1.5 - ratio, 0.0, 1.0)


def build_features(df: pd.DataFrame, atr_period=14, adx_period=14,
                   pct_lookback=100, compression_lookback=10) -> pd.DataFrame:
    """Raw OHLC -> the exact feature set the live detector sees."""
    df = df.reset_index(drop=True).copy()
    h, l, c = df["high"].to_numpy(float), df["low"].to_numpy(float), df["close"].to_numpy(float)

    a = atr(h, l, c, atr_period)
    adx_v, di_p, di_m = adx(h, l, c, adx_period)

    # percentile and expansion are measured over the window BEFORE each bar,
    # exactly as the exporter does (k = i+1 .. i+lookback in series order)
    prior = pd.Series(a).shift(1)

    # rank of the current ATR within that prior window
    rank = np.full(len(df), np.nan)
    arr = a.astype(float)
    for i in range(pct_lookback, len(df)):
        win = arr[i - pct_lookback:i]
        win = win[np.isfinite(win) & (win > 0)]
        if len(win) == 0 or not np.isfinite(arr[i]):
            continue
        rank[i] = float((win < arr[i]).sum()) / len(win)

    mean_prior = prior.rolling(pct_lookback).mean().to_numpy()
    with np.errstate(divide="ignore", invalid="ignore"):
        expansion = np.where(mean_prior > 0, a / mean_prior, 1.0)

    di_sum = di_p + di_m
    with np.errstate(divide="ignore", invalid="ignore"):
        di_norm = np.where(di_sum > 0, np.abs(di_p - di_m) / di_sum, 0.0)

    out = pd.DataFrame({
        "close": c,
        "atr": a,
        "atr_pct": np.where(c > 0, a / c, np.nan),
        "atr_percentile": rank,
        "atr_expansion": expansion,
        "adx": adx_v,
        "di_plus": di_p,
        "di_minus": di_m,
        "di_spread_norm": di_norm,
        "candle_flags": candle_flags(df),
        "compression": compression(df, compression_lookback),
    })
    if "time" in df.columns:
        out.insert(0, "time", df["time"].to_numpy())
    return out


# ---------------------------------------------------------------------------
# Scoring - the exact mirror of ComputeRegimeScores / ClassifyFromScores
# ---------------------------------------------------------------------------
def compute_scores(f: pd.DataFrame, p: dict) -> pd.DataFrame:
    adx_strength = ramp(f["adx"], p["adx_trend_lo"], p["adx_trend_hi"])
    adx_weakness = 1.0 - ramp(f["adx"], p["adx_range_lo"], p["adx_range_hi"])
    directional = ramp(f["di_spread_norm"], p["di_spread_lo"], p["di_spread_hi"])
    vol_high = ramp(f["atr_percentile"], p["atr_vol_lo"], p["atr_vol_hi"])
    expansion = ramp(f["atr_expansion"], p["atr_expansion_lo"], p["atr_expansion_hi"])

    flags = f["candle_flags"].to_numpy(np.int64)
    coiled_now = (flags & (CANDLE_NR7 | CANDLE_INSIDE_BAR)) != 0
    expanding_now = (flags & (CANDLE_WIDE_RANGE | CANDLE_OUTSIDE_BAR)) != 0

    trend = adx_strength * directional
    up = f["di_plus"].to_numpy(float) > f["di_minus"].to_numpy(float)

    rng_score = adx_weakness * (1.0 - vol_high)
    rng_score = np.where(coiled_now, np.minimum(1.0, rng_score * 1.15), rng_score)

    coil = ramp(f["compression"], p["compression_min"], 1.0)
    bo = expansion * coil * (1.0 - adx_strength)
    bo = np.where(expanding_now, np.minimum(1.0, bo * 1.20), bo)

    return pd.DataFrame({
        "trend_up": np.where(up, trend, 0.0),
        "trend_down": np.where(~up, trend, 0.0),
        "range": rng_score,
        "breakout": bo,
        "chop": vol_high * adx_weakness * (1.0 - directional),
    })


def classify(scores: pd.DataFrame, p: dict):
    """Returns (regime codes, confidence). Mirrors ClassifyFromScores()."""
    cols = ["trend_up", "trend_down", "range", "breakout", "chop"]
    codes = np.array([TREND_UP, TREND_DOWN, RANGE, BREAKOUT, CHOP_HIVOL])
    m = scores[cols].to_numpy(float)
    m = np.nan_to_num(m, nan=0.0)

    best_i = m.argmax(axis=1)
    best_v = m.max(axis=1)

    part = np.partition(m, -2, axis=1)
    second = part[:, -2]

    with np.errstate(divide="ignore", invalid="ignore"):
        margin = np.where(best_v > 0, (best_v - second) / best_v, 0.0)
    conf = np.clip(0.5 * best_v + 0.5 * margin, 0.0, 1.0)

    regime = codes[best_i]
    weak = best_v < p["min_score_to_classify"]
    regime = np.where(weak, UNKNOWN, regime)
    conf = np.where(weak, 0.0, conf)
    return regime, conf

#!/usr/bin/env python3
"""
feature_engine.py - objective market features, all strictly causal.

Every column answers "what was knowable at the CLOSE of this bar". That
constraint drives the design more than anything else:

  * A swing high at bar i needs k bars after it to be confirmed, so it does not
    appear in the feature set until bar i+k. Marking it at bar i would leak k
    bars of the future into every structure signal built on top of it.
  * Previous-day and previous-week levels roll at the session boundary, using
    only completed days/weeks.
  * Rolling statistics (ATR percentile) rank against the window BEFORE the
    current bar, never including it.

Nothing here decides anything. Strategies consume these columns; the feature
engine has no opinion about what a good trade looks like.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Volatility / momentum primitives (Wilder, matching the MQL5 side)
# ---------------------------------------------------------------------------
def wilder(v: np.ndarray, period: int) -> np.ndarray:
    v = np.asarray(v, float)
    n = len(v)
    if n < period:
        return np.full(n, np.nan)
    s = pd.Series(np.where(np.isfinite(v), v, 0.0))
    s.iloc[:period - 1] = np.nan
    s.iloc[period - 1] = float(np.nanmean(v[:period]))
    return s.ewm(alpha=1.0 / period, adjust=False, ignore_na=True).mean().to_numpy()


def true_range(h, l, c) -> np.ndarray:
    pc = np.roll(np.asarray(c, float), 1)
    pc[0] = c[0]
    return np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))


def atr(df: pd.DataFrame, period=14) -> np.ndarray:
    return wilder(true_range(df["high"].to_numpy(float), df["low"].to_numpy(float),
                             df["close"].to_numpy(float)), period)


def adx(df: pd.DataFrame, period=14):
    h, l, c = (df[x].to_numpy(float) for x in ("high", "low", "close"))
    up = np.zeros(len(h)); dn = np.zeros(len(h))
    up[1:] = h[1:] - h[:-1]
    dn[1:] = l[:-1] - l[1:]
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    mdm = np.where((dn > up) & (dn > 0), dn, 0.0)
    trs = wilder(true_range(h, l, c), period)
    with np.errstate(divide="ignore", invalid="ignore"):
        dip = 100 * np.where(trs > 0, wilder(pdm, period) / trs, np.nan)
        dim = 100 * np.where(trs > 0, wilder(mdm, period) / trs, np.nan)
        den = dip + dim
        dx = 100 * np.where(den > 0, np.abs(dip - dim) / den, np.nan)
    return wilder(np.nan_to_num(dx), period), dip, dim


def ema(v, period: int) -> np.ndarray:
    v = np.asarray(v, float)
    if len(v) < period:
        return np.full(len(v), np.nan)
    s = pd.Series(v.copy())
    s.iloc[:period - 1] = np.nan
    s.iloc[period - 1] = float(np.mean(v[:period]))
    return s.ewm(alpha=2.0 / (period + 1), adjust=False, ignore_na=True).mean().to_numpy()


def rsi(c, period=14) -> np.ndarray:
    c = np.asarray(c, float)
    d = np.diff(c, prepend=c[0])
    g = wilder(np.where(d > 0, d, 0.0), period)
    lo = wilder(np.where(d < 0, -d, 0.0), period)
    with np.errstate(divide="ignore", invalid="ignore"):
        rs = np.where(lo > 0, g / lo, np.inf)
        out = 100 - 100 / (1 + rs)
    return np.where(np.isfinite(out), out, 100.0)


def rolling_percentile(v: np.ndarray, window: int) -> np.ndarray:
    """Rank of each value within the window BEFORE it. Never self-inclusive."""
    s = pd.Series(v)
    prior = s.shift(1)
    return prior.rolling(window).apply(
        lambda w: np.nan, raw=True) if False else _rank_prior(v, window)


def _rank_prior(v: np.ndarray, window: int) -> np.ndarray:
    out = np.full(len(v), np.nan)
    for i in range(window, len(v)):
        w = v[i - window:i]
        w = w[np.isfinite(w)]
        if len(w) and np.isfinite(v[i]):
            out[i] = (w < v[i]).mean()
    return out


# ---------------------------------------------------------------------------
# Market structure
# ---------------------------------------------------------------------------
def swings(df: pd.DataFrame, k: int = 3):
    """Fractal swing points, reported only once CONFIRMED.

    A swing high at bar i needs k bars either side. It is therefore not
    knowable until bar i+k, and that is where it enters the feature set. The
    returned level/index columns are as-of arrays: at any bar they hold the
    most recent swing that had already been confirmed by then.
    """
    h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float)
    n = len(df)

    is_sh = np.zeros(n, bool)
    is_sl = np.zeros(n, bool)
    for i in range(k, n - k):
        wl, wr = slice(i - k, i), slice(i + 1, i + k + 1)
        if h[i] > h[wl].max() and h[i] > h[wr].max():
            is_sh[i] = True
        if l[i] < l[wl].min() and l[i] < l[wr].min():
            is_sl[i] = True

    # shift confirmation forward by k bars - this is the anti-leak step
    conf_sh = np.zeros(n, bool); conf_sh[k:] = is_sh[:-k]
    conf_sl = np.zeros(n, bool); conf_sl[k:] = is_sl[:-k]

    def asof(conf, src, idxsrc):
        lvl = np.full(n, np.nan); pos = np.full(n, np.nan)
        cur_l, cur_p = np.nan, np.nan
        for i in range(n):
            if conf[i]:
                cur_l, cur_p = src[i - k], i - k
            lvl[i], pos[i] = cur_l, cur_p
        return lvl, pos

    sh_lvl, sh_pos = asof(conf_sh, h, None)
    sl_lvl, sl_pos = asof(conf_sl, l, None)

    # previous confirmed swing, for HH/HL/LH/LL
    def prev_level(conf, src):
        out = np.full(n, np.nan)
        hist = []
        for i in range(n):
            if conf[i]:
                hist.append(src[i - k])
            out[i] = hist[-2] if len(hist) >= 2 else np.nan
        return out

    return {
        "swing_high": sh_lvl, "swing_high_bar": sh_pos,
        "swing_low": sl_lvl, "swing_low_bar": sl_pos,
        "prev_swing_high": prev_level(conf_sh, h),
        "prev_swing_low": prev_level(conf_sl, l),
        "new_swing_high": conf_sh, "new_swing_low": conf_sl,
    }


def structure(df: pd.DataFrame, sw: dict):
    """HH/HL/LH/LL labels, BOS and CHoCH - all from confirmed swings only."""
    n = len(df)
    c = df["close"].to_numpy(float)
    sh, psh = sw["swing_high"], sw["prev_swing_high"]
    sl, psl = sw["swing_low"], sw["prev_swing_low"]

    hh = np.where(np.isfinite(sh) & np.isfinite(psh), sh > psh, False)
    lh = np.where(np.isfinite(sh) & np.isfinite(psh), sh < psh, False)
    hl = np.where(np.isfinite(sl) & np.isfinite(psl), sl > psl, False)
    ll = np.where(np.isfinite(sl) & np.isfinite(psl), sl < psl, False)

    # bias: HH+HL = bullish structure, LH+LL = bearish
    bias = np.where(hh & hl, 1, np.where(lh & ll, -1, 0))
    bias = pd.Series(bias).replace(0, np.nan).ffill().fillna(0).to_numpy()

    # BOS is an EVENT, not a state: it fires on the bar that first closes
    # through the level. Testing "close > swing_high" alone marks every bar
    # price spends above the swing, which turned 17% of bars into breaks and
    # (via the CHoCH window) pushed 43% of the market into TRANSITION.
    above = np.isfinite(sh) & (c > sh)
    below = np.isfinite(sl) & (c < sl)
    prev_above = np.roll(above, 1); prev_above[0] = False
    prev_below = np.roll(below, 1); prev_below[0] = False
    bos_up = above & ~prev_above
    bos_dn = below & ~prev_below
    # the persistent state is still useful, just not as "a break happened"
    above_swing, below_swing = above, below

    # CHoCH: a break against the prevailing bias - the first sign it is turning
    choch_up = bos_up & (bias < 0)
    choch_dn = bos_dn & (bias > 0)

    return {"hh": hh, "hl": hl, "lh": lh, "ll": ll, "struct_bias": bias,
            "bos_up": bos_up, "bos_down": bos_dn,
            "above_swing_high": above_swing, "below_swing_low": below_swing,
            "choch_up": choch_up, "choch_down": choch_dn}


# ---------------------------------------------------------------------------
# Liquidity
# ---------------------------------------------------------------------------
def liquidity(df: pd.DataFrame, sw: dict, atr_v: np.ndarray, equal_tol_atr=0.10):
    """Reference levels traders cluster stops around, plus sweeps of them."""
    n = len(df)
    h, l, c = (df[x].to_numpy(float) for x in ("high", "low", "close"))
    idx = df.index

    # previous COMPLETED day / week
    day = pd.Series(h, index=idx).groupby(idx.normalize())
    pdh = day.max().shift(1).reindex(idx, method="ffill").to_numpy()
    pdl = pd.Series(l, index=idx).groupby(idx.normalize()).min().shift(1) \
            .reindex(idx, method="ffill").to_numpy()
    wk = idx.to_period("W")
    pwh = pd.Series(h, index=idx).groupby(wk).max().shift(1).reindex(wk).to_numpy()
    pwl = pd.Series(l, index=idx).groupby(wk).min().shift(1).reindex(wk).to_numpy()

    # equal highs/lows: two confirmed swings within a fraction of ATR
    tol = equal_tol_atr * atr_v
    eqh = np.isfinite(sw["prev_swing_high"]) & \
        (np.abs(sw["swing_high"] - sw["prev_swing_high"]) <= tol)
    eql = np.isfinite(sw["prev_swing_low"]) & \
        (np.abs(sw["swing_low"] - sw["prev_swing_low"]) <= tol)

    def sweep(level, above: bool):
        """Wick through a level, close back on the origin side - a stop raid."""
        if above:
            return np.isfinite(level) & (h > level) & (c < level)
        return np.isfinite(level) & (l < level) & (c > level)

    return {
        "pdh": pdh, "pdl": pdl, "pwh": pwh, "pwl": pwl,
        "equal_highs": eqh, "equal_lows": eql,
        "sweep_pdh": sweep(pdh, True), "sweep_pdl": sweep(pdl, False),
        "sweep_swing_high": sweep(sw["swing_high"], True),
        "sweep_swing_low": sweep(sw["swing_low"], False),
        "dist_pdh_atr": np.where(atr_v > 0, (pdh - c) / atr_v, np.nan),
        "dist_pdl_atr": np.where(atr_v > 0, (c - pdl) / atr_v, np.nan),
    }


# ---------------------------------------------------------------------------
# Price action
# ---------------------------------------------------------------------------
def price_action(df: pd.DataFrame, atr_v: np.ndarray, disp_atr=1.5, body_frac=0.6):
    o, h, l, c = (df[x].to_numpy(float) for x in ("open", "high", "low", "close"))
    n = len(df)
    rng = h - l
    body = np.abs(c - o)
    with np.errstate(divide="ignore", invalid="ignore"):
        body_ratio = np.where(rng > 0, body / rng, 0.0)

    displacement = (rng > disp_atr * atr_v) & (body_ratio > body_frac)
    impulse_up = displacement & (c > o)
    impulse_dn = displacement & (c < o)

    # consolidation: several bars of below-average range
    avg_rng = pd.Series(rng).rolling(20).mean().shift(1).to_numpy()
    contracted = pd.Series(rng < 0.7 * avg_rng).rolling(3).sum().to_numpy() >= 3

    # Fair value gaps (3-bar imbalance). Known at bar i, no shift needed.
    fvg_up = np.zeros(n, bool); fvg_dn = np.zeros(n, bool)
    fvg_top = np.full(n, np.nan); fvg_bot = np.full(n, np.nan)
    fvg_up[2:] = l[2:] > h[:-2]
    fvg_dn[2:] = h[2:] < l[:-2]
    fvg_bot[2:] = np.where(fvg_up[2:], h[:-2], np.nan)
    fvg_top[2:] = np.where(fvg_up[2:], l[2:], np.where(fvg_dn[2:], l[:-2], np.nan))
    fvg_bot[2:] = np.where(fvg_dn[2:], h[2:], fvg_bot[2:])

    # order block: last opposite-colour candle before a displacement
    ob_bull = np.zeros(n, bool); ob_bear = np.zeros(n, bool)
    ob_bull[1:] = impulse_up[1:] & (c[:-1] < o[:-1])
    ob_bear[1:] = impulse_dn[1:] & (c[:-1] > o[:-1])

    prev_hi = np.roll(h, 1); prev_lo = np.roll(l, 1)
    prev_bh = np.maximum(np.roll(o, 1), np.roll(c, 1))
    prev_bl = np.minimum(np.roll(o, 1), np.roll(c, 1))
    upper = h - np.maximum(o, c)
    lower = np.minimum(o, c) - l

    return {
        "bar_range": rng, "body_ratio": body_ratio,
        "displacement": displacement, "impulse_up": impulse_up, "impulse_down": impulse_dn,
        "consolidation": contracted,
        "fvg_up": fvg_up, "fvg_down": fvg_dn, "fvg_top": fvg_top, "fvg_bottom": fvg_bot,
        "ob_bull": ob_bull, "ob_bear": ob_bear,
        "rejection_bull": (lower >= 2 * body) & (lower > upper),
        "rejection_bear": (upper >= 2 * body) & (upper > lower),
        "engulf_bull": (c > o) & (c >= prev_bh) & (o <= prev_bl),
        "engulf_bear": (c < o) & (o >= prev_bh) & (c <= prev_bl),
        "failed_break_up": (h > prev_hi) & (c < prev_hi),
        "failed_break_dn": (l < prev_lo) & (c > prev_lo),
    }


# ---------------------------------------------------------------------------
def build(df: pd.DataFrame, *, atr_period=14, adx_period=14, pct_window=100,
          swing_k=3, sessions: pd.DataFrame | None = None) -> pd.DataFrame:
    """Full causal feature set for one timeframe."""
    out = pd.DataFrame(index=df.index)
    # carry OHLC through: strategies read price and features from one frame,
    # which removes a whole class of "which frame was that" bugs
    for col in ("open", "high", "low", "close", "volume"):
        if col in df.columns:
            out[col] = df[col].to_numpy()
    c = df["close"].to_numpy(float)

    a = atr(df, atr_period)
    out["atr"] = a
    out["atr_pct"] = np.where(c > 0, a / c, np.nan)
    out["atr_percentile"] = _rank_prior(a, pct_window)
    prior_mean = pd.Series(a).shift(1).rolling(pct_window).mean().to_numpy()
    out["atr_expansion"] = np.where(prior_mean > 0, a / prior_mean, 1.0)
    out["range_expanding"] = out["atr_expansion"] > 1.2
    out["range_contracting"] = out["atr_expansion"] < 0.85

    adx_v, dip, dim = adx(df, adx_period)
    out["adx"] = adx_v
    out["di_plus"] = dip
    out["di_minus"] = dim
    s = dip + dim
    out["di_spread_norm"] = np.where(s > 0, np.abs(dip - dim) / s, 0.0)

    for p in (21, 50, 200):
        out[f"ema{p}"] = ema(c, p)
    out["ema_stack_bull"] = (out["ema21"] > out["ema50"]) & (out["ema50"] > out["ema200"])
    out["ema_stack_bear"] = (out["ema21"] < out["ema50"]) & (out["ema50"] < out["ema200"])
    out["ema50_slope_atr"] = np.where(a > 0,
                                      (out["ema50"] - out["ema50"].shift(5)) / a, np.nan)
    out["rsi14"] = rsi(c, 14)
    out["dist_ema50_atr"] = np.where(a > 0, (c - out["ema50"]) / a, np.nan)

    sw = swings(df, swing_k)
    for k, v in sw.items():
        out[k] = v
    for k, v in structure(df, sw).items():
        out[k] = v
    for k, v in liquidity(df, sw, a).items():
        out[k] = v
    for k, v in price_action(df, a).items():
        out[k] = v

    if sessions is not None:
        for col in sessions.columns:
            out[col] = sessions[col].reindex(out.index).to_numpy()

    return out

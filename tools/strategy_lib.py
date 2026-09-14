"""
strategy_lib.py - Python mirrors of the five MQL5 strategies.

Each class mirrors one file under MQL5/Include/Adaptive/Strategies/. The rules
are transcribed, not reinvented: when you change a .mqh, change its twin here,
and re-run tools/check_parity.py to confirm the two still agree bar for bar.

Every strategy turns (bars, indicators, regime) into ARRAYS of decisions:

    entry_dir[i]    +1 long / -1 short / 0 nothing, decided on bar i
    entry_stop[i]   stop price for that entry (mandatory - no stop, no trade)
    entry_tp[i]     take profit, or nan for "managed by exit/trail"
    exit_long[i]    close an open long, decided on bar i
    exit_short[i]   close an open short
    exit_fraction_long[i] / exit_fraction_short[i]
                    1.0 = full close, 0.5 = half off
    trail_long[i]   candidate new stop for a long, or nan
    trail_short[i]  candidate new stop for a short
    trail_gate[i]   profit in PRICE required before trailing starts

Arrays, not callbacks, because the walk-forward harness runs thousands of
simulations and a per-bar Python callback per strategy would make that
unusable. The backtester consumes index i-1 at bar i, which is also how the
live EA behaves: it decides on the last CLOSED bar and fills at market.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

import regime_lib as R

NAN = float("nan")

#: mirrors risk.min_stop_atr_mult in config.json - a stop closer than this
#: many ATR is noise, and the live risk manager rejects it outright
MIN_STOP_ATR = 0.5


# ---------------------------------------------------------------------------
# Indicators, matching the MT5 built-ins the strategies call
# ---------------------------------------------------------------------------
def ema(values, period: int) -> np.ndarray:
    """iMA(..., MODE_EMA): SMA seed, then alpha = 2/(n+1).

    Defers to pandas' C EWM for the same reason wilder_smooth does - this sits
    in the innermost loop of the parameter search.
    """
    v = np.asarray(values, dtype=float)
    n = len(v)
    if n < period:
        return np.full(n, np.nan)
    s = pd.Series(v.copy())
    s.iloc[:period - 1] = np.nan
    s.iloc[period - 1] = float(np.mean(v[:period]))
    return s.ewm(alpha=2.0 / (period + 1.0), adjust=False,
                 ignore_na=True).mean().to_numpy()


def bollinger(close, period: int, dev: float):
    """iBands: SMA middle, population stdev (MT5 uses ddof=0)."""
    s = pd.Series(np.asarray(close, dtype=float))
    mid = s.rolling(period).mean()
    sd = s.rolling(period).std(ddof=0)
    return (mid + dev * sd).to_numpy(), mid.to_numpy(), (mid - dev * sd).to_numpy()


def rsi(close, period: int) -> np.ndarray:
    """iRSI: Wilder-smoothed average gain / loss."""
    c = np.asarray(close, dtype=float)
    d = np.diff(c, prepend=c[0])
    gain = R.wilder_smooth(np.where(d > 0, d, 0.0), period)
    loss = R.wilder_smooth(np.where(d < 0, -d, 0.0), period)
    with np.errstate(divide="ignore", invalid="ignore"):
        rs = np.where(loss > 0, gain / loss, np.inf)
        out = 100.0 - 100.0 / (1.0 + rs)
    return np.where(np.isfinite(out), out, 100.0)


def stochastic(high, low, close, k_period: int, d_period: int, slowing: int):
    """iStochastic(..., MODE_SMA, STO_LOWHIGH). Returns (%K slowed, %D)."""
    h = pd.Series(np.asarray(high, dtype=float))
    l = pd.Series(np.asarray(low, dtype=float))
    c = pd.Series(np.asarray(close, dtype=float))
    hh = h.rolling(k_period).max()
    ll = l.rolling(k_period).min()
    rng = (hh - ll)
    raw_num = (c - ll).rolling(slowing).sum()
    raw_den = rng.rolling(slowing).sum()
    k = 100.0 * (raw_num / raw_den.replace(0.0, np.nan))
    d = k.rolling(d_period).mean()
    return k.to_numpy(), d.to_numpy()


def donchian(high, low, bars: int):
    """Channel over the `bars` bars BEFORE each bar (iHighest/iLowest start=1)."""
    h = pd.Series(np.asarray(high, dtype=float)).shift(1).rolling(bars).max()
    l = pd.Series(np.asarray(low, dtype=float)).shift(1).rolling(bars).min()
    return h.to_numpy(), l.to_numpy()


# ---------------------------------------------------------------------------
class StrategyBase:
    """Mirrors CStrategyBase: the Filter/Entry/Exit/TrailStop contract."""

    id = "base"
    mql = ""
    #: searchable parameters -> candidate values
    GRID: dict = {}
    DEFAULTS: dict = {}

    def __init__(self, params: dict | None = None):
        self.p = dict(self.DEFAULTS)
        if params:
            self.p.update(params)

    # regimes this strategy is allowed to act in (mirrors Filter())
    HOME_REGIMES: tuple = ()

    def filter_mask(self, regime: np.ndarray) -> np.ndarray:
        if not self.HOME_REGIMES:
            return np.ones(len(regime), dtype=bool)
        return np.isin(regime, self.HOME_REGIMES)

    def build(self, df: pd.DataFrame, feats: pd.DataFrame, regime: np.ndarray) -> dict:
        raise NotImplementedError

    @staticmethod
    def _blank(n: int) -> dict:
        return {
            "entry_dir": np.zeros(n, dtype=int),
            "entry_stop": np.full(n, np.nan),
            "entry_tp": np.full(n, np.nan),
            "exit_long": np.zeros(n, dtype=bool),
            "exit_short": np.zeros(n, dtype=bool),
            "exit_fraction_long": np.ones(n),
            "exit_fraction_short": np.ones(n),
            "trail_long": np.full(n, np.nan),
            "trail_short": np.full(n, np.nan),
            "trail_gate": np.full(n, np.nan),
            # mirrors the stop floor applied centrally in CStrategyBase::TryEnter
            # and re-checked in CRiskManager::Approve
            "min_stop": np.full(n, np.nan),
        }


# ---------------------------------------------------------------------------
class TrendFollowEma(StrategyBase):
    """Mirrors Strategies/TrendFollowEma.mqh - EMA cross gated by ADX."""

    id = "trend_ema"
    mql = "TrendFollowEma.mqh"
    HOME_REGIMES = (R.TREND_UP, R.TREND_DOWN)
    DEFAULTS = {"ema_fast": 21, "ema_slow": 55, "adx_min": 25.0,
                "atr_stop_mult": 2.0, "trail_atr_mult": 2.5, "min_rr": 1.5}
    GRID = {
        "ema_fast": [8, 13, 21, 34],
        "ema_slow": [34, 55, 89, 144],
        "adx_min": [18.0, 22.0, 25.0, 30.0],
        "atr_stop_mult": [1.0, 1.5, 2.0, 2.5, 3.0],
        "trail_atr_mult": [1.5, 2.0, 2.5, 3.0],
        "min_rr": [1.0, 1.5, 2.0, 3.0],
    }

    def build(self, df, feats, regime):
        n = len(df)
        o = self._blank(n)
        p = self.p
        if p["ema_fast"] >= p["ema_slow"]:
            return o  # degenerate: no signals

        c = df["close"].to_numpy(float)
        fast, slow = ema(c, int(p["ema_fast"])), ema(c, int(p["ema_slow"]))
        atr = feats["atr"].to_numpy(float)
        adx = feats["adx"].to_numpy(float)

        pf, ps = np.roll(fast, 1), np.roll(slow, 1)
        cross_up = (pf <= ps) & (fast > slow)
        cross_dn = (pf >= ps) & (fast < slow)

        ok = self.filter_mask(regime) & (adx >= p["adx_min"]) & np.isfinite(atr) & (atr > 0)

        long_sig = ok & cross_up & (regime == R.TREND_UP)
        short_sig = ok & cross_dn & (regime == R.TREND_DOWN)

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        stop_long = slow - p["atr_stop_mult"] * atr
        stop_short = slow + p["atr_stop_mult"] * atr
        o["entry_stop"] = np.where(long_sig, stop_long, np.where(short_sig, stop_short, np.nan))
        o["entry_tp"] = np.where(
            long_sig, c + p["min_rr"] * (c - stop_long),
            np.where(short_sig, c - p["min_rr"] * (stop_short - c), np.nan))

        # Exit(): cross back through the slow EMA, or the regime left trend.
        # A cross against closes fully; a regime exit only scales out half,
        # matching the .mqh, which checks the cross FIRST and falls through.
        left_trend = ~np.isin(regime, (R.TREND_UP, R.TREND_DOWN))
        cross_against_long = fast < slow
        cross_against_short = fast > slow
        o["exit_long"] = cross_against_long | left_trend
        o["exit_short"] = cross_against_short | left_trend
        o["exit_fraction_long"] = np.where(cross_against_long, 1.0, 0.5)
        o["exit_fraction_short"] = np.where(cross_against_short, 1.0, 0.5)

        o["trail_long"] = c - p["trail_atr_mult"] * atr
        o["trail_short"] = c + p["trail_atr_mult"] * atr
        o["trail_gate"] = atr          # 1 ATR in profit before trailing starts
        o["min_stop"] = MIN_STOP_ATR * atr
        return o


# ---------------------------------------------------------------------------
class MeanReversionBB(StrategyBase):
    """Mirrors Strategies/MeanReversionBB.mqh - fade the band, exit at the mean."""

    id = "mean_rev_bb"
    mql = "MeanReversionBB.mqh"
    HOME_REGIMES = (R.RANGE,)
    DEFAULTS = {"bb_period": 20, "bb_deviation": 2.0, "rsi_period": 14,
                "rsi_oversold": 30.0, "rsi_overbought": 70.0, "stop_atr_mult": 1.0}
    GRID = {
        "bb_period": [14, 20, 30, 40],
        "bb_deviation": [1.5, 2.0, 2.5, 3.0],
        "rsi_period": [7, 14, 21],
        "rsi_oversold": [20.0, 25.0, 30.0, 35.0],
        "rsi_overbought": [65.0, 70.0, 75.0, 80.0],
        "stop_atr_mult": [0.5, 1.0, 1.5, 2.0],
    }

    def build(self, df, feats, regime):
        n = len(df)
        o = self._blank(n)
        p = self.p
        if p["rsi_oversold"] >= p["rsi_overbought"]:
            return o

        c = df["close"].to_numpy(float)
        up, mid, lo = bollinger(c, int(p["bb_period"]), p["bb_deviation"])
        r = rsi(c, int(p["rsi_period"]))
        atr = feats["atr"].to_numpy(float)

        ok = self.filter_mask(regime) & np.isfinite(atr) & (atr > 0) & np.isfinite(mid)
        long_sig = ok & (c <= lo) & (r <= p["rsi_oversold"])
        short_sig = ok & (c >= up) & (r >= p["rsi_overbought"])

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        o["entry_stop"] = np.where(long_sig, lo - p["stop_atr_mult"] * atr,
                                   np.where(short_sig, up + p["stop_atr_mult"] * atr, np.nan))
        o["entry_tp"] = np.where(long_sig | short_sig, mid, np.nan)

        left_range = regime != R.RANGE
        o["exit_long"] = left_range | (c >= mid)
        o["exit_short"] = left_range | (c <= mid)

        # break-even only; trailing a fade just donates to the noise
        o["trail_long"] = np.full(n, np.nan)
        o["trail_short"] = np.full(n, np.nan)
        o["trail_gate"] = atr
        o["min_stop"] = MIN_STOP_ATR * atr
        o["_breakeven_only"] = True
        return o


# ---------------------------------------------------------------------------
class BreakoutDonchian(StrategyBase):
    """Mirrors Strategies/BreakoutDonchian.mqh - break of an N-bar range."""

    id = "breakout_dc"
    mql = "BreakoutDonchian.mqh"
    HOME_REGIMES = (R.BREAKOUT, R.RANGE)
    DEFAULTS = {"channel_bars": 20, "atr_stop_mult": 1.5,
                "trail_atr_mult": 2.0, "min_atr_percentile": 0.60}
    GRID = {
        "channel_bars": [10, 15, 20, 30, 40, 55],
        "atr_stop_mult": [1.0, 1.5, 2.0, 2.5],
        "trail_atr_mult": [1.0, 1.5, 2.0, 3.0],
        "min_atr_percentile": [0.40, 0.50, 0.60, 0.70, 0.80],
    }

    def build(self, df, feats, regime):
        n = len(df)
        o = self._blank(n)
        p = self.p
        c = df["close"].to_numpy(float)
        hi, lo = donchian(df["high"], df["low"], int(p["channel_bars"]))
        mid = (hi + lo) / 2.0
        atr = feats["atr"].to_numpy(float)
        pct = feats["atr_percentile"].to_numpy(float)

        ok = (self.filter_mask(regime) & (regime != R.CHOP_HIVOL)
              & (pct >= p["min_atr_percentile"])
              & np.isfinite(atr) & (atr > 0) & np.isfinite(hi) & np.isfinite(lo))

        long_sig = ok & (c > hi)
        short_sig = ok & (c < lo)

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        # nearer of the ATR stop and the channel midpoint
        o["entry_stop"] = np.where(long_sig, np.maximum(c - p["atr_stop_mult"] * atr, mid),
                                   np.where(short_sig, np.minimum(c + p["atr_stop_mult"] * atr, mid),
                                            np.nan))
        o["entry_tp"] = np.full(n, np.nan)      # let the trail run

        o["exit_long"] = c < mid                # break closed back inside: failed
        o["exit_short"] = c > mid

        o["trail_long"] = c - p["trail_atr_mult"] * atr
        o["trail_short"] = c + p["trail_atr_mult"] * atr
        o["trail_gate"] = 0.5 * atr             # breakouts run or fail fast
        o["min_stop"] = MIN_STOP_ATR * atr
        return o


# ---------------------------------------------------------------------------
class MomentumPullback(StrategyBase):
    """Mirrors Strategies/MomentumPullback.mqh - buy the dip inside a trend."""

    id = "momo_pullback"
    mql = "MomentumPullback.mqh"
    HOME_REGIMES = (R.TREND_UP, R.TREND_DOWN)
    DEFAULTS = {"ema_period": 50, "stoch_k": 14, "stoch_d": 3, "stoch_slowing": 3,
                "stoch_oversold": 25.0, "stoch_overbought": 75.0,
                "pullback_atr": 0.75, "stop_atr_mult": 1.5, "trail_atr_mult": 2.0}
    # Grid widened after the null test: with the shipped defaults this
    # strategy fired ONCE in 40,000 bars. The funnel showed why - requiring
    # price to pull back within 0.75 ATR of a 50-EMA *and* the stochastic to
    # already be at an extreme cuts 3883 candidate bars to 2. A slow EMA lags
    # too far behind in a trend for price to reach it that often. The search
    # needs faster EMAs and wider pullback bands to have anything to find.
    GRID = {
        "ema_period": [13, 21, 34, 50, 89],
        "stoch_k": [5, 9, 14, 21],
        "stoch_oversold": [15.0, 20.0, 25.0, 30.0, 40.0],
        "stoch_overbought": [60.0, 70.0, 75.0, 80.0, 85.0],
        "pullback_atr": [0.5, 1.0, 1.5, 2.0, 3.0],
        "stop_atr_mult": [1.0, 1.5, 2.0, 2.5],
        "trail_atr_mult": [1.5, 2.0, 2.5, 3.0],
    }

    def build(self, df, feats, regime, aligned=None):
        n = len(df)
        o = self._blank(n)
        p = self.p
        if p["stoch_oversold"] >= p["stoch_overbought"]:
            return o

        c = df["close"].to_numpy(float)
        h = df["high"].to_numpy(float)
        l = df["low"].to_numpy(float)
        e = ema(c, int(p["ema_period"]))
        k, _d = stochastic(h, l, c, int(p["stoch_k"]), int(p["stoch_d"]), int(p["stoch_slowing"]))
        atr = feats["atr"].to_numpy(float)
        pk = np.roll(k, 1)

        ok = self.filter_mask(regime) & np.isfinite(atr) & (atr > 0) & np.isfinite(e) & np.isfinite(k)
        if aligned is not None:
            ok = ok & aligned      # Filter() demands multi-timeframe agreement

        long_sig = (ok & (regime == R.TREND_UP) & (l <= e + p["pullback_atr"] * atr)
                    & (pk <= p["stoch_oversold"]) & (k > pk) & (c > e))
        short_sig = (ok & (regime == R.TREND_DOWN) & (h >= e - p["pullback_atr"] * atr)
                     & (pk >= p["stoch_overbought"]) & (k < pk) & (c < e))

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        o["entry_stop"] = np.where(
            long_sig, np.minimum(l, e) - p["stop_atr_mult"] * atr,
            np.where(short_sig, np.maximum(h, e) + p["stop_atr_mult"] * atr, np.nan))
        o["entry_tp"] = np.full(n, np.nan)

        o["exit_long"] = c < e
        o["exit_short"] = c > e

        o["trail_long"] = c - p["trail_atr_mult"] * atr
        o["trail_short"] = c + p["trail_atr_mult"] * atr
        o["trail_gate"] = atr
        o["min_stop"] = MIN_STOP_ATR * atr
        return o


# ---------------------------------------------------------------------------
class RangeFadeRsi(StrategyBase):
    """Mirrors Strategies/RangeFadeRsi.mqh - fast RSI fade with a hard time stop."""

    id = "range_fade"
    mql = "RangeFadeRsi.mqh"
    HOME_REGIMES = (R.RANGE, R.CHOP_HIVOL)
    DEFAULTS = {"rsi_period": 2, "rsi_low": 10.0, "rsi_high": 90.0,
                "stop_atr_mult": 2.0, "target_atr_mult": 1.0, "max_hold_bars": 8}
    GRID = {
        "rsi_period": [2, 3, 5],
        "rsi_low": [5.0, 10.0, 15.0, 20.0],
        "rsi_high": [80.0, 85.0, 90.0, 95.0],
        "stop_atr_mult": [1.5, 2.0, 2.5, 3.0],
        "target_atr_mult": [0.5, 1.0, 1.5, 2.0],
        "max_hold_bars": [4, 6, 8, 12, 16],
    }

    def build(self, df, feats, regime, h4_trending=None):
        n = len(df)
        o = self._blank(n)
        p = self.p
        if p["rsi_low"] >= p["rsi_high"]:
            return o

        c = df["close"].to_numpy(float)
        r = rsi(c, int(p["rsi_period"]))
        atr = feats["atr"].to_numpy(float)

        ok = self.filter_mask(regime) & np.isfinite(atr) & (atr > 0)
        if h4_trending is not None:
            ok = ok & ~h4_trending      # never fade into a higher-timeframe trend

        # the nasty regime gets a wider stop
        stop_mult = np.where(regime == R.CHOP_HIVOL, p["stop_atr_mult"] * 1.5, p["stop_atr_mult"])

        long_sig = ok & (r <= p["rsi_low"])
        short_sig = ok & (r >= p["rsi_high"])

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        o["entry_stop"] = np.where(long_sig, c - stop_mult * atr,
                                   np.where(short_sig, c + stop_mult * atr, np.nan))
        o["entry_tp"] = np.where(long_sig, c + p["target_atr_mult"] * atr,
                                 np.where(short_sig, c - p["target_atr_mult"] * atr, np.nan))

        o["exit_long"] = r >= 50.0
        o["exit_short"] = r <= 50.0
        o["min_stop"] = MIN_STOP_ATR * atr
        o["_max_hold_bars"] = int(p["max_hold_bars"])   # hard time stop
        return o


ALL_STRATEGIES = [TrendFollowEma, MeanReversionBB, BreakoutDonchian,
                  MomentumPullback, RangeFadeRsi]
BY_ID = {c.id: c for c in ALL_STRATEGIES}

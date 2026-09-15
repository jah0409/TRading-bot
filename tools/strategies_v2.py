#!/usr/bin/env python3
"""
strategies_v2.py - ten strategies over the causal feature set.

Every strategy declares, explicitly:

    entry / invalidation / stop / target / exit / trail
    allowed regimes, allowed sessions, max concurrent, risk tier, version

and produces the same array contract the backtester consumes. A strategy never
sizes a position and never sends an order - it returns a price and a stop, and
the risk manager decides everything else. That invariant is what makes it
impossible for a strategy bug to overspend the account.

All entries are decided on the CLOSE of bar i and filled at the open of i+1.
Every feature they read is causal by construction (see feature_engine).
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

import regime_v2 as R2

#: mirrors risk.min_stop_atr_mult - a stop closer than this is noise, and the
#: live risk manager rejects it outright
MIN_STOP_ATR = 0.5

#: XAUUSD pip size in USD. Brokers quote gold to 2 decimals, so 1 point =
#: 0.01. The two conventions in common use are 1 pip = 0.10 (10 points) and
#: 1 pip = 1.00 (100 points). We use the CONSERVATIVE one - 1 pip = 1.00 USD -
#: so "at least 8-10 pips" is a real 8-10 dollar move, not 80 cents.
PIP_USD = 1.00

#: minimum move a winning trade must be able to make, in pips
MIN_TARGET_PIPS = 10.0


def min_target_usd() -> float:
    return MIN_TARGET_PIPS * PIP_USD

ALL_SESSIONS = ("ASIAN", "LONDON", "NEWYORK", "OVERLAP", "DEAD")
ACTIVE_SESSIONS = ("LONDON", "NEWYORK", "OVERLAP")


@dataclass
class Spec:
    id: str
    version: str
    timeframe: str
    regimes: tuple
    sessions: tuple
    description: str
    max_concurrent: int = 1
    grid: dict = field(default_factory=dict)
    params: dict = field(default_factory=dict)


def blank(n: int) -> dict:
    return {
        "entry_dir": np.zeros(n, int),
        "entry_stop": np.full(n, np.nan),
        "entry_tp": np.full(n, np.nan),
        "exit_long": np.zeros(n, bool),
        "exit_short": np.zeros(n, bool),
        "exit_fraction_long": np.ones(n),
        "exit_fraction_short": np.ones(n),
        "trail_long": np.full(n, np.nan),
        "trail_short": np.full(n, np.nan),
        "trail_gate": np.full(n, np.nan),
        "min_stop": np.full(n, np.nan),
    }


def gate(f: pd.DataFrame, regime: pd.Series, spec: Spec) -> np.ndarray:
    """Regime + session + data-sanity mask shared by every strategy."""
    ok = np.isin(regime.to_numpy(), spec.regimes)
    if "session" in f.columns:
        ok &= np.isin(f["session"].to_numpy(), spec.sessions)
    a = f["atr"].to_numpy(float)
    ok &= np.isfinite(a) & (a > 0)
    # ABNORMAL is never tradable, whatever a strategy declares
    ok &= (regime.to_numpy() != R2.ABNORMAL)
    return ok


class Strategy:
    spec: Spec

    def __init__(self, params: dict | None = None):
        self.p = dict(self.spec.params)
        if params:
            self.p.update(params)

    def build(self, df, f, regime, htf=None) -> dict:
        raise NotImplementedError

    def _finish(self, o, f, long_sig, short_sig, stop_l, stop_s,
                tp_l=None, tp_s=None, trail_mult=None, trail_gate_mult=1.0,
                exit_l=None, exit_s=None):
        a = f["atr"].to_numpy(float)
        px = f["close"].to_numpy(float)

        # --- MINIMUM TARGET GATE -------------------------------------------
        # A winning trade must be able to make at least MIN_TARGET_PIPS.
        #
        # Where the strategy sets an explicit target, that distance must clear
        # the minimum. Where it trails instead, 1R is the natural unit of a
        # winner, so the STOP distance must clear it - a trade whose whole 1R
        # is under the minimum cannot produce a qualifying winner however far
        # it runs before the trail catches it.
        #
        # Signals that cannot reach the minimum are DROPPED, not stretched.
        # Pushing a target out to a level the market was never going to reach
        # just converts winners into losers.
        need = min_target_usd()
        if tp_l is not None:
            reach_l = np.abs(np.asarray(tp_l, float) - px)
        else:
            reach_l = np.abs(px - np.asarray(stop_l, float))
        if tp_s is not None:
            reach_s = np.abs(px - np.asarray(tp_s, float))
        else:
            reach_s = np.abs(np.asarray(stop_s, float) - px)

        long_sig = np.asarray(long_sig) & np.isfinite(reach_l) & (reach_l >= need)
        short_sig = np.asarray(short_sig) & np.isfinite(reach_s) & (reach_s >= need)

        o["entry_dir"] = np.where(long_sig, 1, np.where(short_sig, -1, 0))
        o["entry_stop"] = np.where(long_sig, stop_l, np.where(short_sig, stop_s, np.nan))
        if tp_l is not None or tp_s is not None:
            o["entry_tp"] = np.where(long_sig, tp_l if tp_l is not None else np.nan,
                                     np.where(short_sig, tp_s if tp_s is not None else np.nan,
                                              np.nan))
        if exit_l is not None:
            o["exit_long"] = exit_l
        if exit_s is not None:
            o["exit_short"] = exit_s
        if trail_mult is not None:
            px = f["close"].to_numpy(float) if "close" in f.columns else None
            o["trail_long"] = px - trail_mult * a if px is not None else np.nan
            o["trail_short"] = px + trail_mult * a if px is not None else np.nan
            o["trail_gate"] = trail_gate_mult * a
        o["min_stop"] = MIN_STOP_ATR * a
        return o


# ---------------------------------------------------------------------------
class TrendContinuation(Strategy):
    """Ride an established trend; add on a BOS in the trend direction."""
    spec = Spec(
        id="trend_continuation", version="2.0.0", timeframe="M15",
        regimes=(R2.TRENDING_BULL, R2.TRENDING_BEAR), sessions=ACTIVE_SESSIONS,
        description="BOS in the direction of an established trend, stop beyond the last swing",
        params={"stop_atr": 1.5, "trail_atr": 2.0, "rr": 2.0, "min_adx": 22.0},
        grid={"stop_atr": [1.0, 1.5, 2.0, 2.5], "trail_atr": [1.5, 2.0, 2.5, 3.0],
              "rr": [1.5, 2.0, 3.0], "min_adx": [18.0, 22.0, 26.0, 30.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec) & (f["adx"].to_numpy() >= p["min_adx"])
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        sl = f["swing_low"].to_numpy(float); sh = f["swing_high"].to_numpy(float)

        L = ok & (regime.to_numpy() == R2.TRENDING_BULL) & f["bos_up"].to_numpy()
        S = ok & (regime.to_numpy() == R2.TRENDING_BEAR) & f["bos_down"].to_numpy()
        stop_l = np.where(np.isfinite(sl), np.minimum(sl, c - p["stop_atr"] * a),
                          c - p["stop_atr"] * a)
        stop_s = np.where(np.isfinite(sh), np.maximum(sh, c + p["stop_atr"] * a),
                          c + p["stop_atr"] * a)
        o = self._finish(o, f, L, S, stop_l, stop_s,
                         tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                         trail_mult=p["trail_atr"], trail_gate_mult=1.0,
                         exit_l=f["choch_down"].to_numpy(), exit_s=f["choch_up"].to_numpy())
        return o


class TrendPullback(Strategy):
    """Buy the dip to the 50 EMA inside a trend, once momentum turns back."""
    spec = Spec(
        id="trend_pullback", version="2.0.0", timeframe="M15",
        regimes=(R2.TRENDING_BULL, R2.TRENDING_BEAR), sessions=ACTIVE_SESSIONS,
        description="Pullback into the EMA50 with a rejection candle, trend intact",
        params={"pullback_atr": 1.0, "stop_atr": 1.5, "trail_atr": 2.0, "rr": 2.0},
        grid={"pullback_atr": [0.5, 1.0, 1.5, 2.0], "stop_atr": [1.0, 1.5, 2.0, 2.5],
              "trail_atr": [1.5, 2.0, 2.5, 3.0], "rr": [1.5, 2.0, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        lo = f["low"].to_numpy(float) if "low" in f else df["low"].to_numpy(float)
        hi = f["high"].to_numpy(float) if "high" in f else df["high"].to_numpy(float)
        e = f["ema50"].to_numpy(float)
        d = f["dist_ema50_atr"].to_numpy(float)

        L = (ok & (regime.to_numpy() == R2.TRENDING_BULL) & (np.abs(d) <= p["pullback_atr"])
             & (f["rejection_bull"].to_numpy() | f["engulf_bull"].to_numpy()) & (c > e))
        S = (ok & (regime.to_numpy() == R2.TRENDING_BEAR) & (np.abs(d) <= p["pullback_atr"])
             & (f["rejection_bear"].to_numpy() | f["engulf_bear"].to_numpy()) & (c < e))
        stop_l = np.minimum(lo, e) - p["stop_atr"] * a
        stop_s = np.maximum(hi, e) + p["stop_atr"] * a
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"],
                            exit_l=(c < e) & f["choch_down"].to_numpy(),
                            exit_s=(c > e) & f["choch_up"].to_numpy())


class BreakoutRetest(Strategy):
    """Break of structure, then a retest that holds. Fewer, better entries."""
    spec = Spec(
        id="breakout_retest", version="2.0.0", timeframe="M15",
        regimes=(R2.BREAKOUT, R2.TRENDING_BULL, R2.TRENDING_BEAR, R2.RANGING),
        sessions=ACTIVE_SESSIONS,
        description="BOS then price returns to the broken level and rejects it",
        params={"retest_bars": 6, "stop_atr": 1.2, "trail_atr": 2.0, "rr": 2.5},
        grid={"retest_bars": [3, 6, 10, 15], "stop_atr": [0.8, 1.2, 1.6, 2.0],
              "trail_atr": [1.5, 2.0, 3.0], "rr": [2.0, 2.5, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        k = int(p["retest_bars"])
        broke_up = pd.Series(f["bos_up"].to_numpy()).rolling(k, min_periods=1).max().to_numpy().astype(bool)
        broke_dn = pd.Series(f["bos_down"].to_numpy()).rolling(k, min_periods=1).max().to_numpy().astype(bool)
        lvl_up = pd.Series(np.where(f["bos_up"].to_numpy(), f["swing_high"].to_numpy(), np.nan)).ffill().to_numpy()
        lvl_dn = pd.Series(np.where(f["bos_down"].to_numpy(), f["swing_low"].to_numpy(), np.nan)).ffill().to_numpy()

        near_up = np.isfinite(lvl_up) & (np.abs(c - lvl_up) < 0.5 * a)
        near_dn = np.isfinite(lvl_dn) & (np.abs(c - lvl_dn) < 0.5 * a)
        L = ok & broke_up & near_up & (f["rejection_bull"].to_numpy() | f["engulf_bull"].to_numpy())
        S = ok & broke_dn & near_dn & (f["rejection_bear"].to_numpy() | f["engulf_bear"].to_numpy())
        stop_l = c - p["stop_atr"] * a
        stop_s = c + p["stop_atr"] * a
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"],
                            exit_l=f["choch_down"].to_numpy(), exit_s=f["choch_up"].to_numpy())


class VolatilityExpansion(Strategy):
    """Trade the impulse when volatility breaks out of contraction."""
    spec = Spec(
        id="vol_expansion", version="2.0.0", timeframe="M15",
        regimes=(R2.BREAKOUT, R2.LOW_VOLATILITY, R2.RANGING), sessions=ACTIVE_SESSIONS,
        description="Displacement candle out of a contracted range",
        params={"stop_atr": 1.5, "trail_atr": 2.0, "min_expansion": 1.3},
        grid={"stop_atr": [1.0, 1.5, 2.0], "trail_atr": [1.5, 2.0, 2.5, 3.0],
              "min_expansion": [1.15, 1.3, 1.5, 1.8]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        prior_quiet = pd.Series(f["consolidation"].to_numpy()).shift(1).rolling(
            5, min_periods=1).max().to_numpy().astype(bool)
        exp_ok = f["atr_expansion"].to_numpy() >= p["min_expansion"]
        L = ok & prior_quiet & exp_ok & f["impulse_up"].to_numpy()
        S = ok & prior_quiet & exp_ok & f["impulse_down"].to_numpy()
        return self._finish(o, f, L, S, c - p["stop_atr"] * a, c + p["stop_atr"] * a,
                            trail_mult=p["trail_atr"], trail_gate_mult=0.5)


class MeanReversion(Strategy):
    """Fade a stretched move back toward the mean, in a range only."""
    spec = Spec(
        id="mean_reversion", version="2.0.0", timeframe="M15",
        regimes=(R2.RANGING, R2.LOW_VOLATILITY), sessions=ALL_SESSIONS,
        description="RSI extreme far from EMA50 in a range; target the mean",
        params={"rsi_lo": 25.0, "rsi_hi": 75.0, "min_dist_atr": 1.5, "stop_atr": 1.5},
        grid={"rsi_lo": [15.0, 20.0, 25.0, 30.0], "rsi_hi": [70.0, 75.0, 80.0, 85.0],
              "min_dist_atr": [1.0, 1.5, 2.0, 2.5], "stop_atr": [1.0, 1.5, 2.0, 2.5]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        e = f["ema50"].to_numpy(float); r = f["rsi14"].to_numpy(float)
        d = f["dist_ema50_atr"].to_numpy(float)
        L = ok & (r <= p["rsi_lo"]) & (d <= -p["min_dist_atr"])
        S = ok & (r >= p["rsi_hi"]) & (d >= p["min_dist_atr"])
        return self._finish(o, f, L, S, c - p["stop_atr"] * a, c + p["stop_atr"] * a,
                            tp_l=e, tp_s=e,
                            exit_l=(regime.to_numpy() != R2.RANGING) | (c >= e),
                            exit_s=(regime.to_numpy() != R2.RANGING) | (c <= e))


class LiquiditySweepReversal(Strategy):
    """The stop raid. Price takes out a level, fails, and reverses."""
    spec = Spec(
        id="liquidity_sweep", version="2.0.0", timeframe="M15",
        regimes=(R2.RANGING, R2.TRANSITION, R2.HIGH_VOLATILITY,
                 R2.TRENDING_BULL, R2.TRENDING_BEAR), sessions=ACTIVE_SESSIONS,
        description="Sweep of PDH/PDL or a swing, closing back inside, then reversal",
        params={"stop_atr": 1.0, "trail_atr": 2.0, "rr": 2.5, "confirm_reject": 1},
        grid={"stop_atr": [0.5, 1.0, 1.5, 2.0], "trail_atr": [1.5, 2.0, 3.0],
              "rr": [1.5, 2.0, 2.5, 3.0], "confirm_reject": [0, 1]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        hi = df["high"].to_numpy(float); lo = df["low"].to_numpy(float)

        swept_hi = f["sweep_pdh"].to_numpy() | f["sweep_swing_high"].to_numpy()
        swept_lo = f["sweep_pdl"].to_numpy() | f["sweep_swing_low"].to_numpy()
        if p["confirm_reject"]:
            swept_hi = swept_hi & f["rejection_bear"].to_numpy()
            swept_lo = swept_lo & f["rejection_bull"].to_numpy()

        # sweep high -> short; sweep low -> long. Stop beyond the raid wick.
        S = ok & swept_hi
        L = ok & swept_lo
        stop_s = hi + p["stop_atr"] * a
        stop_l = lo - p["stop_atr"] * a
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"])


class BosChochContinuation(Strategy):
    """Trade the structural turn: CHoCH then continuation in the new direction."""
    spec = Spec(
        id="bos_choch", version="2.0.0", timeframe="M15",
        regimes=(R2.TRANSITION, R2.TRENDING_BULL, R2.TRENDING_BEAR), sessions=ACTIVE_SESSIONS,
        description="CHoCH flips structure; enter the first BOS confirming the new side",
        params={"window": 12, "stop_atr": 1.5, "trail_atr": 2.0, "rr": 2.0},
        grid={"window": [6, 12, 20, 30], "stop_atr": [1.0, 1.5, 2.0, 2.5],
              "trail_atr": [1.5, 2.0, 3.0], "rr": [1.5, 2.0, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        w = int(p["window"])
        ch_up = pd.Series(f["choch_up"].to_numpy()).rolling(w, min_periods=1).max().to_numpy().astype(bool)
        ch_dn = pd.Series(f["choch_down"].to_numpy()).rolling(w, min_periods=1).max().to_numpy().astype(bool)
        L = ok & ch_up & f["bos_up"].to_numpy()
        S = ok & ch_dn & f["bos_down"].to_numpy()
        sl = f["swing_low"].to_numpy(float); sh = f["swing_high"].to_numpy(float)
        stop_l = np.where(np.isfinite(sl), np.minimum(sl, c - p["stop_atr"] * a), c - p["stop_atr"] * a)
        stop_s = np.where(np.isfinite(sh), np.maximum(sh, c + p["stop_atr"] * a), c + p["stop_atr"] * a)
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"])


class FvgRetracement(Strategy):
    """Enter on a retrace into a fresh fair value gap, in the trend direction."""
    spec = Spec(
        id="fvg_retrace", version="2.0.0", timeframe="M15",
        regimes=(R2.TRENDING_BULL, R2.TRENDING_BEAR, R2.BREAKOUT), sessions=ACTIVE_SESSIONS,
        description="Price returns into an unfilled FVG aligned with the trend",
        params={"max_age": 10, "stop_atr": 1.0, "trail_atr": 2.0, "rr": 2.5},
        grid={"max_age": [5, 10, 20, 30], "stop_atr": [0.5, 1.0, 1.5, 2.0],
              "trail_atr": [1.5, 2.0, 3.0], "rr": [2.0, 2.5, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        lo = df["low"].to_numpy(float); hi = df["high"].to_numpy(float)
        age = int(p["max_age"])

        # the most recent FVG zone, carried forward for `age` bars
        up_top = pd.Series(np.where(f["fvg_up"].to_numpy(), f["fvg_top"].to_numpy(), np.nan)).ffill(limit=age).to_numpy()
        up_bot = pd.Series(np.where(f["fvg_up"].to_numpy(), f["fvg_bottom"].to_numpy(), np.nan)).ffill(limit=age).to_numpy()
        dn_top = pd.Series(np.where(f["fvg_down"].to_numpy(), f["fvg_top"].to_numpy(), np.nan)).ffill(limit=age).to_numpy()
        dn_bot = pd.Series(np.where(f["fvg_down"].to_numpy(), f["fvg_bottom"].to_numpy(), np.nan)).ffill(limit=age).to_numpy()

        touch_up = np.isfinite(up_bot) & (lo <= up_top) & (c > up_bot)
        touch_dn = np.isfinite(dn_top) & (hi >= dn_bot) & (c < dn_top)
        L = ok & (regime.to_numpy() == R2.TRENDING_BULL) & touch_up & ~f["fvg_up"].to_numpy()
        S = ok & (regime.to_numpy() == R2.TRENDING_BEAR) & touch_dn & ~f["fvg_down"].to_numpy()
        stop_l = np.where(np.isfinite(up_bot), up_bot - p["stop_atr"] * a, c - p["stop_atr"] * a)
        stop_s = np.where(np.isfinite(dn_top), dn_top + p["stop_atr"] * a, c + p["stop_atr"] * a)
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"])


class SessionBreakout(Strategy):
    """Break of the Asian range in the first hours of London."""
    spec = Spec(
        id="session_breakout", version="2.0.0", timeframe="M15",
        regimes=(R2.BREAKOUT, R2.TRENDING_BULL, R2.TRENDING_BEAR, R2.RANGING, R2.TRANSITION),
        sessions=("LONDON", "OVERLAP"),
        description="London breaks the Asian session range with displacement",
        params={"max_bars_into_london": 12, "stop_atr": 1.5, "trail_atr": 2.0, "rr": 2.0},
        grid={"max_bars_into_london": [4, 8, 12, 20], "stop_atr": [1.0, 1.5, 2.0],
              "trail_atr": [1.5, 2.0, 3.0], "rr": [1.5, 2.0, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        idx = f.index
        asian = f["sess_asian"].to_numpy()
        day = idx.normalize()
        hi = pd.Series(np.where(asian, df["high"].to_numpy(float), np.nan), index=idx)
        lo = pd.Series(np.where(asian, df["low"].to_numpy(float), np.nan), index=idx)
        a_hi = hi.groupby(day).cummax().groupby(day).ffill().to_numpy()
        a_lo = lo.groupby(day).cummin().groupby(day).ffill().to_numpy()

        early = f["bars_since_london_open"].to_numpy()
        window = np.isfinite(early) & (early <= p["max_bars_into_london"])
        L = ok & window & np.isfinite(a_hi) & (c > a_hi) & f["impulse_up"].to_numpy()
        S = ok & window & np.isfinite(a_lo) & (c < a_lo) & f["impulse_down"].to_numpy()
        stop_l = np.where(np.isfinite(a_lo), np.maximum(a_lo, c - p["stop_atr"] * a), c - p["stop_atr"] * a)
        stop_s = np.where(np.isfinite(a_hi), np.minimum(a_hi, c + p["stop_atr"] * a), c + p["stop_atr"] * a)
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"])


class PdhPdlReaction(Strategy):
    """React at the previous day's high/low - the most watched levels on gold."""
    spec = Spec(
        id="pdh_pdl_reaction", version="2.0.0", timeframe="M15",
        regimes=(R2.RANGING, R2.TRANSITION, R2.TRENDING_BULL, R2.TRENDING_BEAR),
        sessions=ACTIVE_SESSIONS,
        description="Rejection at PDH/PDL without a clean break",
        params={"touch_atr": 0.3, "stop_atr": 1.0, "trail_atr": 2.0, "rr": 2.0},
        grid={"touch_atr": [0.15, 0.3, 0.5, 0.8], "stop_atr": [0.5, 1.0, 1.5, 2.0],
              "trail_atr": [1.5, 2.0, 3.0], "rr": [1.5, 2.0, 2.5, 3.0]})

    def build(self, df, f, regime, htf=None):
        n = len(f); o = blank(n); p = self.p
        ok = gate(f, regime, self.spec)
        c = f["close"].to_numpy(float); a = f["atr"].to_numpy(float)
        hi = df["high"].to_numpy(float); lo = df["low"].to_numpy(float)
        pdh = f["pdh"].to_numpy(float); pdl = f["pdl"].to_numpy(float)
        tol = p["touch_atr"] * a

        at_pdh = np.isfinite(pdh) & (hi >= pdh - tol) & (c < pdh)
        at_pdl = np.isfinite(pdl) & (lo <= pdl + tol) & (c > pdl)
        S = ok & at_pdh & f["rejection_bear"].to_numpy()
        L = ok & at_pdl & f["rejection_bull"].to_numpy()
        stop_s = pdh + p["stop_atr"] * a
        stop_l = pdl - p["stop_atr"] * a
        return self._finish(o, f, L, S, stop_l, stop_s,
                            tp_l=c + p["rr"] * (c - stop_l), tp_s=c - p["rr"] * (stop_s - c),
                            trail_mult=p["trail_atr"])


ALL = [TrendContinuation, TrendPullback, BreakoutRetest, VolatilityExpansion,
       MeanReversion, LiquiditySweepReversal, BosChochContinuation,
       FvgRetracement, SessionBreakout, PdhPdlReaction]
BY_ID = {c.spec.id: c for c in ALL}

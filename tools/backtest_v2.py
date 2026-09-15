#!/usr/bin/env python3
"""
backtest_v2.py - event-driven simulator with a real cost model.

Differences from backtest.py (which stays, and still backs the v1 pipeline):

  * JUMPS between signals instead of walking every bar. Signals are sparse -
    a few thousand entries in a few hundred thousand bars - so stepping one
    bar at a time spends almost all its effort on bars where nothing can
    happen. Work is now O(trades x holding period), which makes a full
    walk-forward over 10 strategies feasible.
  * PER-BAR SPREAD from the cost model, widened in dead hours and around news,
    rather than one flat cost number.
  * COMMISSION COMPUTED FROM THE ACTUAL STOP. A round turn costs the same in
    dollars whatever the stop width, so a tight stop pays a far larger
    fraction of its own risk. Charging every trade a flat 0.05R hides exactly
    the trades that cannot survive their own costs.

Event order within a bar is unchanged and still pessimistic: decisions come
from the last CLOSED bar, fills happen at the next open, and a bar touching
both stop and target is assumed to have hit the stop first.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Trade:
    direction: int
    entry_bar: int
    exit_bar: int
    entry: float
    exit: float
    r: float
    reason: str
    regime: str
    session: str
    mfe_r: float
    mae_r: float
    bars_held: int
    risk_price: float


@dataclass
class Result:
    trades: list = field(default_factory=list)

    @property
    def r(self) -> np.ndarray:
        return np.array([t.r for t in self.trades], float)

    def stats(self) -> dict:
        r = self.r
        if len(r) == 0:
            return dict(trades=0, expectancy_r=0.0, total_r=0.0, win_rate=0.0,
                        profit_factor=0.0, max_dd_r=0.0, t_stat=0.0,
                        worst_streak=0, best_streak=0, avg_bars=0.0,
                        avg_mfe_r=0.0, avg_mae_r=0.0)
        w, l = r[r > 0], r[r <= 0]
        eq = np.cumsum(r)
        dd = float(np.max(np.maximum.accumulate(eq) - eq)) if len(eq) else 0.0
        sd = float(np.std(r, ddof=1)) if len(r) > 1 else 0.0
        ws = bs = cw = cl = 0
        for x in r:
            if x > 0:
                cw += 1; cl = 0
            else:
                cl += 1; cw = 0
            ws = max(ws, cl); bs = max(bs, cw)
        return dict(
            trades=len(r), expectancy_r=float(r.mean()), total_r=float(r.sum()),
            win_rate=float(len(w) / len(r)),
            profit_factor=float(w.sum() / -l.sum()) if l.sum() < 0 else float("inf"),
            max_dd_r=dd,
            t_stat=float(r.mean() / sd * np.sqrt(len(r))) if sd > 1e-12 else 0.0,
            worst_streak=ws, best_streak=bs,
            avg_bars=float(np.mean([t.bars_held for t in self.trades])),
            avg_mfe_r=float(np.mean([t.mfe_r for t in self.trades])),
            avg_mae_r=float(np.mean([t.mae_r for t in self.trades])),
        )


def run(df, sig: dict, regime, session=None, cost=None,
        spread_arr=None, max_hold=None) -> Result:
    o = df["open"].to_numpy(float)
    h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float)
    n = len(df)

    ed = sig["entry_dir"]; es = sig["entry_stop"]; et = sig["entry_tp"]
    xl, xs = sig["exit_long"], sig["exit_short"]
    tl, ts = sig["trail_long"], sig["trail_short"]
    tg = sig["trail_gate"]; ms = sig.get("min_stop")

    regime = np.asarray(regime, dtype=object)
    session = np.asarray(session, dtype=object) if session is not None else np.full(n, "", object)
    if spread_arr is None:
        spread_arr = np.full(n, cost.spread if cost else 0.0)

    slip_in = cost.slippage_entry if cost else 0.0
    slip_stop = cost.slippage_stop if cost else 0.0
    hold_cap = max_hold if max_hold is not None else 10 ** 9

    res = Result()
    #: bars where a decision exists, so the flat loop can jump instead of walk
    sig_bars = np.flatnonzero(ed != 0)
    if len(sig_bars) == 0:
        return res
    ptr = 0
    i = 1

    while i < n:
        # ---- jump to the next bar whose PREVIOUS bar carried a signal ------
        while ptr < len(sig_bars) and sig_bars[ptr] < i - 1:
            ptr += 1
        if ptr >= len(sig_bars):
            break
        i = max(i, sig_bars[ptr] + 1)
        if i >= n:
            break
        d = i - 1

        direction = int(ed[d])
        stop = es[d]
        if not np.isfinite(stop) or direction == 0:
            ptr += 1
            continue

        sp = spread_arr[i]
        fill = o[i] + direction * (sp / 2.0 + slip_in)
        risk = abs(fill - stop)
        floor = ms[d] if ms is not None and np.isfinite(ms[d]) else 0.0

        if risk <= 1e-9 or (fill - stop) * direction <= 0 or risk < floor:
            ptr += 1
            continue

        comm_r = cost.commission_in_r(risk) if cost else 0.0
        tp = et[d]
        entry_bar = i
        mfe = mae = 0.0
        cur_stop = stop
        exited = False

        # ---- walk the position, bar by bar --------------------------------
        j = i
        while j < n:
            if direction > 0:
                mfe = max(mfe, (h[j] - fill) / risk)
                mae = max(mae, (fill - l[j]) / risk)
            else:
                mfe = max(mfe, (fill - l[j]) / risk)
                mae = max(mae, (h[j] - fill) / risk)

            # stop first, always - the pessimistic assumption
            hit_stop = (l[j] <= cur_stop) if direction > 0 else (h[j] >= cur_stop)
            if hit_stop:
                px = cur_stop - direction * slip_stop
                r = (px - fill) * direction / risk - comm_r
                res.trades.append(Trade(direction, entry_bar, j, fill, px, r, "stop",
                                        regime[d], session[d], mfe, mae, j - entry_bar, risk))
                exited = True
                break

            if np.isfinite(tp):
                hit_tp = (h[j] >= tp) if direction > 0 else (l[j] <= tp)
                if hit_tp:
                    r = (tp - fill) * direction / risk - comm_r
                    res.trades.append(Trade(direction, entry_bar, j, fill, tp, r, "target",
                                            regime[d], session[d], mfe, mae, j - entry_bar, risk))
                    exited = True
                    break

            if j > entry_bar:
                k = j - 1
                want = xl[k] if direction > 0 else xs[k]
                if want or (j - entry_bar) >= hold_cap:
                    px = o[j] - direction * (spread_arr[j] / 2.0)
                    r = (px - fill) * direction / risk - comm_r
                    why = "strategy_exit" if want else "time_stop"
                    res.trades.append(Trade(direction, entry_bar, j, fill, px, r, why,
                                            regime[d], session[d], mfe, mae, j - entry_bar, risk))
                    exited = True
                    break

                cand = tl[k] if direction > 0 else ts[k]
                gate = tg[k]
                if np.isfinite(cand) and np.isfinite(gate):
                    moved = (o[j] - fill) * direction
                    if moved >= gate and ((direction > 0 and cand > cur_stop) or
                                          (direction < 0 and cand < cur_stop)):
                        cur_stop = cand
            j += 1

        if not exited:
            px = df["close"].to_numpy(float)[-1]
            r = (px - fill) * direction / risk - comm_r
            res.trades.append(Trade(direction, entry_bar, n - 1, fill, px, r, "end_of_data",
                                    regime[d], session[d], mfe, mae, n - 1 - entry_bar, risk))
        i = max(j + 1, i + 1)

    return res


def breakdown(res: Result, by: str) -> dict:
    """Per-regime or per-session stats, for the scoring engine."""
    out = {}
    for t in res.trades:
        k = getattr(t, by)
        out.setdefault(k, []).append(t.r)
    return {k: dict(trades=len(v), expectancy_r=float(np.mean(v)),
                    win_rate=float(np.mean([x > 0 for x in v])),
                    total_r=float(np.sum(v)))
            for k, v in out.items()}

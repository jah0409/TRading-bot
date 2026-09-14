"""
backtest.py - bar-by-bar simulator for one strategy on one symbol.

Measures edge in R, never in money. Position sizing belongs to CRiskManager
and changes with the risk phase; if the harness reported dollars it would be
measuring the sizing rules rather than the strategy. One unit of risk per
trade, results in R multiples, and the risk manager scales that later.

Event order within each bar, chosen to avoid look-ahead:

  decisions are taken from bar i-1 (the last CLOSED bar), exactly as the live
  EA does, and filled at bar i's OPEN.

    1. open position: strategy Exit() from bar i-1  -> fill at open[i]
    2. open position: TrailStop() from bar i-1      -> move the stop
    3. bar i plays out: stop or take-profit hit?    -> fill at that level
    4. flat: Entry() from bar i-1                   -> fill at open[i]
    5. just entered: the rest of bar i can still stop us out

When a bar touches both the stop and the target, the stop is assumed to fill
first. That is pessimistic and deliberately so - the alternative flatters
every result you will ever produce here.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Position:
    direction: int          # +1 long, -1 short
    entry: float
    stop: float
    tp: float
    initial_risk: float     # |entry - stop| in price; this is 1R
    bar: int
    volume: float = 1.0     # fraction of the original position still open
    realised_r: float = 0.0


@dataclass
class Trade:
    direction: int
    entry_bar: int
    exit_bar: int
    entry: float
    exit: float
    r: float
    reason: str
    regime: int


@dataclass
class BacktestResult:
    trades: list = field(default_factory=list)

    @property
    def n(self) -> int:
        return len(self.trades)

    @property
    def r_series(self) -> np.ndarray:
        return np.array([t.r for t in self.trades], dtype=float)

    def stats(self) -> dict:
        r = self.r_series
        if len(r) == 0:
            return {"trades": 0, "expectancy_r": 0.0, "total_r": 0.0, "win_rate": 0.0,
                    "profit_factor": 0.0, "max_dd_r": 0.0, "t_stat": 0.0, "worst_streak": 0}
        wins, losses = r[r > 0], r[r <= 0]
        equity = np.cumsum(r)
        peak = np.maximum.accumulate(equity)
        sd = float(np.std(r, ddof=1)) if len(r) > 1 else 0.0

        streak = worst = 0
        for x in r:
            streak = streak + 1 if x <= 0 else 0
            worst = max(worst, streak)

        return {
            "trades": len(r),
            "expectancy_r": float(np.mean(r)),
            "total_r": float(np.sum(r)),
            "win_rate": float(len(wins) / len(r)),
            "profit_factor": float(wins.sum() / -losses.sum()) if losses.sum() < 0 else float("inf"),
            "max_dd_r": float(np.max(peak - equity)) if len(r) else 0.0,
            # t-statistic of the mean: rewards edge AND sample size, which is
            # what stops a 4-trade fluke outranking a real 200-trade edge
            "t_stat": float(np.mean(r) / sd * np.sqrt(len(r))) if sd > 1e-12 else 0.0,
            "worst_streak": worst,
        }


def run(df, sig: dict, regime: np.ndarray,
        cost_r: float = 0.0, spread: float = 0.0,
        max_bars: int | None = None) -> BacktestResult:
    """Simulate `sig` (from a StrategyBase.build) over `df`.

    cost_r  round-trip cost expressed as a fraction of 1R, applied per trade
    spread  price units added to entry and removed from exit
    """
    o = df["open"].to_numpy(float)
    h = df["high"].to_numpy(float)
    l = df["low"].to_numpy(float)
    n = len(df)

    entry_dir = sig["entry_dir"]
    entry_stop = sig["entry_stop"]
    entry_tp = sig["entry_tp"]
    exit_long, exit_short = sig["exit_long"], sig["exit_short"]
    frac_long, frac_short = sig["exit_fraction_long"], sig["exit_fraction_short"]
    trail_long, trail_short = sig["trail_long"], sig["trail_short"]
    trail_gate = sig["trail_gate"]
    min_stop = sig.get("min_stop")

    breakeven_only = bool(sig.get("_breakeven_only", False))
    hold_limit = sig.get("_max_hold_bars")

    res = BacktestResult()
    pos: Position | None = None

    def close(p: Position, price: float, bar: int, reason: str, fraction: float = 1.0):
        nonlocal pos
        fill = price - spread * p.direction
        r = (fill - p.entry) * p.direction / p.initial_risk
        part = min(fraction, p.volume)
        p.realised_r += r * part
        p.volume -= part
        if p.volume <= 1e-9:
            res.trades.append(Trade(p.direction, p.bar, bar, p.entry, fill,
                                    p.realised_r - cost_r, reason, regime[p.bar]))
            pos = None

    for i in range(1, n):
        d = i - 1  # decision bar: the last CLOSED bar

        if pos is not None:
            # 1. strategy exit, decided on bar d, filled at this open
            want_exit = exit_long[d] if pos.direction > 0 else exit_short[d]
            frac = frac_long[d] if pos.direction > 0 else frac_short[d]
            if want_exit:
                close(pos, o[i], i, "strategy_exit", float(frac))

        if pos is not None and hold_limit is not None and (i - pos.bar) >= hold_limit:
            close(pos, o[i], i, "time_stop")

        if pos is not None:
            # 2. trail. Only ever tightens, and only once far enough in profit.
            gate = trail_gate[d]
            if np.isfinite(gate):
                if breakeven_only:
                    moved = (o[i] - pos.entry) * pos.direction
                    if moved > gate:
                        cand = pos.entry
                        if (pos.direction > 0 and cand > pos.stop) or \
                           (pos.direction < 0 and cand < pos.stop):
                            pos.stop = cand
                else:
                    cand = trail_long[d] if pos.direction > 0 else trail_short[d]
                    if np.isfinite(cand):
                        moved = (o[i] - pos.entry) * pos.direction
                        if moved >= gate:
                            if (pos.direction > 0 and cand > pos.stop) or \
                               (pos.direction < 0 and cand < pos.stop):
                                pos.stop = cand

        if pos is not None:
            # 3. did this bar take out the stop or the target?
            if pos.direction > 0:
                if l[i] <= pos.stop:
                    close(pos, pos.stop, i, "stop")
                elif np.isfinite(pos.tp) and h[i] >= pos.tp:
                    close(pos, pos.tp, i, "take_profit")
            else:
                if h[i] >= pos.stop:
                    close(pos, pos.stop, i, "stop")
                elif np.isfinite(pos.tp) and l[i] <= pos.tp:
                    close(pos, pos.tp, i, "take_profit")

        # 4. entry, decided on bar d, filled at this open
        if pos is None and entry_dir[d] != 0:
            direction = int(entry_dir[d])
            stop = entry_stop[d]
            if np.isfinite(stop):
                fill = o[i] + spread * direction
                risk = abs(fill - stop)
                # A stop on the wrong side, or closer than the ATR floor, is
                # not a trade. CRiskManager::Approve rejects exactly these, so
                # the simulator must refuse them too or it measures an edge the
                # live EA can never take.
                floor = min_stop[d] if min_stop is not None else 0.0
                if not np.isfinite(floor):
                    floor = 0.0
                if risk > 1e-9 and (fill - stop) * direction > 0 and risk >= floor:
                    pos = Position(direction, fill, stop, entry_tp[d], risk, i)

                    # 5. the rest of this bar can still stop us out
                    if direction > 0:
                        if l[i] <= pos.stop:
                            close(pos, pos.stop, i, "stop_same_bar")
                        elif np.isfinite(pos.tp) and h[i] >= pos.tp:
                            close(pos, pos.tp, i, "tp_same_bar")
                    else:
                        if h[i] >= pos.stop:
                            close(pos, pos.stop, i, "stop_same_bar")
                        elif np.isfinite(pos.tp) and l[i] <= pos.tp:
                            close(pos, pos.tp, i, "tp_same_bar")

        if max_bars is not None and i >= max_bars:
            break

    return res

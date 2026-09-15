#!/usr/bin/env python3
"""
data_engine.py - the single source of market data for all research.

M1 is the master series. Every other timeframe is derived from it by exact
aggregation, which the audit verified reproduces the supplied M30 file with
100.00% exact OHLC match. One source means two timeframes can never disagree.

Three guarantees this module exists to provide:

1. POINT-IN-TIME. A higher-timeframe bar is only visible to a lower timeframe
   once it has CLOSED. `align()` shifts every HTF column forward by one bar
   before joining, so an M5 bar at 14:05 sees the H1 bar that closed at 14:00,
   never the one still forming. This is the single most common way a backtest
   lies to you.

2. NO INVENTED CANDLES. Gaps are recorded, never filled. `gap_registry()`
   returns the holes; research windows exclude them rather than bridging them.

3. HONEST SESSIONS. The data clock is EET/EEST (UTC+2 winter, UTC+3 summer),
   identified in the audit from the week open and the volume profile. Session
   boundaries are computed per-bar because the DST offset is not constant.
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

TF_MINUTES = {"M1": 1, "M5": 5, "M15": 15, "M30": 30, "H1": 60, "H4": 240, "D1": 1440}
PANDAS_RULE = {"M1": "1min", "M5": "5min", "M15": "15min", "M30": "30min",
               "H1": "1h", "H4": "4h", "D1": "1D"}

#: The data clock. EET in winter, EEST in summer - the MT5 broker standard.
DATA_TZ = "Europe/Athens"


# ---------------------------------------------------------------------------
@dataclass
class Gap:
    start: pd.Timestamp
    end: pd.Timestamp
    minutes: float
    missing_bars: int

    def as_dict(self):
        return {"start": str(self.start), "end": str(self.end),
                "hours": round(self.minutes / 60, 2), "missing_bars": self.missing_bars}


class MarketData:
    """Loads M1 once, serves every timeframe derived from it."""

    def __init__(self, m1: pd.DataFrame, symbol: str = "XAUUSD"):
        if not isinstance(m1.index, pd.DatetimeIndex):
            raise TypeError("M1 frame must be indexed by datetime")
        if not m1.index.is_monotonic_increasing:
            m1 = m1.sort_index()
        if m1.index.has_duplicates:
            m1 = m1[~m1.index.duplicated(keep="first")]
        self.m1 = m1
        self.symbol = symbol
        self._cache: dict[str, pd.DataFrame] = {"M1": m1}

    # --- loading ----------------------------------------------------------
    @classmethod
    def from_jsonl(cls, path: str | Path, symbol: str = "XAUUSD") -> "MarketData":
        df = pd.read_json(path, lines=True)
        df.columns = [c.lower() for c in df.columns]
        df["date"] = pd.to_datetime(df["date"])
        df = df.rename(columns={"date": "time"}).set_index("time")
        keep = [c for c in ("open", "high", "low", "close", "volume") if c in df.columns]
        return cls(df[keep], symbol)

    @classmethod
    def from_csv(cls, path: str | Path, symbol: str = "XAUUSD") -> "MarketData":
        with open(path, errors="replace") as fh:
            first = fh.readline()
        skip = 0 if first.lower().lstrip().startswith(("date", "time")) else 1
        # index_col=False: these exports end rows with a trailing comma, which
        # otherwise promotes the date to the index and shifts every field left
        df = pd.read_csv(path, skiprows=skip, index_col=False)
        df.columns = [c.lower().strip() for c in df.columns]
        df["date"] = pd.to_datetime(df["date"], format="mixed")
        df = df.rename(columns={"date": "time"}).set_index("time").sort_index()
        keep = [c for c in ("open", "high", "low", "close", "volume") if c in df.columns]
        return cls(df[keep], symbol)

    # --- derivation --------------------------------------------------------
    def tf(self, timeframe: str) -> pd.DataFrame:
        """Exact aggregation of M1 to `timeframe`. Cached."""
        timeframe = timeframe.upper()
        if timeframe in self._cache:
            return self._cache[timeframe]
        if timeframe not in PANDAS_RULE:
            raise ValueError(f"unknown timeframe {timeframe}")

        agg = {"open": "first", "high": "max", "low": "min", "close": "last"}
        if "volume" in self.m1.columns:
            agg["volume"] = "sum"
        out = (self.m1.resample(PANDAS_RULE[timeframe], label="left", closed="left")
               .agg(agg).dropna(subset=["open", "high", "low", "close"]))
        self._cache[timeframe] = out
        return out

    # --- data holes --------------------------------------------------------
    def gap_registry(self, timeframe: str = "M1", weekend_hours=(47, 72)) -> list[Gap]:
        """Real holes in the feed, excluding the normal weekend break.

        Never used to fill anything in - used to EXCLUDE periods from research.
        """
        df = self.tf(timeframe)
        step = TF_MINUTES[timeframe.upper()]
        d = df.index.to_series().diff().dt.total_seconds() / 60.0
        weekend = (d >= weekend_hours[0] * 60) & (d <= weekend_hours[1] * 60)
        holes = (d > step * 1.5) & ~weekend
        out = []
        idx = df.index
        for i in np.flatnonzero(holes.to_numpy()):
            out.append(Gap(idx[i - 1], idx[i], float(d.iloc[i]),
                           int(round(d.iloc[i] / step - 1))))
        return out

    def clean_windows(self, timeframe="M1", min_gap_hours=24.0) -> list[tuple]:
        """Contiguous spans with no hole longer than `min_gap_hours`."""
        gaps = [g for g in self.gap_registry(timeframe) if g.minutes >= min_gap_hours * 60]
        df = self.tf(timeframe)
        bounds, start = [], df.index[0]
        for g in gaps:
            bounds.append((start, g.start))
            start = g.end
        bounds.append((start, df.index[-1]))
        return [(a, b) for a, b in bounds if b > a]

    # --- the point-in-time join -------------------------------------------
    @staticmethod
    def align(base: pd.DataFrame, higher: pd.DataFrame, prefix: str,
              columns: list[str] | None = None) -> pd.DataFrame:
        """Attach CLOSED higher-timeframe values to each base bar.

        The shift(1) is the whole point. Without it an M5 bar at 14:05 would
        see the H1 bar stamped 14:00 - which does not finish until 15:00 and
        therefore contains an hour of the future. With it, that M5 bar sees the
        H1 bar stamped 13:00, the last one actually closed.
        """
        cols = columns if columns is not None else list(higher.columns)
        src = higher[cols].shift(1)
        src = src.add_prefix(f"{prefix}_")
        return base.join(src.reindex(base.index, method="ffill"))

    # --- sessions ----------------------------------------------------------
    @staticmethod
    def sessions(index: pd.DatetimeIndex) -> pd.DataFrame:
        """Session flags and distance-from-open, computed per bar.

        Timestamps are on the EET/EEST data clock. Converting to UTC bar by bar
        handles the DST shift; assuming a fixed +2 or +3 would put every London
        and New York boundary an hour out for half the year.
        """
        local = index.tz_localize(DATA_TZ, ambiguous="NaT", nonexistent="NaT")
        utc = local.tz_convert("UTC")
        h = utc.hour + utc.minute / 60.0

        asian = (h >= 23) | (h < 7)          # Tokyo/Sydney
        london = (h >= 7) & (h < 16)
        newyork = (h >= 12.5) & (h < 21)
        overlap = london & newyork           # 12:30-16:00 UTC, the live window

        out = pd.DataFrame(index=index)
        out["utc_hour"] = h
        out["sess_asian"] = asian
        out["sess_london"] = london
        out["sess_newyork"] = newyork
        out["sess_overlap"] = overlap
        out["sess_dead"] = ~(asian | london | newyork)

        def since(mask, boundary):
            """Bars since this session opened (NaN when outside it)."""
            opened = mask & ~np.roll(mask, 1)
            grp = np.cumsum(opened)
            s = pd.Series(np.arange(len(mask)), index=index)
            first = s.groupby(grp).transform("first")
            return np.where(mask, s - first, np.nan)

        out["bars_since_london_open"] = since(np.asarray(london), 7)
        out["bars_since_ny_open"] = since(np.asarray(newyork), 12.5)
        out["session"] = np.select(
            [np.asarray(overlap), np.asarray(london & ~overlap),
             np.asarray(newyork & ~overlap), np.asarray(asian)],
            ["OVERLAP", "LONDON", "NEWYORK", "ASIAN"], default="DEAD")
        return out


# ---------------------------------------------------------------------------
def build_cache(m1_path: str, out_dir: str, timeframes=("M5", "M15", "M30", "H1", "H4", "D1")):
    """Write derived timeframes to parquet so research does not re-resample 6.6M rows."""
    md = MarketData.from_jsonl(m1_path)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    manifest = {"symbol": md.symbol, "source": str(m1_path), "data_tz": DATA_TZ,
                "timeframes": {}}
    md.m1.to_parquet(out / "XAUUSD_M1.parquet")
    manifest["timeframes"]["M1"] = {
        "rows": len(md.m1), "start": str(md.m1.index[0]), "end": str(md.m1.index[-1])}
    print(f"  M1   {len(md.m1):>9,} bars  {md.m1.index[0]} .. {md.m1.index[-1]}")

    for tf in timeframes:
        df = md.tf(tf)
        df.to_parquet(out / f"XAUUSD_{tf}.parquet")
        manifest["timeframes"][tf] = {
            "rows": len(df), "start": str(df.index[0]), "end": str(df.index[-1])}
        print(f"  {tf:<4} {len(df):>9,} bars  {df.index[0]} .. {df.index[-1]}")

    gaps = md.gap_registry("M1")
    big = sorted([g for g in gaps if g.minutes >= 24 * 60], key=lambda g: -g.minutes)
    manifest["gaps_over_24h"] = [g.as_dict() for g in big[:50]]
    manifest["gap_count_total"] = len(gaps)
    manifest["clean_windows"] = [[str(a), str(b)] for a, b in md.clean_windows("M1")]
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"\n  gaps: {len(gaps):,} total, {len(big)} longer than 24h")
    print(f"  clean windows: {len(manifest['clean_windows'])}")
    for a, b in manifest["clean_windows"][:10]:
        print(f"    {a[:10]} .. {b[:10]}")
    print(f"\n  -> {out}/manifest.json")
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--m1", required=True, help="M1 jsonl")
    ap.add_argument("--out", required=True, help="cache directory")
    a = ap.parse_args()
    build_cache(a.m1, a.out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
audit_data.py - inspect a historical OHLC dataset before anyone trusts it.

Nothing in the research pipeline should consume a file that has not been
through this. It answers, per file:

  actual timeframe (inferred from timestamp spacing, NOT the filename)
  start / end / candle count / timestamp format
  duplicate timestamps, out-of-order rows, invalid OHLC
  missing candles vs. an expected session calendar
  gaps, price spikes
  a RESEARCH_GRADE / LIMITED / INSUFFICIENT verdict

It does not repair anything. Interpolating OHLC and calling it history is how
a backtest ends up validating candles that never traded.

  python3 tools/audit_data.py FILE [FILE ...] [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

#: minute counts for the timeframes the EA understands
TF_MINUTES = {"M1": 1, "M5": 5, "M15": 15, "M30": 30,
              "H1": 60, "H4": 240, "D1": 1440, "W1": 10080}

#: rows needed before a timeframe can carry each research job.
#: Deliberately conservative - these are sample-size floors, not targets.
RESEARCH_FLOOR = 20_000     # enough for walk-forward with several folds
LIMITED_FLOOR = 3_000       # enough to look at, not enough to conclude from


def infer_timeframe(times: pd.Series) -> tuple[str, float, pd.Series]:
    """Modal spacing between consecutive bars -> timeframe label."""
    deltas = times.diff().dropna().dt.total_seconds() / 60.0
    if deltas.empty:
        return "UNKNOWN", float("nan"), deltas
    modal = float(deltas.mode().iloc[0])
    label = "UNKNOWN"
    for name, mins in TF_MINUTES.items():
        if abs(modal - mins) < 1e-6:
            label = name
            break
    if label == "UNKNOWN":
        # nearest known timeframe, flagged by the caller via modal value
        nearest = min(TF_MINUTES.items(), key=lambda kv: abs(kv[1] - modal))
        label = f"~{nearest[0]}"
    return label, modal, deltas


def load(path: Path) -> pd.DataFrame:
    """Read jsonl or csv into time/open/high/low/close[/volume], chronological."""
    suffix = path.suffix.lower()

    if suffix in (".jsonl", ".ndjson"):
        df = pd.read_json(path, lines=True)
    else:
        # these exports carry a title line above the real header
        with open(path, "r", errors="replace") as fh:
            first = fh.readline()
        skip = 0 if "," in first and first.lower().lstrip().startswith(("date", "time")) else 1
        # index_col=False matters: these exports end every data row with a
        # trailing comma, which makes pandas silently promote the date column
        # to the index and shift every field one to the left. Open becomes
        # "Date", Close becomes "Low", and the audit reports year 5422.
        df = pd.read_csv(path, skiprows=skip, index_col=False)

    df.columns = [str(c).strip().lower() for c in df.columns]
    ren = {}
    for c in df.columns:
        if c.startswith("date") or c in ("time", "timestamp", "datetime"):
            ren[c] = "time"
        elif c.startswith("open"):
            ren[c] = "open"
        elif c.startswith("high"):
            ren[c] = "high"
        elif c.startswith("low"):
            ren[c] = "low"
        elif c.startswith("close") or c.startswith("price"):
            ren[c] = "close"
        elif c.startswith("vol") or c.startswith("tickvol"):
            ren[c] = "volume"
    df = df.rename(columns=ren)

    missing = [c for c in ("time", "open", "high", "low", "close") if c not in df.columns]
    if missing:
        raise ValueError(f"missing columns {missing}; saw {list(df.columns)}")

    raw_time = df["time"].astype(str)
    fmt = detect_time_format(raw_time)
    df["time"] = pd.to_datetime(raw_time, format=fmt, errors="coerce") if fmt \
        else pd.to_datetime(raw_time, errors="coerce", format="mixed")

    for c in ("open", "high", "low", "close"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    if "volume" in df.columns:
        df["volume"] = pd.to_numeric(df["volume"], errors="coerce")

    df.attrs["time_format"] = fmt or "mixed/inferred"
    df.attrs["rows_raw"] = len(df)
    return df


def detect_time_format(s: pd.Series) -> str | None:
    sample = s.dropna().astype(str).head(200)
    if sample.empty:
        return None
    for fmt in ("%Y.%m.%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%d %H:%M", "%m/%d/%Y %H:%M", "%d/%m/%Y %H:%M",
                "%Y-%m-%d", "%Y.%m.%d"):
        try:
            pd.to_datetime(sample, format=fmt)
            return fmt
        except (ValueError, TypeError):
            continue
    return None


def session_hour_profile(times: pd.Series) -> dict:
    """Which UTC-ish hours carry bars. Hints at the server timezone."""
    hours = times.dt.hour.value_counts().sort_index()
    total = int(hours.sum())
    quiet = [int(h) for h in range(24) if hours.get(h, 0) < total / 24 * 0.25]
    return {"bars_per_hour": {int(k): int(v) for k, v in hours.items()},
            "quiet_hours": quiet}


def audit(path: Path) -> dict:
    out: dict = {"file": path.name, "path": str(path)}
    try:
        df = load(path)
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"
        out["verdict"] = "INSUFFICIENT"
        return out

    out["rows_raw"] = int(df.attrs["rows_raw"])
    out["time_format"] = df.attrs["time_format"]

    bad_time = int(df["time"].isna().sum())
    df = df.dropna(subset=["time"]).copy()
    out["unparseable_timestamps"] = bad_time

    # ordering: record whether the FILE was ordered, then sort for analysis
    was_sorted = bool(df["time"].is_monotonic_increasing)
    was_reverse = bool(df["time"].is_monotonic_decreasing)
    out["file_order"] = ("chronological" if was_sorted else
                         "reverse-chronological" if was_reverse else "UNORDERED")
    df = df.sort_values("time").reset_index(drop=True)

    dup = int(df["time"].duplicated().sum())
    out["duplicate_timestamps"] = dup
    df_nodup = df.drop_duplicates(subset="time", keep="first").reset_index(drop=True)

    out["rows_usable"] = int(len(df_nodup))
    if len(df_nodup) < 10:
        out["verdict"] = "INSUFFICIENT"
        return out

    tf, modal, deltas = infer_timeframe(df_nodup["time"])
    out["inferred_timeframe"] = tf
    out["modal_spacing_minutes"] = round(modal, 4)
    out["start"] = str(df_nodup["time"].iloc[0])
    out["end"] = str(df_nodup["time"].iloc[-1])
    span_days = (df_nodup["time"].iloc[-1] - df_nodup["time"].iloc[0]).total_seconds() / 86400
    out["span_days"] = round(span_days, 1)
    out["span_years"] = round(span_days / 365.25, 2)

    # --- OHLC validity ------------------------------------------------
    o, h, l, c = (df_nodup[x].to_numpy(float) for x in ("open", "high", "low", "close"))
    finite = np.isfinite(o) & np.isfinite(h) & np.isfinite(l) & np.isfinite(c)
    pos = finite & (o > 0) & (h > 0) & (l > 0) & (c > 0)
    hl = pos & (h >= l)
    envelope = hl & (h >= np.maximum(o, c) - 1e-9) & (l <= np.minimum(o, c) + 1e-9)
    out["rows_nonfinite_or_nonpositive"] = int((~pos).sum())
    out["rows_high_below_low"] = int((pos & ~hl).sum())
    out["rows_ohlc_envelope_violation"] = int((hl & ~envelope).sum())
    out["rows_ohlc_valid"] = int(envelope.sum())

    # --- gaps and missing candles -------------------------------------
    exp = TF_MINUTES.get(tf.lstrip("~"), modal if modal > 0 else 1)
    d = deltas.to_numpy()
    out["bars_at_expected_spacing"] = int((np.abs(d - exp) < 1e-6).sum())
    # a weekend for gold is roughly 48-65h; anything beyond that is a data hole
    weekend_like = (d >= 47 * 60) & (d <= 72 * 60)
    intraday_gap = (d > exp * 1.5) & ~weekend_like
    out["weekend_like_breaks"] = int(weekend_like.sum())
    out["intraday_gaps"] = int(intraday_gap.sum())
    if intraday_gap.any():
        big = np.sort(d[intraday_gap])[::-1][:5]
        out["largest_intraday_gaps_hours"] = [round(float(x) / 60, 2) for x in big]
        # bars that "should" have existed inside those gaps
        out["estimated_missing_candles"] = int(np.round((d[intraday_gap] / exp - 1).sum()))
    else:
        out["estimated_missing_candles"] = 0

    # coverage against a naive 5-day trading week
    if exp > 0 and span_days > 0:
        expected_total = span_days * (24 * 60 / exp) * (5.0 / 7.0)
        out["coverage_vs_5day_week_pct"] = round(100.0 * len(df_nodup) / expected_total, 1)

    # --- spikes --------------------------------------------------------
    cc = c[envelope]
    if len(cc) > 100:
        r = np.diff(np.log(cc))
        sd = float(np.std(r))
        if sd > 0:
            z = np.abs(r) / sd
            out["returns_over_10_sigma"] = int((z > 10).sum())
            out["returns_over_20_sigma"] = int((z > 20).sum())
            out["max_abs_bar_return_pct"] = round(float(np.max(np.abs(r)) * 100), 3)

    out["price_min"] = round(float(np.nanmin(cc)), 2) if len(cc) else None
    out["price_max"] = round(float(np.nanmax(cc)), 2) if len(cc) else None

    prof = session_hour_profile(df_nodup["time"])
    out["quiet_hours_utc_label"] = prof["quiet_hours"]

    # --- verdict -------------------------------------------------------
    n = out["rows_usable"]
    problems = []
    if out["rows_ohlc_envelope_violation"] or out["rows_high_below_low"]:
        problems.append("invalid OHLC rows")
    if dup:
        problems.append("duplicate timestamps")
    if out.get("coverage_vs_5day_week_pct", 100) < 60:
        problems.append("sparse coverage")

    if n >= RESEARCH_FLOOR and not problems:
        verdict = "RESEARCH_GRADE"
    elif n >= RESEARCH_FLOOR:
        verdict = "RESEARCH_GRADE_WITH_CAVEATS"
    elif n >= LIMITED_FLOOR:
        verdict = "LIMITED"
    else:
        verdict = "INSUFFICIENT"
    out["verdict"] = verdict
    out["problems"] = problems
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", help="write the full report here")
    args = ap.parse_args()

    reports = []
    for f in args.files:
        p = Path(f)
        print(f"\n{'='*72}\n{p.name}\n{'='*72}")
        rep = audit(p)
        reports.append(rep)
        for k, v in rep.items():
            if k in ("path", "file"):
                continue
            print(f"  {k:<36} {v}")

    if args.json:
        Path(args.json).write_text(json.dumps(reports, indent=2))
        print(f"\nfull report -> {args.json}")

    print(f"\n{'='*72}\nSUMMARY\n{'='*72}")
    print(f"  {'file':<30}{'tf':>7}{'rows':>12}{'span_y':>8}  verdict")
    for r in reports:
        print(f"  {r['file'][:29]:<30}{str(r.get('inferred_timeframe','?')):>7}"
              f"{r.get('rows_usable',0):>12,}{str(r.get('span_years','?')):>8}  {r['verdict']}")


if __name__ == "__main__":
    main()

# XAUUSD historical data — audit

Audited 2026-09-15 with `tools/audit_data.py`. Nothing here was repaired,
interpolated, or back-filled. Where data is missing it is reported as missing.

## Files supplied

Five uploads, which unpack into two unrelated families.

| Upload | Contents |
|---|---|
| `XAUUSD_HISTORICAL_DATA_30MB.zip.part-aa/ab/ac` | split archive → 4 JSONL files |
| `XAU_4h_data.jsonl` (standalone) | byte-identical to the archived 4h file (md5 `491c03f8…`) — a duplicate, not extra data |
| `XAUUSD_2026_HISTORICAL_DATA.zip` | 4 CSVs, recent, different feed |

### The split archive is truncated

All three parts are exactly 31,457,280 bytes and the central directory is
absent, so the upload was cut off — at minimum a `part-ad` is missing. Entries
were recovered by scanning local file headers and inflating each deflate
stream between them.

| Entry | Recovered |
|---|---|
| `XAU_4h_data.jsonl` | complete |
| `XAU_1m_data.jsonl` | complete |
| `XAU_30m_data.jsonl` | complete |
| `XAU_15m_data.jsonl` | **truncated** — 133,978 whole records, 1 partial record dropped |

Any files that followed 15m in the archive (5m? 1h? 1d?) are gone entirely.

## Family A — JSONL (MT5-style export)

Format `{"Date":"2004.06.11 04:00","Open":…,"High":…,"Low":…,"Close":…,"Volume":…}`,
chronological, no duplicate timestamps, **zero invalid OHLC rows across all
four files**. Volume is tick volume.

| File | TF (inferred) | Rows | Range | Coverage | Verdict |
|---|---|---|---|---|---|
| `XAU_1m_data.jsonl` | **M1** | 6,600,530 | 2004-06-11 → 2025-10-01 | 82.5% | RESEARCH_GRADE |
| `XAU_30m_data.jsonl` | **M30** | 242,152 | 2004-06-11 → 2025-09-30 | 90.8% | RESEARCH_GRADE |
| `XAU_4h_data.jsonl` | **H4** | 32,074 | 2004-06-11 → 2025-09-30 | 96.2% | RESEARCH_GRADE |
| `XAU_15m_data.jsonl` | **M15** | 133,978 | 2004-06-11 → **2010-07-02** | 88.3% | LIMITED (stale) |

Timeframes were inferred from modal timestamp spacing and match the filenames
in every case.

### M1 is the master series

Resampling M1 → M30 reproduces the supplied M30 file with **100.00% exact
match on open, high, low and close** across all 242,152 comparable bars. The
same source, consistently exported.

That makes the architecture obvious: **keep M1, derive everything else.**

| Derived from M1 | Bars | Range |
|---|---|---|
| M5 | 1,405,621 | 2004-06-11 → 2025-10-01 |
| M15 | 481,599 | 2004-06-11 → 2025-10-01 |
| M30 | 242,592 | 2004-06-11 → 2025-10-01 |
| H1 | 122,044 | 2004-06-11 → 2025-10-01 |
| H4 | 32,132 | 2004-06-11 → 2025-10-01 |
| D1 | 5,393 | 2004-06-11 → 2025-10-01 |

This resolves the M15 truncation completely — a modern M15 series is rebuilt
from M1 rather than recovered from the broken archive. It also removes any
chance of two timeframes disagreeing, which separate files can and do.

### Missing candles

Real, and not to be filled in.

| TF | Weekend breaks | Intraday gaps | Est. missing bars |
|---|---|---|---|
| M1 | 1,038 | 212,931 | ~1,507,000 |
| M30 | 1,036 | 5,369 | ~28,600 |
| H4 | 1,036 | 148 | ~2,153 |

The largest holes are long: 1,622h (~68 days) in M1, 1,941h (~81 days) in H4,
plus 625h, 409h and 242h gaps. These sit mostly in the thin 2004–2008 era. M1
coverage of 82.5% against a naive 5-day week is normal for gold — the metal
does not trade 24/5 without pause — but the multi-week holes are genuine feed
outages and must be excluded from research windows, not bridged.

### Server timezone: EET/EEST (UTC+2 winter / UTC+3 summer)

Identified, not assumed:

- **No Sunday bars at all**; weekday counts are flat Mon–Fri.
- First bar of the week lands on hour **01**, last bar on hour **23**.
- Tick volume and bar range both peak at hour **16**, with a secondary peak at
  **09–10**.

Gold opens Sunday 22:00 UTC, which is Monday 01:00 at UTC+3 — exactly the
observed week open with no Sunday bars. The 16:00 peak is the NY/COMEX open
(13:30 UTC → 16:30 EEST); the 09–10 peak is the London open (08:00 UTC).

**This matters for session logic.** Asian/London/NY boundaries must be derived
from the data clock, not assumed to be UTC, and the EET↔EEST DST shift means
the offset is not constant. Session windows have to be computed per-bar.

## Family B — CSV (recent, different feed)

Format `MM/DD/YYYY HH:MM`, **reverse-chronological**, with a title line above
the header and **a trailing comma on every data row**. That trailing comma
makes pandas silently promote the date to the index and shift every field one
column left — Open is read as the date, Close as the low. The audit tool
initially reported dates in the year 5422 because of it; fixed with
`index_col=False`. Any loader for these files needs that guard.

Filenames carry no timeframe. Inferred from spacing:

| File | TF (inferred) | Rows | Range | Verdict |
|---|---|---|---|---|
| `XAUUSD_historical_data.csv` | **D1** | 812 | 2023-12-19 → 2026-09-14 | INSUFFICIENT alone |
| `…data (1).csv` | **H4** | 722 | 2026-03-31 → 2026-09-14 | INSUFFICIENT alone |
| `…data (2).csv` | **H1** | 671 | 2026-08-03 → 2026-09-14 | INSUFFICIENT alone |
| `…data (3).csv` | **M5** | 269 | 2026-09-11 → 2026-09-14 | INSUFFICIENT alone |

No duplicates, no invalid OHLC. "INSUFFICIENT" is about sample size only —
these are clean, they are just small.

### The two families agree

Over the 366 overlapping days (2023-12-19 → 2025-09-30), daily bars built from
the JSONL H4 versus the CSV D1:

| Field | Median abs diff | as % | p95 | max |
|---|---|---|---|---|
| high | 0.24 | 0.010% | 7.42 | 36.44 |
| low | 0.23 | 0.010% | 3.65 | 49.30 |
| close | 1.14 | 0.045% | 7.70 | 30.11 |

Same instrument, different brokers. Close differs more than high/low because
the two feeds cut the daily bar at different server hours — expected, and a
reason not to splice them naively.

### The eleven-month intraday hole

```
2004-06-11 ─────────────── M1 / M30 / H4 ──────────────► 2025-10-01
                          M15 ──► 2010-07-02
                    2023-12-19 ──── D1 (csv) ──────────────────► 2026-09-14
                                              2026-03-31 ─ H4 ─► 2026-09-14
                                                    2026-08-03 ─ H1 ─► ...
                                                          2026-09-11 M5 ►
```

Intraday history stops at **2025-10-01**. The last ~11.5 months exist only as
812 daily bars, plus a few hundred H4/H1/M5 bars from 2026. D1 bridges the
period continuously, so there is no hole in daily context — but there is no
intraday data to test an intraday strategy on for the most recent year.

## Fitness by research job

| Job | Source | Verdict |
|---|---|---|
| D1 higher-timeframe context | M1→D1 (5,393) + CSV D1 to 2026 | **RESEARCH_GRADE** |
| H4 regime analysis | M1→H4 / supplied H4 (32k, 21y) | **RESEARCH_GRADE** |
| H1 directional bias | M1→H1 (122k) — no H1 file supplied | **RESEARCH_GRADE** (derived) |
| M30 structure | M1→M30 (242k, 21y) | **RESEARCH_GRADE** |
| M15 setup detection | M1→M15 (482k, to 2025) | **RESEARCH_GRADE** (derived; the supplied M15 file is LIMITED/stale and should be ignored) |
| M5 entry confirmation | M1→M5 (1.4M, to 2025) | **RESEARCH_GRADE** (derived) |
| M1 execution research | M1 (6.6M, 21y) | **RESEARCH_GRADE**, with the caveat that these are OHLC bars, not ticks — no spread, no bid/ask |
| Out-of-sample (recent, unseen) | 2026 CSVs | **LIMITED** — 812 D1 bars is a usable final gate for daily context; 269 M5 bars is not enough to test an intraday strategy |

## What is not here

Stating these plainly because they bound what any backtest can claim:

1. **No spread or bid/ask.** Bars are mid/bid OHLC with tick volume. Spread,
   slippage and commission must be modelled as assumptions, not measured.
2. **No tick data.** Intrabar fill order is unknowable; a bar touching both
   stop and target has to be resolved by a pessimistic rule.
3. **No real out-of-sample intraday window.** The 2026 CSVs are too small.
4. **No US100 data at all.** Per §29, nothing measured here transfers.
5. **The 2004–2010 era is a different market.** Gold at $400 with thin tick
   volume is not the 2020s instrument. Useful for robustness checks, dangerous
   as a training set for live parameters.

## What would most improve validation

In priority order:

1. **M1 from 2025-10-01 to today**, from the broker you will actually trade —
   closes the 11-month hole and makes a genuine recent out-of-sample window.
2. **Tick data, or at least recorded spread**, for a 3–6 month window — turns
   the cost model from an assumption into a measurement.
3. **The same export for US100** — without it, US100 cannot be validated at all.
4. The missing `part-ad` of the archive, if more timeframes were in it.

## Reproducing this audit

```bash
python3 tools/audit_data.py <file> [...] --json report.json
```

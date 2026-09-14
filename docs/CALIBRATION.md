# Calibrating the regime classifier

The classifier ships with first-guess thresholds. They are not wrong so much
as arbitrary — nobody has shown they separate anything on *your* broker's
XAUUSD and US100. This is how you replace them with fitted ones.

## Why the classifier was restructured first

The original classifier was a chain of `if`s with hard cutoffs. Three things
made it uncalibratable, and all three are fixed:

1. **Hard cutoffs have no gradient.** A bar at ADX 24.9 and one at 25.1 got
   completely different labels, and a search over such a surface either does
   nothing or jumps wildly. Every threshold is now a *soft ramp*: the score
   goes 0 at `_lo` and 1 at `_hi`, linearly between.

2. **The branches were ordered, so precedence beat evidence.** `BREAKOUT` was
   tested first, which meant an established ADX-40 trend that happened to
   print one wide-range bar was relabelled a breakout. The classifier is now
   an **argmax over continuous scores** — every regime is scored, the best one
   wins, and nothing gets to pre-empt anything.

3. **Confidence was not comparable between branches.** A `RANGE` confidence of
   0.6 and a `TREND` confidence of 0.6 came from unrelated formulas, yet the
   allocator multiplied suitability by them and the composite vote weighted by
   them. Confidence is now one thing everywhere: **the margin between the
   winning score and the runner-up**, blended with the winner's level. Two
   regimes scoring 0.9 and 0.85 is genuine ambiguity and now reads as low
   confidence, which it always should have.

A fourth bug fell out of the rewrite: the breakout branch tested the *current*
bar for a coil (NR7 / inside bar). A breakout bar is by definition not an
inside bar, so that condition could never be true. Compression is now measured
over the bars **before** the one being classified.

## The pipeline

```
  MT5 terminal                          your machine
  ────────────                          ────────────
  RegimeExport.mq5  ──features CSV──▶   calibrate_regime.py
  (uses the live                        (mirrors the live
   scoring code)                         scoring code)
                                               │
                                               ▼
                                      regime.per_symbol block
                                      + suitability rows
                                               │
                                               ▼
                                          config.json
```

Both ends call the same scoring functions — `RegimeFeatures.mqh` in MQL5,
`tools/regime_lib.py` in Python. That is not a convenience: if calibration
fitted thresholds against features computed even slightly differently from the
ones the EA uses live, the fitted numbers would be worthless.

## Step 1 — export features

Copy `MQL5/Scripts/Adaptive/RegimeExport.mq5` into your terminal's
`MQL5/Scripts/`, compile, and run it on any chart. It walks history for every
configured symbol and timeframe and writes
`MQL5/Files/Adaptive/calib/features_<SYMBOL>_<TF>.csv`.

Each row is one bar: the exact features the detector would have seen, the
scores it would have produced — and forward-looking outcome columns
(`fwd_ret`, `fwd_efficiency`, `fwd_mae_atr`, `fwd_mfe_atr`, `fwd_vol_ratio`)
that only an offline tool is allowed to know.

Aim for 20,000 bars. H1 is the timeframe to start with — it carries the
heaviest weight in the composite vote.

## Step 2 — fit

```bash
python3 tools/calibrate_regime.py \
    --features features_XAUUSD_H1.csv \
    --symbol XAUUSD \
    --folds 4 \
    --emit-config --out xauusd_regime.json
```

Repeat per symbol. Never share a fitted block between symbols.

### What it optimises

The default objective is **risk-adjusted expectancy of the strategy family
each regime designates** — trend regimes designate trend-following, `RANGE`
designates mean reversion, `CHOP_HIVOL` designates staying out. A regime label
is only worth anything if it picks the right kind of strategy, so that is what
gets scored.

It scores `mean(R) / std(R)`, not `mean(R)`. This matters more than it looks:
staying out of high-volatility, zero-edge bars *cannot* raise the mean, so a
plain mean objective has no reason to ever identify `CHOP_HIVOL`. In testing it
duly collapsed that class to ~1% of bars and mislabelled two thirds of known
chop as trend. On a prop account that is the most expensive mistake the
classifier can make. Dividing by the standard deviation gives avoiding chop a
payoff.

`--objective label` is available as a cross-check: macro-F1 against
forward-derived labels. More interpretable, less directly tied to money.

### Read the stability table, not just the numbers

```
  parameter                  median      min      max   stability
  --------------------------------------------------------------
  adx_trend_lo                   22       20       26   loose
  adx_range_lo                    8        8        8   stable
  atr_expansion_lo            1.175        1      1.3   NOISE - ignore
```

Each fold is fitted independently; the reported value is the **median** across
folds. A parameter marked `NOISE` landed somewhere different in every fold —
the objective surface is flat in that direction and the fitted value is an
artefact of where the search stopped. Leave those at their defaults.

This is why `--folds` defaults to 4 rather than doing one fit. On three
independent test fixtures a single fit put `adx_trend_lo` at 22, 28 and 30
with near-identical scores. Any one of those, reported alone, would have
looked like a finding.

### Accept the fit only if

- **calibration beat defaults in most folds** (the tool prints the count), and
- **in→out degradation is under ~50%**, and
- the regime shares look sane — no class at 0%, none at 90%.

If calibration does not beat the defaults out of sample, keep the defaults.
That is a real result, not a failure.

## Step 3 — paste in

The emitted `regime.per_symbol.<SYMBOL>` block goes into `config.json`
verbatim. The `_suitability_measured_out_of_sample` rows are a **prior** for
`strategies[].suitability`, which `CPerformanceTracker` then adjusts from live
results.

One caveat the tool repeats in its own output: `breakout_dc` scores identically
to the trend strategies. The payoff proxy enters a breakout exactly as it
enters a trend, so it cannot separate them. What separates them is the
compression that came *before* — a feature, not an outcome. Treat that row as
"trend-like" and set its `RANGE` and `CHOP_HIVOL` cells by judgement.

## Step 4 — verify in observe mode

Load the EA with `InpAllowLiveTrading = false` for a week and read
`regime_*.csv`. Put the transitions next to the chart. If the labels do not
match what you see with your own eyes, the fit is wrong no matter what the
out-of-sample number said — go back to step 2 and look at the stability table
again.

## Self-test

The pipeline can be exercised without any broker data:

```bash
python3 tools/make_synthetic.py --bars 24000 --out /tmp/synth.csv
python3 tools/calibrate_regime.py --ohlc /tmp/synth.csv --symbol SYNTH --folds 4
```

The fixture plants known regime segments, so the run prints a
**planted-vs-classified** cross-tab that real market data can never give you.
Current results on that fixture:

| planted | recovered as itself |
|---|---|
| TREND_UP | 92% |
| TREND_DOWN | 81% |
| RANGE | 55% |
| BREAKOUT | mostly read as TREND |
| CHOP_HIVOL | poorly — about half correctly avoided via `UNKNOWN`, a third mislabelled as TREND |

Two honest conclusions from that table:

- **Trend detection is solid. Chop detection is the weak point.** Its partial
  saving grace is that the classifier abstains (`UNKNOWN`) on much of the chop
  it fails to name, and `UNKNOWN` means nobody trades. The residual — chop
  mislabelled as trend — is the real exposure, and it is the thing to watch
  in observe mode.
- **`BREAKOUT` is not fully separable from `TREND` using forward price action**,
  which is exactly why the share floor (`--min-regime-share`) exists to stop
  the optimiser deleting the class outright.

The fixture is a test harness, not a market model. Never calibrate production
thresholds on it.

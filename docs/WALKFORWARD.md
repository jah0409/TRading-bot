# Walk-forward validation

No strategy joins the live mix without passing out-of-sample. This is the
tooling that decides, and what it found when it was pointed at the strategies
this repo ships.

## Why it is not in the EA

Walk-forward means running many parameter sets across many windows. That is an
offline batch job, not something an EA can do while trading. The EA's side of
the contract is the logging; this is the rest.

## The tools

| Tool | Does |
|---|---|
| `tools/strategy_lib.py` | Python mirrors of the five `.mqh` strategies |
| `tools/backtest.py` | bar-by-bar simulator, results in R |
| `tools/walkforward.py` | anchored folds, parameter search, ACCEPT/REJECT |
| `tools/null_test.py` | **the one that catches lying simulators** |
| `tools/make_synthetic.py` | fixture with planted regimes |

```bash
python3 tools/null_test.py                                   # always run first
python3 tools/walkforward.py --ohlc bars.csv --symbol XAUUSD \
        --regime-config xauusd_regime.json --emit-config
```

## Run the null test first, every time

`null_test.py` runs every strategy, default parameters, no optimisation, over
several **pure geometric random walks**. Random data contains no edge by
construction, so a correct simulator must report an expectancy
indistinguishable from zero.

If a strategy shows a significantly **positive** edge there, the simulator is
lying and every walk-forward number downstream is worthless. This is not
theoretical — see "What it found" below.

A significantly **negative** result is not a bug. It means the strategy has a
structural cost on random data: an adverse reward:risk, or it pays the spread
often enough to bleed. That is a finding about the strategy.

Current state: no look-ahead bias detected.

```
  strategy          trades     exp R       t   result
  trend_ema            621   -0.0251   -1.27   OK - no edge, as expected
  mean_rev_bb          615   +0.0559   +0.97   OK - no edge, as expected
  breakout_dc         2224   +0.0429   +1.27   OK - no edge, as expected
  range_fade         19542   -0.0284   -7.19   negative edge (structural)
```

## What it measures

Everything is in **R**, never in money. Position sizing belongs to
`CRiskManager` and changes with the risk phase; a harness reporting dollars
would be grading the sizing rules, not the strategy.

The search maximises the **t-statistic of mean R**, `mean/sd × sqrt(n)`. Not
total profit, which rewards overtrading; not expectancy alone, which lets a
four-trade fluke outrank a 200-trade edge.

Execution follows the live EA: decide on the last **closed** bar, fill at the
next **open**. Within a bar the order is exit → trail → stop/target → entry,
and a bar that touches both the stop and the target is assumed to have hit the
stop first. That is pessimistic on purpose.

## Acceptance

`walkforward.py` prints ACCEPT or REJECT against three rules:

1. most folds reach `--min-trades` (default 20) — below that it is not evidence
2. out-of-sample expectancy is positive in **more than half** the folds
3. in→out degradation is **under 50%**

A strategy that fails ships with `"enabled": false`. That is a real result,
not a failure of the process.

Read the **stability** column before pasting anything. Each fold is fitted
independently and the reported value is the median; a parameter marked `NOISE`
landed somewhere different every fold and should stay at its default.

## What it found

Pointing this at the shipped strategies turned up three real defects.

### 1. Collapsing stops — a live-account bug, not a harness bug

`mean_rev_bb` reported **+0.98R per trade on a pure random walk**. Impossible,
so something was wrong. It was the strategy, not the simulator.

The stop is anchored to a **level** (the Bollinger band) while the fill happens
at **market**. When price closes far past the band, the two collide: the stop
lands almost on top of the entry, risk collapses toward zero, and R explodes —
one trade booked +104R on a move worth +0.5R.

Measured across 8,286 signals: **29% of stops were under 0.5 ATR, 12.7% under
0.25 ATR, and 1% were on the wrong side of the entry entirely.**

Live, that is much worse than a bad backtest number. `CalcLots` divides the
risk budget by the stop distance, so a near-zero stop asks for an enormous
position, on a stop the spread alone would take out.

Fixed in three places:

- `CStrategyBase::TryEnter` floors every stop at `min_stop_atr_mult × ATR`
  from the entry, centrally, so present and future strategies inherit it.
- `CRiskManager::Approve` rejects a sub-minimum stop independently — the
  backstop that holds even if a new strategy forgets, and on brokers that
  report `SYMBOL_TRADE_STOPS_LEVEL` as 0.
- `backtest.py` refuses the same entries, so the simulator cannot book trades
  the live EA would block.

After the fix, random-walk expectancy fell from +0.98R to +0.06R (t = +0.97,
indistinguishable from zero) and the harness rejects it.

### 2. `momo_pullback` is effectively inert

With shipped defaults it fired **once in 40,000 bars**. The funnel:

```
  regime is TREND_UP              5601 bars
  + 4-bar regime aligned          3883 bars   (-31%)
  + pulled back to EMA              83 bars   (-98%)
  + stochastic already oversold      2 bars   (-98%)
```

A 50-period EMA lags too far behind in a trend for price to come back within
0.75 ATR of it often, and on the rare bars it does, the stochastic is not also
at an extreme. The two conditions nearly exclude each other.

The search grid has been widened (faster EMAs, wider pullback bands) so the
optimiser has somewhere to go; with that room it finds parameter sets trading
184–713 times per fold. **The shipped defaults are too tight and should not be
used as-is.**

### 3. The `--min-trades` gate matters

Before the grid was widened, `trend_ema` produced 11–28 trades per fold and the
harness refused to judge it. That is the gate working. Expectancy on 11 trades
is noise, however good it looks.

## Parameter hygiene

- Two or three indicators per strategy. A fourth is almost always a fit.
- Optimise on round numbers and check the neighbours: if ADX 25 works and 24
  and 26 do not, you found noise, and the stability column will say so.
- **Test XAUUSD and US100 separately.** Sharing one parameter set between an
  instrument priced in the thousands with tick-level gold volatility and a cash
  index is a coincidence waiting to be discovered.
- Calibrate the regime classifier first (`docs/CALIBRATION.md`) and pass the
  result in with `--regime-config`. Strategy entries are gated by regime, so
  fitting strategies against an uncalibrated classifier fits both at once.

## A warning about the fixture

`make_synthetic.py` plants exploitable structure — mean-reverting ranges,
compression-then-burst breakouts. Every strategy passes on it, with
expectancies (+1R to +3R per trade) that no real market will give you. It
exists to prove the harness can **find** edge, paired with the null test which
proves the harness does not **invent** it. Never calibrate production
parameters on it.

## Ship disabled

Add a newly accepted strategy to `config.json` with `"enabled": false`, run it
in observe mode alongside the live mix for a few weeks, compare its logged
signals against what the harness said it would do, and only then enable it.

## Pruning live strategies

`CPerformanceTracker::IsPruneCandidate()` flags strategies with ≥40 trades and
negative expectancy into `strategy_*.csv`. Report-only on purpose —
auto-disabling on a live funded account, against an uncalibrated model, is how
you end up with one strategy left and no idea why.

Review flagged strategies monthly. Disable in `config.json`, don't delete — the
regime that suited it may come back.

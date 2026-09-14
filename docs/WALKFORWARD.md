# Walk-forward validation

No strategy joins the live mix without passing out-of-sample. This is the
process; the harness itself is not built yet.

## Why it is not in the EA

Walk-forward means running many parameter sets across many time windows. That
is an offline batch job, not something an EA can do while trading. The EA's
side of the contract is already done: every trade is logged with the strategy,
the regime at entry, the risk taken and the R-multiple achieved, so the
harness has everything it needs.

## Process

1. **Split.** Anchored windows: 6 months in-sample, 2 months out-of-sample,
   rolled forward 2 months at a time. At least 5 folds; fewer proves nothing.
2. **Optimise in-sample.** Only the strategy's own `params` block. Regime and
   risk settings stay fixed — optimising the risk engine against history is
   how you fit the drawdown you happened to avoid.
3. **Score out-of-sample** on expectancy in R, not on net profit. Profit is
   dominated by position size, which the risk manager owns, not the strategy.
4. **Accept** only if out-of-sample expectancy is positive in the majority of
   folds *and* the in-sample/out-of-sample degradation is under ~50%. A
   strategy that only works in-sample is a curve fit with good manners.
5. **Fill in the suitability table** from the per-regime results in the fold
   data, and paste it into the strategy's `suitability` block in config.json.
   These start as your prior; the live `CPerformanceTracker` adjusts them.
6. **Ship disabled.** Add the strategy to `config.json` with
   `"enabled": false`, run it in observe mode alongside the live mix for a
   few weeks, compare its logged signals against what it did in backtest,
   then enable.

## Parameter hygiene

- Two or three indicators per strategy. A fourth is almost always a fit.
- Optimise on round numbers and check the neighbours: if ADX 25 works and
  24 and 26 do not, you found noise.
- Test XAUUSD and US100 separately. Sharing one parameter set across an
  instrument priced in the thousands with tick-level gold volatility and a
  cash index is a coincidence waiting to be discovered.

## Pruning live strategies

`CPerformanceTracker::IsPruneCandidate()` flags strategies with ≥40 trades
and negative expectancy into `strategy_*.csv`. It is **report-only on
purpose** — auto-disabling on a live funded account, against an uncalibrated
model, is how you end up with one strategy left and no idea why.

Review flagged strategies monthly. Disable in `config.json`, don't delete —
the regime that suited it may come back.

# XAUUSD research results

Run 2026-09-15 against the real data supplied (see `docs/DATA_AUDIT.md`), with
realistic costs, strict train/validate/test separation and a random-walk null
test on every strategy.

**Headline: 2 of 30 strategy × timeframe combinations passed. Both edges are
thin. Nothing here justifies size.**

## What was tested

10 strategies × 3 timeframes (M15, H1, H4), each through 4 anchored
walk-forward folds with a separate TRAIN, VALIDATE and TEST block per fold and
a 15% final holdout never touched by any fold.

Costs applied per trade: spread 0.28 (×0.8 in the London/NY overlap, ×1.8 in
dead hours), entry slippage 0.10, stop slippage 0.25, commission $7/lot round
turn — charged **from the actual stop distance**, not as a flat per-trade
number.

## Result

| Timeframe | Accepted | Notes |
|---|---|---|
| M15 | **0 / 10** | every strategy loses after costs |
| H1 | **1 / 10** | `trend_continuation` |
| H4 | **1 / 10** | `bos_choch` |

### The two that passed

| | H1 `trend_continuation` | H4 `bos_choch` |
|---|---|---|
| Out-of-sample expectancy | **+0.038 R** | **+0.031 R** |
| Trades (out of sample) | 396 | 297 |
| Win rate | 48% | 47% |
| Profit factor | 1.13 | 1.08 |
| Max drawdown | 13.9 R | 16.5 R |
| Positive folds | 3 / 4 | 3 / 4 |
| Train→test degradation | +50% | +48% |
| Unstable params per fold | 0.2 | 0.5 |
| Evidence tier | STRONGER | STRONGER |

At 0.25% risk per trade, +0.038R is **+0.0095% of the account per trade**.
Over 396 trades spread across 13 years that is a real but very small edge, and
a 13.9R drawdown at 0.25% risk is a 3.5% account drawdown — inside the 5% kill
switch, but not by much.

## Why M15 failed: the cost floor

The single most important number in this study.

| TF | Median ATR | 1.5-ATR stop | Cost as % of stop | Cost in R |
|---|---|---|---|---|
| M5 | 0.95 | 1.43 | 26.6% | **0.315** |
| M15 | 1.75 | 2.63 | 14.4% | **0.171** |
| M30 | 2.60 | 3.89 | 9.8% | 0.116 |
| H1 | 3.81 | 5.71 | 6.7% | 0.079 |
| H4 | 7.96 | 11.95 | 3.2% | **0.038** |
| D1 | 22.09 | 33.13 | 1.1% | 0.014 |

A strategy must clear that number before it earns anything. On M15 it needs
+0.171R per trade just to break even. None of the ten came close. **M5 is
structurally untradeable at these costs** — a third of every R goes to the
broker.

## There is signal — it is just smaller than M15 costs

Comparing each strategy on real XAUUSD against a matched random walk, both at
**zero cost**, isolates the actual predictive content:

| Strategy | Real (gross) | Random (gross) | Edge |
|---|---|---|---|
| breakout_retest | −0.069 | −0.811 | **+0.742** |
| liquidity_sweep | −0.061 | −0.421 | **+0.361** |
| fvg_retrace | +0.014 | −0.159 | +0.173 |
| trend_continuation | −0.010 | −0.125 | +0.115 |
| bos_choch | −0.007 | −0.082 | +0.075 |
| **pooled** | | | **+0.207 R over 15,699 trades** |

The strategies read the market — they do materially better on real gold than
on noise. What they cannot do on M15 is beat their own transaction costs. That
is a different problem from "no edge", and it points at the fix: trade a
timeframe where the stop is wide enough that costs stop mattering.

## Null tests

No strategy showed a positive edge on random-walk data, so the simulator is
not leaking future information. Several are significantly **negative** on
noise (t = −24 to −5), which is the structural cost drag above, not a bug.

## What was rejected and why

Worth reading, because the rejections are where the method earned its keep:

- **`trend_pullback` (H1)** initially ACCEPTED on "positive in 1/1 folds" —
  only one fold had reached the 30-trade minimum, while pooled expectancy was
  **−0.093R**. The acceptance rule now requires positive *pooled, trade-
  weighted* expectancy and at least 3 qualifying folds. Counting folds without
  weighting them is not evidence.
- **`trend_continuation` (H4)** shows the best raw numbers of anything tested
  (+0.173R, PF 1.52) but was rejected for **no in-sample edge** — two of four
  folds trained negative, and fold 1 needed 4 unstable parameters. Good
  out-of-sample numbers on top of a failed in-sample fit are luck, not edge.
- **`liquidity_sweep` (H4)** pooled +0.037R but was positive in only 2/4
  folds. Inconsistent.
- Everything on **M15** failed on cost, as above.

## What this means for deployment

1. **Only the two validated strategies ship enabled.** Every other strategy in
   `config.json` has `"enabled": false`. That is the correct state for an
   unvalidated strategy.
2. **Phase 1 risk (0.25%) and it stays there** until live results provide
   their own evidence. With expectancy this thin, a promotion on anything less
   than a real live sample would be unjustified.
3. **Expect long flat periods.** 396 trades over 13 years on H1 is roughly 30
   a year. Combined with NO_VALID_EDGE mode, the EA will do nothing for long
   stretches. That is the design working, not a fault.
4. **Do not trade M5 or M15 with this cost structure.** If your broker's
   all-in cost is materially lower than the model here, re-run
   `tools/research.py --cost optimistic` and see whether that changes.
5. **US100 gets nothing from this.** Not one number transfers. It needs its
   own dataset and its own study.

## The honest caveat

Both surviving edges are ~0.03R with ~50% train→test degradation. They passed
a demanding process, but "passed" here means "not disproven", not "will make
money". The realistic expectation is a small edge that may or may not persist,
which is exactly why the EA ships at 0.25% risk with health monitoring,
probation states and a kill switch.

## Reproducing

```bash
python3 tools/data_engine.py --m1 XAU_1m_data.jsonl --out cache
python3 tools/research.py --cache cache --tf H1 --from 2012-01-01 --out h1.json
python3 tools/research.py --cache cache --tf H4 --from 2008-01-01 --out h4.json
```

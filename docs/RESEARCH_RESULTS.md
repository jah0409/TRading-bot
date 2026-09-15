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


---

# Addendum: the ≥10 pip minimum target

Added at your request: *"strategy must target at least 8–10 pips per winning
trade."*

## What a "pip" means on gold

Gold is quoted to 2 decimals, so 1 point = 0.01 USD. Two conventions are in
common use and they differ by 10×:

| Convention | 10 pips |
|---|---|
| 1 pip = 0.10 USD | 1.00 USD |
| 1 pip = 1.00 USD | **10.00 USD** |

**The conservative one is implemented**: `pip_size = 1.00`, so
`min_target_pips = 10` means a winning trade must be able to make a real
**$10.00** move. Set `risk.pip_size` to 0.10 in `config.json` if your broker's
convention differs.

For scale, at $1.00/pip a 10-pip target is 1.26× H4 ATR and 26× the round-trip
cost. At $0.10/pip it would be 0.13 ATR — scalping, and not viable at these
costs.

## How it is enforced — in three places

1. **Strategy layer** (`strategies_v2.py`): signals that cannot reach the
   minimum are **dropped, not stretched**. Pushing a target out to a level the
   market was never going to reach just converts winners into losers.
2. **Trail clamp** (`backtest_v2.py`): once trailing starts, the stop may not
   sit closer to entry than the minimum — otherwise a "10 pip minimum" quietly
   produces 3 pip trailed winners.
3. **Live gate** (`TradeGate.mqh`, check 15 of 16): every order is re-checked
   against `risk.min_target_pips` before it reaches the risk manager.

Where a strategy trails instead of setting a target, the **stop** distance must
clear the minimum: 1R is the natural unit of a winner, and a trade whose entire
1R is below the minimum cannot produce a qualifying winner however far it runs.

## A bug this constraint exposed

The first version of the trail clamp raised the stop to `entry + min_target`.
On M15, where ATR is ~1.75 and a 1.5-ATR stop is ~$2.63, a $10 floor sits at
roughly **+3.9R — above the current market price**. The next bar then satisfied
`low <= stop` and booked an exit the market never reached.

It reported **+0.595R expectancy and PF 2.46 on M15**, against a 0.171R cost
floor. That impossibility is what gave it away. Corrected behaviour: do not
trail at all until the trade is already past the minimum, and only then refuse
to trail back below it. The same family drops to −0.023R once fixed.

**Every "5/10 accepted" number produced before that fix was fictitious and has
been discarded.**

## Corrected results

| Timeframe | Accepted |
|---|---|
| M15 | 0 / 10 |
| H1 | 0 / 10 |
| H4 | 0 / 10 |

**Nothing clears the full acceptance bar under the ≥10 pip constraint.** The
rules were set before these numbers were seen and were not relaxed afterwards.

### The closest candidate

`bos_choch` on H4 — pooled **+0.081R over 281 trades**, PF 1.22, 64% win, max
drawdown 12.1R, **zero unstable parameters**, and train expectancy positive in
all four folds (+0.10 to +0.14). It fails on one clause: test expectancy was
positive in only 2 of 4 folds — though the two negatives were ≈breakeven
(−0.045, −0.016) and the two positives were substantial (+0.223, +0.167).

It ships **enabled but flagged `borderline: true`**, which makes
`CStrategyHealth` start it in **PROBATION at half risk**. That is what the
state machine is for: a positive expectancy that did not clear the consistency
test is neither a validated edge nor worth discarding.

Typical target: **11.9 pips**, minimum enforced 10.0.

## Did the constraint help or hurt?

Both. Per-trade expectancy improved — H4 `bos_choch` went from +0.031R to
+0.081R, and its drawdown fell from 16.5R to 12.1R, because the rule removes
small-target trades whose reward never justified the cost. But it also cuts
trade count, and with fewer trades per fold the consistency test became harder
to pass. The constraint is sound; the dataset is the limit.

## Honest bottom line

The ≥10 pip requirement is **achievable and, on the evidence, beneficial** —
but it does not manufacture an edge. After correcting the clamp bug, no
strategy in this library clears the full bar on your XAUUSD data.

The EA therefore ships with one borderline strategy on probation at half risk,
and will spend most of its time in `NO_VALID_EDGE` doing nothing. That is the
designed behaviour and the correct outcome for the evidence available.

---

# Addendum 2: can it take 15 trades a day?

Asked directly, so tested directly. Short answer: **no, and the reason is not
the one I expected.**

## 1. The physical ceiling

Gold moves a finite distance each day. From M5 data, 2022–2025:

| | median |
|---|---|
| Net daily range (high − low) | **$26** |
| Total path length (sum of all M5 moves) | **$194** |

Path length is the theoretical maximum any strategy could extract, and no
strategy gets near it — you enter late, exit early, and losing trades consume
path too. Above roughly a third of path is not realistic.

| Ask | Needs | % of daily path | |
|---|---|---|---|
| 15 trades × $10 target | $150 | **77%** | impossible |
| 15 × $5 | $75 | 39% | very hard |
| 15 × $3 | $45 | 23% | possible |
| 5 × $10 | $50 | 26% | possible |

So 15 trades a day **and** a 10-pip target cannot coexist. You can have one.

## 2. The cost wall

To reach 15/day you need M5 or faster. Cost drag there:

| Stop | Cost as % of stop | Cost in R |
|---|---|---|
| $1 | 38% | **0.450** |
| $2 | 19% | 0.225 |
| $3 | 12.7% | 0.150 |
| $5 | 7.6% | 0.090 |

M5 median ATR is $1.30. A stop wide enough to make costs tolerable is 2.3×
ATR — not a scalp stop, and it needs $6+ of movement to pay, which takes time
and cuts frequency straight back down.

## 3. What an actual scalper does

`ScalpSweepM5` was built for this test: sweep a micro swing, enter the
rejection, target N × risk. Deliberately permissive — micro swings, active
sessions, no regime filter beyond avoiding ABNORMAL — so that whatever limits
it is the market, not a filter chosen by me. 27 configurations, M5,
2022–2025, 886 trading days.

| swing_k | stop | RR | trades/day | median target | **gross** | net (std) | net (ECN) |
|---|---|---|---|---|---|---|---|
| 1 | 0.5 | 1.5 | **12.2** | $2.54 | −0.003 | −0.238 | −0.151 |
| 1 | 1.0 | 1.5 | 8.2 | $3.70 | +0.012 | −0.150 | −0.088 |
| 2 | 2.0 | 2.0 | 3.3 | $8.05 | −0.002 | −0.099 | −0.060 |
| 3 | 2.0 | 3.0 | 2.3 | $12.13 | +0.013 | −0.086 | −0.046 |

Two things to read here.

**The frequency ceiling is about 12/day**, not 15 — and only with a $2.54
target, which is 2.5 pips, not 10.

**More important: gross expectancy is zero.** Across all 27 configurations it
ranges −0.027 to +0.013 R — noise around nothing, *before a cent of costs*.
Costs then take another 0.09–0.27 R. Not one configuration is net positive at
standard or ECN costs.

That is the real finding. This is not an edge being eaten by spread; there is
**no edge to eat**. The sweep-and-reject pattern on M5 micro-swings is noise.
Making the costs cheaper does not fix a strategy whose gross expectancy is
zero — it just loses more slowly.

## 4. The frequency/quality frontier, as measured

| Approach | Trades/day | Expectancy | Status |
|---|---|---|---|
| M5 scalp, max frequency | 12.2 | −0.238 R | loses |
| M5 scalp, best config | 2.3 | −0.086 R | loses |
| M15 liquidity sweep | ~0.9 | −0.061 R | loses |
| H4 liquidity sweep | ~0.25 | −0.047 R | loses |
| **H4 bos_choch** | **0.11** | **+0.081 R** | **the only thing that works** |

The pattern is consistent and it points one way: on this instrument, with
these costs, **edge increases as frequency falls**.

## 5. What would actually raise trade count

Honest options, in order of how real they are:

1. **More symbols.** The architecture already runs several. Ten instruments at
   the validated rate is ~1 trade/day — not 15, but 10× more than now. Each
   needs its own dataset and its own validation; nothing transfers.
2. **More validated strategies.** Nine of ten failed. Finding more is
   open-ended research, not a setting.
3. **Accept the rate.** ~27 trades/year at +0.081 R, compounding slowly.

What will *not* work: loosening filters to force activity. That experiment is
already in this document — every M5 and M15 configuration tested, and all of
them lose.

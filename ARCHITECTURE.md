# AdaptiveEA — architecture

Regime-adaptive, multi-strategy MT5 Expert Advisor for **XAUUSD** and **US100**,
built around a single hard constraint: *the LegionFunding account must never
breach*. Everything else — strategy selection, regime detection, capital
allocation — is subordinate to that.

Status: **skeleton**. The flow is complete and wired end to end. Risk
arithmetic, config, logging, execution and news windows are implemented.
Regime thresholds and strategy entry rules are written but uncalibrated,
and three areas are explicit stubs (marked `=== STUB ===` in code).

---

## 1. Component map

```
                        ┌──────────────────────────┐
     OnTimer (5s) ─────▶│      COrchestrator       │◀──── OnTick (trailing only)
     OnTradeTransaction │  owns everything, runs   │
              ─────────▶│  the cooperative loop    │
                        └───────────┬──────────────┘
                                    │
      ┌──────────────┬──────────────┼──────────────┬──────────────┐
      ▼              ▼              ▼              ▼              ▼
┌───────────┐ ┌────────────┐ ┌────────────┐ ┌───────────┐ ┌──────────────┐
│  CConfig  │ │CRegime     │ │CNewsFilter │ │CRisk      │ │CStrategy     │
│ config    │ │Detector    │ │ blackout + │ │Manager    │ │Allocator     │
│ .json ->  │ │ ATR/ADX/   │ │ caution    │ │ THE GATE  │ │ scores ->    │
│ typed     │ │ candles    │ │ windows    │ │ + sizing  │ │ who trades   │
│ structs   │ │ M15/H1/H4  │ │            │ │           │ │              │
└───────────┘ └────────────┘ └────────────┘ └─────┬─────┘ └──────┬───────┘
                                                   │              │
                                    ┌──────────────┘              │
                                    ▼                             ▼
                          ┌──────────────────┐        ┌────────────────────┐
                          │ COrderExecutor   │◀───────│  CStrategyBase     │
                          │ the only code    │        │  Filter / Entry /  │
                          │ that sends       │        │  Exit / TrailStop  │
                          │ orders           │        └─────────┬──────────┘
                          └──────────────────┘                  │
                                                     ┌──────────┴──────────┐
                                                     ▼                     ▼
                                          ┌────────────────┐   ┌───────────────────┐
                                          │CVirtualAccount │   │CPerformanceTracker│
                                          │ per-strategy   │   │ [strategy×regime] │
                                          │ P/L & equity   │   │ expectancy matrix │
                                          └────────────────┘   └───────────────────┘
                                                     │                     │
                                                     └──────► CLogger ◄────┘
                                                        5 CSV streams
```

**The invariant worth remembering:** a strategy never sizes a position and
never sends an order. It produces a *price and a stop*. `CRiskManager` turns
that into lots, or refuses. `COrderExecutor` is the only code that talks to
the trade server. There is exactly one place a trade can be born —
`CStrategyBase::TryEnter()` — and it always goes through the gate.

---

## 2. The main loop

`OnTimer` fires every `execution.main_loop_seconds` (default 5):

| # | Step | Module |
|---|------|--------|
| 1 | Refresh equity, daily P/L, drawdown; set lock/kill flags | `CRiskManager::Update` |
| 2 | Reload the calendar if due | `CNewsFilter::Refresh` |
| 3 | If a risk event demands it, **flatten first** | `COrderExecutor::CloseAll` |
| 4 | Reset the cross-symbol concurrency counter | `CStrategyAllocator::BeginCycle` |
| 5 | Per symbol: classify regime on M15/H1/H4 | `CRegimeDetector::Evaluate` |
| 6 | Per symbol: build `SMarketContext` (prices, regime, news, phase) | `COrchestrator::BuildContext` |
| 7 | If inside a news blackout: close that symbol, skip it | `CNewsFilter` |
| 8 | Score strategies for this regime, enable the survivors | `CStrategyAllocator::Allocate` |
| 9 | Round-robin: `ManagePositions` then `TryEnter` per strategy | `CStrategyBase` |
| 10 | Mark virtual accounts to market | `CVirtualAccount` |
| 11 | Heartbeat to `equity_*.csv` every 60s | `CLogger` |

`OnTick` does **only** stop trailing — cheap, so a fast move cannot run past
an unmoved stop between 5-second passes.

`OnTradeTransaction` attributes each fill and close back to the strategy and
the regime that was live at entry. That attribution is what makes the
`[strategy × regime]` expectancy matrix — and therefore the whole feedback
loop — possible.

---

## 3. Risk model — and one number you should change

Concrete figures for account **#70188572**, $10,000:

| Limit | Value | Where enforced |
|---|---|---|
| Firm hard breach | $1,000 (10%) | `HardFloorEquity()` = $9,000 — flatten before it |
| Firm daily breach | $400 (4%) | `DailyFloorEquity()` — flatten before it |
| **Our kill switch** | 5% DD → $9,500 | flatten all + lock until manually cleared |
| **Our daily lock** | 2% → $200 | no new entries until server rollover |
| Per trade | 1% = $100 max | `strategy_max_risk_pct` |
| Per strategy open | 1% | `BLOCK_STRATEGY_RISK_CAP` |
| Sum of open stops | see below | `BLOCK_AGGREGATE_STOP_CAP` |

### The conflict in the brief

You asked for *"sum of stops ≤ 10% of balance"* and *"close all trades if
equity drawdown ≥ 5%"*. Those two cannot both hold. If open stops total 10%
and the market gaps through all of them at once — Sunday open on gold, a CPI
print on US100 — the account takes a 10% hit and **breaches on the spot**.
The kill switch never gets a chance to fire, because it needs a tick between
the 5% level and the stops to act on.

So `config.json` ships with `aggregate_stop_cap_pct: 6.0`, not 10. Six
percent is the largest simultaneous stop-out that still lands above the
$9,000 floor with room to spare. `CConfig::Validate()` logs a loud warning if
you raise it to 10 or above; it does not stop you. Your account, your call —
but the 10% figure is the one number in the brief I'd push back on.

Two further guards are already in `CalcLots()`:

- Sizing is capped at **half the remaining headroom** to the nearer of the
  daily and hard floors — so the last trade of a bad day cannot be the
  breaching one.
- The risk basis is `min(balance, equity, initial_balance)` — position size
  shrinks automatically in drawdown, and never inflates after a good run.

### Risk ramp

| Phase | Risk/trade | Max concurrent strategies |
|---|---|---|
| Month 1 | 0.25% | 2 |
| Month 2 | 0.50% | 3 |
| Month 3+ | 1.00% | 5 (hard ceiling, enforced in `PhaseMaxStrategies`) |

Promotion needs **time *and* profit**: `UpdatePhase()` demotes a phase if the
account is not up by `advance_min_profit_pct`. "Gradually increase risk as
the EA proves profitable" should mean proof, not just a calendar.

The concurrency cap counts **distinct strategies**, not strategy-symbol
pairs — `trend_ema` live on both XAUUSD and US100 consumes one slot, not two.

---

## 4. Regime detection

Per symbol, on M15 / H1 / H4:

- **ATR** → volatility, ranked as a *percentile* against its own 100-bar
  history. A raw ATR number means nothing across two instruments priced as
  differently as gold and a tech index; a percentile is comparable.
- **ADX + DI** → trend strength and direction.
- **Candles** → inside/outside bars, NR7 coils, wide-range expansion, pins,
  engulfings, as a bitmask.

Six regimes: `TREND_UP`, `TREND_DOWN`, `RANGE`, `BREAKOUT`, `CHOP_HIVOL`,
`UNKNOWN`. `CHOP_HIVOL` — high volatility with no direction — exists as its
own class because it is where multi-strategy systems bleed out: every
strategy sees a signal and they are all wrong.

The three timeframes are blended by configurable weights (default
M15 0.25 / H1 0.40 / H4 0.35) into a composite plus a confidence. Below
`min_composite_confidence` the composite collapses to `UNKNOWN` and
**nobody trades** — no trading on a guess.

Hysteresis (`min_bars_in_regime`) requires a new regime to persist before it
is adopted, which stops the active-strategy set churning every bar.

---

## 5. Strategy selection

```
final_score = base_suitability[regime]  ×  performance_adjustment
                      ▲                              ▲
              from config.json              from the live [strategy × regime]
              (your prior)                  expectancy matrix
```

The adjustment is shrunk toward 1.0 by sample size — with 5 trades the config
prior dominates; by ~20 trades the data is trusted half-way. That is the
"adjust suitability scores over time" loop, and it is deliberately slow.

Selection: drop anything below its own `min_suitability_to_run`, drop
anything `incompatible_with` an already-selected higher scorer (so you never
run `trend_ema` and `mean_rev_bb` on the same symbol at once), take the top N
for the phase, then split capital by score.

Shipped strategies — each 2–3 indicators, no more:

| id | Indicators | Home regime |
|---|---|---|
| `trend_ema` | EMA21, EMA55, ADX | TREND_UP / DOWN |
| `mean_rev_bb` | Bollinger(20,2), RSI14 | RANGE |
| `breakout_dc` | Donchian(20), ATR | BREAKOUT |
| `momo_pullback` | EMA50, Stochastic, ATR | TREND (pullback entry) |
| `range_fade` | RSI(2), ATR | RANGE / CHOP — **disabled until walk-forwarded** |

---

## 6. News filter

| Tier | Window | Events |
|---|---|---|
| A | ±60 min | FOMC, NFP, CPI, GDP, ECB/BoE/BoJ rate decisions, pressers |
| B | ±30 min | Retail sales, PMI, ISM, consumer sentiment/confidence, PPI |
| Caution | ±120 min | size ×0.5, stops ×1.5 — trade smaller, not not-at-all |

Both tiers **close open positions and block new entries**. Gold reacts to
EUR/GBP/JPY central banks, not just USD, so `news.currencies.XAU` covers all
four; US100 watches USD only.

Sources, in order: MQL5 native calendar → CSV → HTTP API. **If no source is
usable, the filter fails closed** (`fail_closed_if_stale: true`): no
calendar, no trading. On a funded account that is the only defensible
default.

---

## 7. Three things the brief asks for that need a decision

### 7.1 "Each strategy runs on a dedicated thread"

**MQL5 has no threads.** An EA is a single-threaded event handler; `OnTick`
and `OnTimer` must return before the next event is delivered, and there is no
API to spawn a worker. This is a platform limit, not an implementation
shortcut.

What is implemented instead: a **cooperative round-robin** with a per-pass
time budget (`pass_budget_ms`). Strategies that don't get their slice go
first next pass, so none can be starved. Combined with new-bar gating, each
strategy is evaluated against fresh data every few seconds — which is the
property you actually want from "concurrent".

If you need genuine parallelism, the EA has to become a thin bridge (named
pipes or a socket) to an external process in a language that has threads,
with MT5 reduced to execution and market data. That is a much larger build.
My recommendation: stay single-process. At 5-second cadence with five
strategies on two symbols, the loop costs a few milliseconds.

### 7.2 Calendar in the Strategy Tester

`CalendarValueHistory()` returns nothing in the Strategy Tester. Any backtest
that claims a news filter worked is using the CSV path — which is why the CSV
fallback exists and why backtests must run with a populated
`Files/Adaptive/calendar.csv` covering the test period. Otherwise the filter
fails closed and the backtest does nothing at all, which at least fails
loudly rather than silently overstating results.

`WebRequest()` also needs the host whitelisted in
*Tools → Options → Expert Advisors*, and never works in the tester. The API
parser is a stub — suggested flow is: fetch → normalise into the CSV → let
both live and tester read one format.

### 7.3 Walk-forward testing

Walk-forward validation cannot live inside the EA — it needs to run many
parameter sets over many windows, offline. The EA side of the contract is
done: every trade is logged with its regime, strategy, R-multiple and risk.
The harness that consumes those logs is a separate tool
(see `docs/WALKFORWARD.md`).

Pruning is deliberately **report-only**. `IsPruneCandidate()` flags
strategies with ≥40 trades and negative expectancy into the strategy log;
it does not auto-disable. Auto-pruning on a live funded account, off an
uncalibrated model, is how you end up with one strategy left and no idea why.

---

## 8. What is real vs. stubbed

| Area | State |
|---|---|
| Config load/validate, JSON parser | implemented |
| CSV logging (5 streams) | implemented |
| Risk arithmetic, sizing, all gates | implemented |
| Daily lock / kill switch, restart-persistent | implemented |
| Risk ramp phases | implemented |
| Regime detection plumbing + candle maths | implemented |
| Regime classifier **thresholds** | written, **uncalibrated** |
| News windows, tiering, fail-closed | implemented |
| Order execution, retries, trailing | implemented |
| Virtual accounts, expectancy matrix, allocation | implemented |
| Strategy entry rules | written, **uncalibrated** (`=== TUNE ME ===`) |
| News HTTP API parser | **stub** |
| Correlation model (XAUUSD↔US100) | **stub** — placeholder counts same-direction risk |
| Walk-forward harness | **not started** — offline tool |

---

## 9. Suggested order of work

1. **Compile and run in observe mode.** `InpAllowLiveTrading` is `false` by
   default — the EA classifies, scores and logs without sending an order.
   Leave it a week and read `regime_*.csv`. If the regime labels don't match
   what you see on the chart, nothing downstream matters.
2. **Calibrate the regime thresholds** per symbol. Gold and US100 will not
   share an ADX threshold.
3. **Walk-forward one strategy** end to end, prove the harness.
4. **Arm with one strategy**, phase 1, one symbol.
5. Add strategies only as each earns its place out of sample.

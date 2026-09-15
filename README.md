# AdaptiveEA

Regime-adaptive multi-strategy MetaTrader 5 Expert Advisor for **XAUUSD** and
**US100**, with prop-firm risk enforcement and an economic-calendar filter.

**Never used MetaTrader? Start here: [docs/SIMPLE_SETUP.md](docs/SIMPLE_SETUP.md)** — plain English, no jargon.

**More detail: [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).**

**Read [ARCHITECTURE.md](ARCHITECTURE.md) for how it works.** This is a skeleton: the
full flow is wired and the risk engine is real, but the regime thresholds and
strategy rules are uncalibrated and three areas are explicit stubs.

`InpAllowLiveTrading` defaults to **false**. The EA runs in observe mode —
classifying regimes, scoring strategies and writing logs — until you
deliberately arm it.

## Layout

```
MQL5/
  Experts/Adaptive/AdaptiveEA.mq5        entry point: OnInit/OnTimer/OnTick
  Include/Adaptive/
    Core/        Types, Json, Config, Logger
    Engine/      Orchestrator            main loop, scheduler, attribution
    Regime/      RegimeDetector          ATR + ADX + candles on M15/H1/H4
                 RegimeFeatures          scoring maths, shared with the exporter
    Risk/        RiskManager             sizing and every limit check
                 CorrelationModel        rolling rho; caps concentrated exposure
    News/        NewsFilter              blackout + caution windows
    Execution/   OrderExecutor           the only code that sends orders
    Portfolio/   VirtualAccount, PerformanceTracker, StrategyAllocator
    Strategies/  StrategyBase + 5 strategies + StrategyFactory
  Scripts/Adaptive/RegimeExport.mq5      dump features for calibration
  Files/Adaptive/
    config.json                          all tuning lives here
    calendar.csv                         fallback calendar (required for backtests)
tools/                                   offline research (Python)
  regime_lib.py                          mirror of RegimeFeatures.mqh
  calibrate_regime.py                    fit regime thresholds, emit config
  strategy_lib.py                        mirrors of the five .mqh strategies
  backtest.py                            bar-by-bar simulator, results in R
  walkforward.py                         anchored folds, ACCEPT/REJECT verdict
  null_test.py                           random-walk test for look-ahead bias
  test_correlation.py                    validates the portfolio-risk formula
  make_synthetic.py                      known-regime fixture
docs/CALIBRATION.md                      how to calibrate the classifier
docs/WALKFORWARD.md                      out-of-sample validation process
```

## Install

1. Copy `MQL5/Include/Adaptive` → `<terminal data folder>/MQL5/Include/`
2. Copy `MQL5/Files/Adaptive` → `<terminal data folder>/MQL5/Files/`
3. Copy `MQL5/Experts/Adaptive` → `<terminal data folder>/MQL5/Experts/`
4. Open `AdaptiveEA.mq5` in MetaEditor and compile (F7)
5. Edit `MQL5/Files/Adaptive/config.json`:
   - **`symbols`** — match your broker's names exactly (`XAUUSD.r`, `NAS100`,
     `US100.cash` all exist in the wild)
   - `account.login` — the EA refuses to start on the wrong account
   - `risk.ramp.deployment_start` — today's date, to start the ramp at month 1
6. Attach to **one** chart. The EA drives every configured symbol from that
   single instance — a second instance would double the risk budget without
   either knowing about the other.

## Operating

Keyboard shortcuts on the chart:

| Key | Action |
|---|---|
| `S` | print the status line |
| `P` | write prune candidates to the strategy log |
| `K` | clear the kill switch (manual and logged, by design) |

The kill switch does **not** clear at daily rollover. A 5% drawdown is a
campaign-level event that wants a human to look at it.

## Logs

`MQL5/Files/Adaptive/logs/`, one file per stream per day:

| File | Contents |
|---|---|
| `trades_*.csv` | every fill, exit, trail — with strategy, regime, R-multiple |
| `equity_*.csv` | equity, drawdown, open risk, lock/kill state (60s heartbeat) |
| `regime_*.csv` | regime transitions per symbol per timeframe |
| `strategy_*.csv` | enable/disable, suitability scores, trade results |
| `risk_*.csv` | every block, lock, kill and approval |

`risk_*.csv` is the one to read when the EA isn't trading and you think it
should be — every refusal is logged with its reason.

## Backtesting

Populate `Files/Adaptive/calendar.csv` for the test period first. The MQL5
native calendar returns nothing in the Strategy Tester, and the news filter
fails closed — with no calendar it will correctly refuse to trade, and your
backtest will do nothing.

## Known limits

- **No threads.** MQL5 has none; strategies run cooperatively round-robin.
  See ARCHITECTURE.md §7.1.
- The news HTTP API parser is still a stub. The MQL5 native calendar covers
  live trading and the CSV covers the tester, so this only matters if you want
  an external feed.
- **`aggregate_stop_cap_pct` ships at 6%, not the 10% in the brief** — 10%
  of simultaneous stops is an instant account breach. ARCHITECTURE.md §3.
- Strategy parameters are first guesses. Walk-forward them before arming
  (`tools/walkforward.py`), and run `tools/null_test.py` first every time.
- **`momo_pullback`'s shipped defaults are too tight** - one signal in 40,000
  bars. Walk-forward it and take the fitted parameters before enabling.
- Regime thresholds ship as defaults calibrated on neither symbol. Fit them
  per symbol with `tools/calibrate_regime.py` — see docs/CALIBRATION.md.
- **Chop detection is the classifier's weak point.** On the synthetic fixture
  it recovers ~92% of trending bars but names only part of the chop, avoiding
  much of the rest by abstaining. Watch this in observe mode.

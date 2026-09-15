# Getting started — install, test, and run

Written assuming you have never used MetaTrader before. Follow it in order.
Nothing here risks money until Part 5, and Part 5 says to use a demo account.

**Read this first:** this EA is designed to trade rarely. On the validated
strategy it took **281 trades in 17 years of H4 data** — about 16 a year. Most
days it will do nothing. That is the design, not a fault. If you want
constant activity, this is the wrong tool.

---

## Part 1 — Install the files (10 minutes)

### 1.1 Find your MetaTrader data folder

MT5 does **not** keep files where the program is installed. Inside MetaTrader:

**File → Open Data Folder**

A Windows Explorer window opens. Inside it you will see a folder called
`MQL5`. That is your target.

### 1.2 Copy three folders across

From this repository, copy into that `MQL5` folder:

| From this repo | Into your MT5 `MQL5` folder |
|---|---|
| `MQL5/Include/Adaptive` | `Include/Adaptive` |
| `MQL5/Experts/Adaptive` | `Experts/Adaptive` |
| `MQL5/Files/Adaptive` | `Files/Adaptive` |
| `MQL5/Scripts/Adaptive` | `Scripts/Adaptive` (optional, research only) |

Keep the folder names exactly as they are. When you are done you should have
`MQL5/Include/Adaptive/Core/Types.mqh` and
`MQL5/Files/Adaptive/config.json` among others.

### 1.3 Compile

1. In MetaTrader press **F4** — MetaEditor opens.
2. In the Navigator panel on the left, expand **Expert Advisors → Adaptive**.
3. Double-click **AdaptiveEA.mq5**.
4. Press **F7** (or click Compile).

You want to see **0 errors** at the bottom. Warnings are fine.

If you get errors, copy the first one and send it to me — errors usually mean
a folder landed in the wrong place, and the first one tells us which.

---

## Part 2 — Point it at your broker (important)

Open `MQL5/Files/Adaptive/config.json` in any text editor (Notepad is fine).

### 2.1 Your symbol name

Brokers name gold differently: `XAUUSD`, `XAUUSD.r`, `GOLD`, `XAUUSD_i`. Find
yours in the MT5 **Market Watch** panel (Ctrl+M). Then edit:

```json
"symbols": ["XAUUSD"],
```

Change `XAUUSD` to whatever your broker calls it. Also change it in the
strategy block further down:

```json
"symbols": ["XAUUSD"],
```

**If this is wrong the EA refuses to start.** That is deliberate.

### 2.2 Your account number

```json
"account": {
  "login": 70188572,
```

Set this to the account you are actually running on. To use any account,
set `"enforce_login_match": false` — but on a funded account, leave the check on.

### 2.3 Which pip convention your broker uses

```json
"min_target_pips": 10.0,
"pip_size": 1.00
```

`pip_size: 1.00` means 10 pips = **$10.00 of gold movement**. That is the
conservative reading and what was validated. If your broker calls $0.10 a pip,
set `pip_size` to `0.10` — but understand that makes the minimum target $1.00,
which the research shows is **not viable** after costs.

---

## Part 3 — Backtest it (Strategy Tester)

This is how you see it work without risking anything.

### 3.1 One thing you must do first

The news filter **fails closed**: no calendar means no trading, on purpose.
MT5's built-in calendar does **not** work in the Strategy Tester, so without
this step your backtest will correctly do nothing at all.

Either populate `MQL5/Files/Adaptive/calendar.csv` with events covering your
test period (format is in the file), **or**, for a first look only, set:

```json
"news": { "enabled": false,
```

Remember to turn it back on before live.

### 3.2 Run the test

1. In MetaTrader press **Ctrl+R** — the Strategy Tester opens at the bottom.
2. Set:
   - **Expert**: `Adaptive\AdaptiveEA`
   - **Symbol**: your gold symbol
   - **Period**: **H4** (the validated strategy trades H4)
   - **Date**: from 2018 to today
   - **Modelling**: *Open prices only* is fine to start and is much faster
   - **Deposit**: 10000, **Leverage**: whatever your firm gives
3. Click the **Inputs** tab and set **InpAllowLiveTrading = true**.
   *(In the tester this only arms the simulation — no real orders exist.)*
4. Click **Start**.

### 3.3 Reading the result

The **Graph** tab shows the equity curve. The **Results** tab lists trades.

Set your expectations from the research, not from hope:

| What was validated | Value |
|---|---|
| Expectancy | +0.081 R per trade |
| Trades | 281 in 17 years |
| Win rate | 64% |
| Profit factor | 1.22 |
| Worst drawdown | 12.1 R |

At 0.25% risk, 12.1 R of drawdown is about **3% of the account**. A flat
stretch of several months is normal and expected.

**If the tester shows zero trades**, that is usually one of: news filter still
on (see 3.1), wrong symbol name, period not H4, or `InpAllowLiveTrading` still
false. Check the **Journal** tab — the EA prints why it refused to start.

---

## Part 4 — Watch it live without trading (observe mode)

Before any real order, run it on a **demo account** with trading disarmed.

1. Open an **H4 chart** of your gold symbol.
2. Drag **AdaptiveEA** from the Navigator onto that chart.
3. In the dialog, **Common** tab: tick *Allow Algo Trading*.
4. **Inputs** tab: leave **InpAllowLiveTrading = false**. This is the safety.
5. Click OK.

You should see a text panel in the top-left corner of the chart showing equity,
drawdown, the current regime and the strategy state.

Leave it for a week. It will place no orders. Meanwhile it writes everything to
`MQL5/Files/Adaptive/logs/`:

| File | What it tells you |
|---|---|
| `regime_*.csv` | what market condition it thinks we are in |
| `risk_*.csv` | **every refusal and why** — read this one first |
| `strategy_*.csv` | strategy state changes and scores |
| `equity_*.csv` | account heartbeat every 60s |
| `trades_*.csv` | fills and exits |

Open them in Excel. If the regime labels do not match what you see on the
chart, stop and tell me — nothing downstream matters if that is wrong.

**Keyboard shortcuts** (click the chart first): `S` prints status, `P` prints
strategies flagged for review, `K` clears the kill switch after a drawdown halt.

---

## Part 5 — Go live on DEMO

Only after Part 4 looks sane.

Same as Part 4, but set **InpAllowLiveTrading = true**. Use a **demo account**
with the same balance as your funded account.

Run it for at least **two months**. You need to see it take real trades, sit
flat for long periods, and handle a losing run — that is the point of the
exercise.

### Going to the funded account

I am not going to tell you this is ready for your $10,000. The honest position:

- The edge is **+0.081R and borderline** — it passed on expectancy but failed
  the consistency test (positive in 2 of 4 out-of-sample periods).
- The EA knows this. The strategy ships flagged `borderline`, which starts it
  in **PROBATION at half risk** automatically.
- Risk stays at **0.25%** and will not increase until live results earn it.

If you do go live, change nothing except the account number, and watch
`risk_*.csv` daily for the first month.

---

## What protects you

These run whether or not you configure anything:

| Limit | Value | What happens |
|---|---|---|
| Daily lock | −2% | no new trades until server midnight |
| Kill switch | −5% | closes everything, stays flat until you press `K` |
| Per trade | 1% max | hard cap, phase 1 uses 0.25% |
| Sum of open stops | 6% | new trades refused beyond it |
| News blackout | ±60 / ±30 min | flat and no entries |
| No valid edge | — | sits flat rather than forcing a trade |

Your firm's real limits are $400 daily and $1,000 total. Everything above
stops well short of those on purpose.

---

## When something goes wrong

| Symptom | Cause |
|---|---|
| "STARTUP FAILED" in Journal | wrong symbol name or account number in config.json |
| Zero trades in the tester | news filter on with no calendar (3.1), or wrong period |
| Zero trades live | normal — check `risk_*.csv` for the reason |
| "no validated baseline" warning | expected for the disabled strategies |
| Compile errors | a folder is in the wrong place; send me the first error |

The single most useful habit: **when it does not trade, open `risk_*.csv`.**
Every refusal is logged with its reason. It is almost never a bug.

---

## Do not do these

- Do not enable the other strategies. They failed validation.
- Do not raise risk because it is winning. The phase system handles that.
- Do not run two copies on one account — they cannot see each other's risk.
- Do not run it on M5 or M15. Costs eat the edge; the research shows this.
- Do not use it on US100. Nothing here was validated on an index.

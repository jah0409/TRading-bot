# Simple setup guide

No jargon. Do the steps in order. Nothing risks real money until Step 7,
and Step 7 tells you to use fake money first.

---

## How many trades will it take?

**About 1 trade every day and a half.** Roughly **3–4 trades a week**,
**15 a month**, **180 a year**.

Out of every 100 days it can trade:

| | how often |
|---|---|
| no trades that day | 51 days |
| 1 trade | 32 days |
| 2 trades | 14 days |
| 3 trades | 3 days |
| 4–5 trades | 1 day |

So **about half of all days are quiet**. That is normal. Some weeks have none
at all — that happened 34 times in the 11 years I tested.

### Want roughly double?

Two extra strategies are switched off in the settings file. Turn them on and
you get **~1.5 trades a day**, ~8 a week, and only 24% of days are quiet.

**But read this first:** over 11 years those two extras added almost no extra
profit (+4 units) while making the worst losing streak **more than twice as
deep**. They give you more to watch, not more money. Step 6 shows you where
the switch is if you still want it.

---

## What you need

- A Windows PC (MetaTrader 5 works best on Windows)
- MetaTrader 5 installed — free from your broker or `metatrader5.com`
- A **demo account** (fake money). Your broker gives these away free.

Do not use your real account yet.

---

## Step 1 — Download the files

On the GitHub page, click the green **Code** button → **Download ZIP**.

Unzip it. You now have a folder with `MQL5` and `docs` inside.

---

## Step 2 — Find MetaTrader's folder

MetaTrader hides its files somewhere odd. To find it:

1. Open MetaTrader 5
2. Top menu: **File** → **Open Data Folder**
3. A window opens. Double-click the folder called **MQL5**

Leave this window open. This is where the files go.

---

## Step 3 — Copy the files across

From the unzipped download, copy these folders into MetaTrader's `MQL5`
folder. Windows will ask if you want to merge — say **yes**.

| Copy this | Into MetaTrader's MQL5 folder |
|---|---|
| `MQL5\Include\Adaptive` | `Include\` |
| `MQL5\Experts\Adaptive` | `Experts\` |
| `MQL5\Files\Adaptive` | `Files\` |

**Check it worked:** you should be able to open
`MQL5\Files\Adaptive\config.json` in Notepad.

---

## Step 4 — Build it

1. In MetaTrader press **F4**. A second program opens (MetaEditor).
2. On the left, find **Expert Advisors** → **Adaptive** → **AdaptiveEA.mq5**
3. Double-click it
4. Press **F7**

At the bottom you want **"0 errors"**. Warnings are fine — ignore those.

**If you get errors:** a folder is in the wrong place. Copy the first red line
and send it to me.

---

## Step 5 — Tell it your broker's name for gold

Open `MQL5\Files\Adaptive\config.json` in Notepad.

Every broker spells gold differently. Find yours:

- In MetaTrader press **Ctrl+M** to show the Market Watch list
- Look for gold. It might be `XAUUSD`, `XAUUSD.r`, `GOLD`, or `XAUUSD_i`

Now in the file, find every place it says `"XAUUSD"` and change it to exactly
what your broker calls it. Use Ctrl+H (Find and Replace) to get them all.

Also find this line and put your own account number in:

```
"login": 70188572,
```

Don't know your account number? MetaTrader shows it at the top-left, or in
**File → Login to Trade Account**.

Save the file.

---

## Step 6 — (Optional) More trades

Only if you want ~1.5 trades a day instead of ~0.7, and you have read the
warning at the top.

In the same file, search for `liquidity_sweep_h1`. Just below it you will see:

```
"enabled": false,
```

Change `false` to `true`. Do the same for `bos_choch_m30`. Save.

You can always change it back.

---

## Step 7 — Test it on the past

This replays years of old price data so you can watch it trade without money.

1. In MetaTrader press **Ctrl+R**. A panel opens at the bottom.
2. Fill it in:
   - **Expert**: `Adaptive\AdaptiveEA`
   - **Symbol**: your gold name from Step 5
   - **Period**: **H1**
   - **Date**: from 2020 to today
   - **Deposit**: 10000
3. Click the **Inputs** tab. Find `InpAllowLiveTrading` and set it to **true**.
   *(This only affects the test. No real orders can happen here.)*
4. Click **Start**

**One thing that will confuse you:** if the test makes zero trades, it is
almost always the news filter. The EA refuses to trade when it cannot check
for news, and MetaTrader's news list does not work in testing mode. For a
first look only, open `config.json`, find `"news"`, and change
`"enabled": true` to `"enabled": false`. **Turn it back on afterwards.**

When it finishes, click the **Graph** tab to see the money line, or
**Results** to see each trade.

---

## Step 8 — Watch it live, with no trading

Now let it run on live prices but with the trading switch OFF.

1. Open an **H1 chart** of your gold symbol
2. Drag **AdaptiveEA** from the left-hand list onto the chart
3. In the box that appears:
   - **Common** tab: tick **Allow Algo Trading**
   - **Inputs** tab: leave `InpAllowLiveTrading` as **false** ← this is the safety
4. Click OK

You should see text in the top-left corner of the chart. That means it is
running. It will not place any orders.

Leave it for a week. It writes notes about everything it sees into
`MQL5\Files\Adaptive\logs\`. Open those in Excel.

**The one file that matters:** `risk_*.csv`. Every time it decides *not* to
trade, it writes down why. When you think it is broken, look there first. It
is almost never broken — it is usually just waiting.

---

## Step 9 — Demo account with fake money

Same as Step 8, but set `InpAllowLiveTrading` to **true**, on a **demo
account**.

Run it for **two months**. You need to see it take real trades, sit quiet for
days, and lose a few — that is the whole point.

---

## Step 10 — Real money

Only after Step 9 looks sensible, and understand this first:

The edge I measured is **small and not certain**. It passed the tests, but
passing means "I could not prove it wrong", not "this will make money". The EA
knows this — it starts every strategy at **half risk** and only increases if
live results earn it.

If you go ahead, change nothing except the account number.

---

## Safety things that are always on

You do not need to set these up. They just work.

| If this happens | The EA does this |
|---|---|
| You lose 2% in a day | stops trading until tomorrow |
| You lose 5% total | closes everything and stops completely |
| Big news is coming | goes flat, waits an hour |
| Nothing looks good | does nothing at all |
| Any single trade | never risks more than 1% |

Your prop firm's real limits are $400 in a day and $1,000 total. All of the
above stop well before those.

---

## Buttons you can press

Click on the chart first, then press:

| Key | What it does |
|---|---|
| `S` | prints how it is doing |
| `P` | prints which strategies look weak |
| `K` | restarts it after a 5% stop |

---

## When something goes wrong

| What you see | What it means |
|---|---|
| "STARTUP FAILED" | wrong gold name or account number in Step 5 |
| No trades in the test | news filter — see Step 7 |
| No trades live | probably normal. Check `risk_*.csv` |
| Red errors when building | a folder is in the wrong place |

---

## Rules — please do not break these

1. **Do not turn on the other strategies** (the ones marked "superseded").
   They failed testing.
2. **Do not increase the risk setting** because it is winning. It handles that
   itself.
3. **Do not run two copies** on the same account. They cannot see each other
   and you will risk double.
4. **Do not use M5 or M15 charts.** The trading costs eat the profit — I tested
   this and every version lost money.
5. **Do not use it on US100** or anything except gold. It was only tested on gold.
6. **Do not skip the demo.** Two months. Really.

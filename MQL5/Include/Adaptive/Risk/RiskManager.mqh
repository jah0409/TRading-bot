//+------------------------------------------------------------------+
//| RiskManager.mqh - the single gate every trade passes through      |
//|                                                                    |
//| LegionFunding #70188572, $10,000:                                  |
//|   hard breach   $1,000 (10%)   -> never reach it                   |
//|   daily breach  $  400 (4%)    -> never reach it                   |
//|   our kill      $  500 (5% DD) -> flatten + lock                   |
//|   our day lock  $  200 (2%)    -> lock until server rollover       |
//|   per trade     1% of basis    -> hard ceiling per strategy        |
//|   sum of stops  <= 10% basis   -> aggregate exposure cap           |
//|                                                                    |
//| Sizing and the limit arithmetic are IMPLEMENTED (this is the part  |
//| that must not be hand-waved). Correlation modelling is stubbed.    |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_RISKMANAGER_MQH__
#define __ADAPTIVE_RISKMANAGER_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "CorrelationModel.mqh"

//--- per-strategy live exposure ------------------------------------
struct SStrategyExposure
  {
   string            strategy_id;
   int               positions;
   double            risk_money;    // sum of |entry-SL| exposure still at risk
   double            realised_today;
  };

class CRiskManager
  {
private:
   CConfig            *m_cfg;
   CLogger            *m_log;
   CCorrelationModel  *m_corr;

   //--- account state -------------------------------------------------
   double            m_balance;
   double            m_equity;
   double            m_initial_balance;
   double            m_peak_equity;
   double            m_day_start_equity;
   double            m_day_start_balance;
   int               m_current_day;        // day-of-year on the server clock

   //--- derived -------------------------------------------------------
   double            m_day_pnl;
   double            m_day_pnl_pct;
   double            m_dd_initial_pct;
   double            m_dd_peak_pct;
   double            m_effective_dd_pct;

   //--- magic -> strategy id. Attribution MUST key off the magic
   //--- number: some brokers truncate or overwrite order comments,
   //--- and a mis-attributed position means a per-strategy cap that
   //--- silently does not bind.
   long              m_known_magics[];
   string            m_known_ids[];

   //--- exposure ------------------------------------------------------
   double            m_open_risk_money;
   double            m_open_risk_pct;
   int               m_open_positions;
   SStrategyExposure m_exposure[];

   //--- state flags ---------------------------------------------------
   int               m_live_trades;
   int               m_violations_since_phase;
   bool              m_daily_locked;
   bool              m_killed;
   bool              m_flatten_requested;
   ENUM_BLOCK_REASON m_flatten_reason;
   ENUM_RISK_PHASE   m_phase;

   //--- persistence keys so a terminal restart cannot clear a lock ----
   string            GVKey(const string suffix) const
     {
      return StringFormat("ADPT_%I64d_%s", AccountInfoInteger(ACCOUNT_LOGIN), suffix);
     }

   void              PersistState(void)
     {
      GlobalVariableSet(GVKey("peak_equity"), m_peak_equity);
      GlobalVariableSet(GVKey("day_index"),   (double)m_current_day);
      GlobalVariableSet(GVKey("day_start_eq"), m_day_start_equity);
      GlobalVariableSet(GVKey("day_start_bal"), m_day_start_balance);
      GlobalVariableSet(GVKey("daily_locked"), (m_daily_locked ? 1.0 : 0.0));
      GlobalVariableSet(GVKey("killed"),       (m_killed ? 1.0 : 0.0));
     }

   void              RestoreState(void)
     {
      if(GlobalVariableCheck(GVKey("peak_equity")))
         m_peak_equity = GlobalVariableGet(GVKey("peak_equity"));
      if(GlobalVariableCheck(GVKey("day_index")))
         m_current_day = (int)GlobalVariableGet(GVKey("day_index"));
      if(GlobalVariableCheck(GVKey("day_start_eq")))
         m_day_start_equity = GlobalVariableGet(GVKey("day_start_eq"));
      if(GlobalVariableCheck(GVKey("day_start_bal")))
         m_day_start_balance = GlobalVariableGet(GVKey("day_start_bal"));
      if(GlobalVariableCheck(GVKey("daily_locked")))
         m_daily_locked = (GlobalVariableGet(GVKey("daily_locked")) > 0.5);
      if(GlobalVariableCheck(GVKey("killed")))
         m_killed = (GlobalVariableGet(GVKey("killed")) > 0.5);
     }

   int               ServerDayIndex(void) const
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return dt.year * 1000 + dt.day_of_year;
     }

   void              RollDayIfNeeded(void)
     {
      int today = ServerDayIndex();
      if(today == m_current_day)
         return;

      m_current_day       = today;
      m_day_start_equity  = m_equity;
      m_day_start_balance = m_balance;
      m_daily_locked      = false;      // fresh day, fresh daily budget
      //--- NOTE: m_killed is NOT cleared here. A 5% equity drawdown is a
      //--- campaign-level event; only a human clears it (ResetKillSwitch).
      PersistState();

      if(m_log != NULL)
         m_log.Risk("DAY_ROLLOVER", "", "", BLOCK_NONE, 0, 0, 0, 0, m_equity, 0, m_effective_dd_pct,
                    StringFormat("day_start_equity=%.2f day_start_balance=%.2f killed=%d",
                                 m_day_start_equity, m_day_start_balance, (m_killed ? 1 : 0)));
     }

   //--- index into m_exposure[], creating the slot on first use -------
   int               ExposureSlot(const string strategy_id)
     {
      for(int i = 0; i < ArraySize(m_exposure); i++)
         if(m_exposure[i].strategy_id == strategy_id)
            return i;
      int n = ArraySize(m_exposure);
      ArrayResize(m_exposure, n + 1);
      m_exposure[n].strategy_id    = strategy_id;
      m_exposure[n].positions      = 0;
      m_exposure[n].risk_money     = 0.0;
      m_exposure[n].realised_today = 0.0;
      return n;
     }

   //--- money at risk if this position stops out, in account currency
   double            PositionRiskMoney(const string symbol, const ENUM_POSITION_TYPE type,
                                       const double volume, const double open_price,
                                       const double sl) const
     {
      if(sl <= 0.0)
         return volume * 1e9;   // no stop == unbounded; never approvable

      double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tick_value <= 0.0)
         tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size <= 0.0 || tick_value <= 0.0)
         return volume * 1e9;

      //--- a stop already past entry (break-even+) carries no downside
      double adverse = (type == POSITION_TYPE_BUY ? open_price - sl : sl - open_price);
      if(adverse <= 0.0)
         return 0.0;

      return (adverse / tick_size) * tick_value * volume;
     }

   string            IdForMagic(const long magic) const
     {
      for(int i = 0; i < ArraySize(m_known_magics); i++)
         if(m_known_magics[i] == magic)
            return m_known_ids[i];
      return "";
     }

   bool              IsOurMagic(const long magic) const
     {
      long base = m_cfg.Exec().magic_base * 100;
      return (magic >= base && magic < base + 1000);
     }

public:
                     CRiskManager(void) : m_cfg(NULL), m_log(NULL), m_corr(NULL), m_balance(0), m_equity(0),
                                          m_initial_balance(0), m_peak_equity(0),
                                          m_day_start_equity(0), m_day_start_balance(0),
                                          m_current_day(0), m_day_pnl(0), m_day_pnl_pct(0),
                                          m_dd_initial_pct(0), m_dd_peak_pct(0),
                                          m_effective_dd_pct(0), m_open_risk_money(0),
                                          m_open_risk_pct(0), m_open_positions(0),
                                          m_live_trades(0), m_violations_since_phase(0),
                                          m_daily_locked(false), m_killed(false),
                                          m_flatten_requested(false),
                                          m_flatten_reason(BLOCK_NONE), m_phase(PHASE_MONTH_1) {}

   //--- called once per strategy at startup, before any trading
   void              RegisterStrategy(const long magic, const string id)
     {
      if(IdForMagic(magic) != "")
         return;
      int n = ArraySize(m_known_magics);
      ArrayResize(m_known_magics, n + 1);
      ArrayResize(m_known_ids, n + 1);
      m_known_magics[n] = magic;
      m_known_ids[n]    = id;
     }

   bool              Init(CConfig *cfg, CLogger *log, CCorrelationModel *corr = NULL)
     {
      m_cfg  = cfg;
      m_log  = log;
      m_corr = corr;
      if(m_cfg == NULL)
         return false;

      m_balance         = AccountInfoDouble(ACCOUNT_BALANCE);
      m_equity          = AccountInfoDouble(ACCOUNT_EQUITY);
      m_initial_balance = m_cfg.Account().initial_balance;
      m_peak_equity     = MathMax(m_equity, m_initial_balance);
      m_current_day     = ServerDayIndex();
      m_day_start_equity  = m_equity;
      m_day_start_balance = m_balance;

      RestoreState();
      PersistState();
      Update();

      if(m_log != NULL)
         m_log.Risk("RISK_INIT", "", "", BLOCK_NONE, 0, 0, 0, 0, m_equity, m_day_pnl_pct,
                    m_effective_dd_pct,
                    StringFormat("initial=%.2f peak=%.2f hard_floor=%.2f daily_floor=%.2f phase=%d",
                                 m_initial_balance, m_peak_equity, HardFloorEquity(),
                                 DailyFloorEquity(), (int)m_phase));
      return true;
     }

   //+---------------------------------------------------------------+
   //| Absolute lines we must never cross                             |
   //+---------------------------------------------------------------+
   double            HardFloorEquity(void) const
     {
      return m_initial_balance * (1.0 - m_cfg.Account().max_total_loss_pct / 100.0);
     }

   double            DailyFloorEquity(void) const
     {
      double anchor = MathMin(m_day_start_equity, m_day_start_balance);
      return anchor * (1.0 - m_cfg.Account().max_daily_loss_pct / 100.0);
     }

   //--- what we actually size against: never larger than the account
   //--- started with, so drawdown shrinks position size automatically
   double            RiskBasis(void) const
     {
      return MathMin(MathMin(m_balance, m_equity), m_initial_balance);
     }

   //+---------------------------------------------------------------+
   //| Main-loop refresh. Recomputes everything from live account     |
   //| state, then sets the lock / kill flags.                        |
   //+---------------------------------------------------------------+
   void              Update(void)
     {
      m_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_equity  = AccountInfoDouble(ACCOUNT_EQUITY);

      RollDayIfNeeded();

      if(m_equity > m_peak_equity)
         m_peak_equity = m_equity;

      //--- daily P/L measured against the day's opening equity
      m_day_pnl     = m_equity - m_day_start_equity;
      m_day_pnl_pct = (m_day_start_equity > 0.0 ? m_day_pnl / m_day_start_equity * 100.0 : 0.0);

      //--- drawdown, two ways
      m_dd_initial_pct = (m_initial_balance > 0.0
                          ? (m_initial_balance - m_equity) / m_initial_balance * 100.0 : 0.0);
      m_dd_peak_pct    = (m_peak_equity > 0.0
                          ? (m_peak_equity - m_equity) / m_peak_equity * 100.0 : 0.0);

      string basis = m_cfg.Account().drawdown_basis;
      if(basis == "static_initial")      m_effective_dd_pct = m_dd_initial_pct;
      else if(basis == "trailing_peak")  m_effective_dd_pct = m_dd_peak_pct;
      else                               m_effective_dd_pct = MathMax(m_dd_initial_pct, m_dd_peak_pct);

      RecomputeExposure();
      UpdatePhase();

      //--- kill switch: half the max loss, flatten and stay flat -------
      if(!m_killed && m_effective_dd_pct >= m_cfg.Risk().kill_switch_dd_pct)
        {
         m_killed            = true;
         m_flatten_requested = true;
         m_flatten_reason    = BLOCK_KILL_SWITCH;
         PersistState();
         if(m_log != NULL)
            m_log.Risk("KILL_SWITCH", "", "", BLOCK_KILL_SWITCH, 0, 0, 0, 0, m_equity,
                       m_day_pnl_pct, m_effective_dd_pct,
                       StringFormat("dd %.2f%% >= %.2f%% (initial=%.2f peak=%.2f)",
                                    m_effective_dd_pct, m_cfg.Risk().kill_switch_dd_pct,
                                    m_dd_initial_pct, m_dd_peak_pct));
        }

      //--- daily lock: half the daily limit, no new trades today ------
      if(!m_daily_locked && m_day_pnl_pct <= -m_cfg.Risk().daily_lock_loss_pct)
        {
         m_daily_locked = true;
         PersistState();
         if(m_log != NULL)
            m_log.Risk("DAILY_LOCK", "", "", BLOCK_DAILY_LOCK, 0, 0, 0, 0, m_equity,
                       m_day_pnl_pct, m_effective_dd_pct,
                       StringFormat("day pnl %.2f%% <= -%.2f%%",
                                    m_day_pnl_pct, m_cfg.Risk().daily_lock_loss_pct));
        }

      //--- approaching the firm's hard lines: flatten pre-emptively ----
      if(m_equity <= DailyFloorEquity() || m_equity <= HardFloorEquity())
        {
         m_flatten_requested = true;
         m_flatten_reason    = (m_equity <= HardFloorEquity() ? BLOCK_MAX_TOTAL_LOSS : BLOCK_DAILY_LOCK);
         m_daily_locked      = true;
         PersistState();
        }
     }

   //+---------------------------------------------------------------+
   //| Walk live positions and rebuild the exposure table. This is    |
   //| the authoritative "sum of stops" number.                       |
   //+---------------------------------------------------------------+
   void              RecomputeExposure(void)
     {
      for(int i = 0; i < ArraySize(m_exposure); i++)
        {
         m_exposure[i].positions  = 0;
         m_exposure[i].risk_money = 0.0;
        }
      m_open_risk_money = 0.0;
      m_open_positions  = 0;

      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(!IsOurMagic(magic))
            continue;

         string symbol = PositionGetString(POSITION_SYMBOL);
         string comment = PositionGetString(POSITION_COMMENT);
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double volume = PositionGetDouble(POSITION_VOLUME);
         double open   = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl     = PositionGetDouble(POSITION_SL);

         double risk = PositionRiskMoney(symbol, ptype, volume, open, sl);

         //--- magic first; fall back to the comment convention
         //--- "PREFIX|id" only for positions opened before registration
         string sid = IdForMagic(magic);
         if(sid == "")
           {
            sid = comment;
            int bar = StringFind(comment, "|");
            if(bar >= 0)
               sid = StringSubstr(comment, bar + 1);
           }

         int slot = ExposureSlot(sid);
         m_exposure[slot].positions++;
         m_exposure[slot].risk_money += risk;

         m_open_risk_money += risk;
         m_open_positions++;
        }

      double basis = RiskBasis();
      m_open_risk_pct = (basis > 0.0 ? m_open_risk_money / basis * 100.0 : 0.0);
     }

   //+---------------------------------------------------------------+
   //| Risk ramp: month 1 / 2 / 3+                                    |
   //+---------------------------------------------------------------+
   void              UpdatePhase(void)
     {
      datetime start = m_cfg.Risk().deployment_start;
      if(start <= 0)
         start = TimeCurrent();

      double days   = (double)(TimeCurrent() - start) / 86400.0;
      int    months = (int)MathFloor(days / 30.44) + 1;

      ENUM_RISK_PHASE candidate = PHASE_MONTH_1;
      if(months >= 3)      candidate = PHASE_MONTH_3;
      else if(months == 2) candidate = PHASE_MONTH_2;

      //--- Time is a CEILING on the phase, never a reason to reach it.
      //--- Promotion additionally requires: the account up by the
      //--- configured margin, a real sample of live trades, drawdown
      //--- inside tolerance, and no risk violation since the last
      //--- promotion. A strategy set may sit at 0.25% indefinitely -
      //--- that is a correct outcome, not a stalled one.
      if(m_cfg.Risk().phase_auto_advance && candidate > PHASE_MONTH_1)
        {
         double net_pct = (m_initial_balance > 0.0
                           ? (m_balance - m_initial_balance) / m_initial_balance * 100.0 : 0.0);
         bool profitable = (net_pct >= m_cfg.Risk().phase_advance_min_profit_pct);
         bool sampled    = (m_live_trades >= m_cfg.Json_MinTrades());
         bool dd_ok      = (m_effective_dd_pct <= m_cfg.Json_MaxDd());
         bool clean      = (m_violations_since_phase == 0);
         if(!(profitable && sampled && dd_ok && clean))
           {
            candidate = (ENUM_RISK_PHASE)MathMax((int)PHASE_MONTH_1, (int)candidate - 1);
            if(m_log != NULL && candidate < m_phase)
               m_log.Risk("PHASE_HELD", "", "", BLOCK_NONE, 0, 0, 0, 0, m_equity,
                          m_day_pnl_pct, m_effective_dd_pct,
                          StringFormat("profit %.2f%% (need %.2f%%), trades %d (need %d), "
                                       "dd %.2f%% (max %.2f%%), violations %d",
                                       net_pct, m_cfg.Risk().phase_advance_min_profit_pct,
                                       m_live_trades, m_cfg.Json_MinTrades(),
                                       m_effective_dd_pct, m_cfg.Json_MaxDd(),
                                       m_violations_since_phase));
           }
        }

      if(candidate != m_phase)
        {
         if(m_log != NULL)
            m_log.Risk("PHASE_CHANGE", "", "", BLOCK_NONE, 0, 0, 0, 0, m_equity, m_day_pnl_pct,
                       m_effective_dd_pct,
                       StringFormat("phase %d -> %d (months=%d risk=%.2f%% max_strats=%d)",
                                    (int)m_phase, (int)candidate, months,
                                    PhaseRiskPct(candidate), PhaseMaxStrategies(candidate)));
         m_phase = candidate;
        }
     }

   double            PhaseRiskPct(const ENUM_RISK_PHASE p) const
     {
      double pct;
      switch(p)
        {
         case PHASE_MONTH_2: pct = m_cfg.Risk().phase2_risk_pct; break;
         case PHASE_MONTH_3: pct = m_cfg.Risk().phase3_risk_pct; break;
         default:            pct = m_cfg.Risk().phase1_risk_pct; break;
        }
      //--- never above the 1% per-strategy budget, never above firm ceiling
      pct = MathMin(pct, m_cfg.Risk().strategy_max_risk_pct);
      pct = MathMin(pct, m_cfg.Account().firm_max_risk_trade_pct);
      return pct;
     }

   int               PhaseMaxStrategies(const ENUM_RISK_PHASE p) const
     {
      int n;
      switch(p)
        {
         case PHASE_MONTH_2: n = m_cfg.Risk().phase2_max_strategies; break;
         case PHASE_MONTH_3: n = m_cfg.Risk().phase3_max_strategies; break;
         default:            n = m_cfg.Risk().phase1_max_strategies; break;
        }
      return MathMin(n, 5);   // spec: never exceed 5 concurrent strategies
     }

   //+---------------------------------------------------------------+
   //| Position sizing: lots such that a stop-out costs exactly       |
   //| risk_pct of the risk basis, rounded DOWN to the lot step.      |
   //+---------------------------------------------------------------+
   bool              CalcLots(STradeIntent &intent, const double risk_pct, string &err)
     {
      err = "";
      string sym = intent.symbol;

      double stop_dist = MathAbs(intent.entry_price - intent.stop_loss);
      if(intent.stop_loss <= 0.0 || stop_dist <= 0.0)
        {
         err = "missing or zero-distance stop loss";
         return false;
        }

      double tick_size  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tick_value <= 0.0)
         tick_value = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size <= 0.0 || tick_value <= 0.0)
        {
         err = StringFormat("bad tick metrics for %s (size=%.10f value=%.5f)",
                            sym, tick_size, tick_value);
         return false;
        }

      //--- cost of a full stop-out, per 1.00 lot
      double money_per_lot = (stop_dist / tick_size) * tick_value;
      if(money_per_lot <= 0.0)
        {
         err = "non-positive risk per lot";
         return false;
        }

      double basis      = RiskBasis();
      double risk_money = basis * risk_pct / 100.0;

      //--- also cap by remaining headroom to the daily and hard floors,
      //--- so the last trade of a bad day cannot be the breaching one
      double room_daily = MathMax(0.0, m_equity - DailyFloorEquity());
      double room_hard  = MathMax(0.0, m_equity - HardFloorEquity());
      double headroom   = MathMin(room_daily, room_hard) * 0.5;   // never spend >half the room
      if(headroom > 0.0)
         risk_money = MathMin(risk_money, headroom);

      double min_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double max_lot  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
      double lot_step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      if(lot_step <= 0.0)
         lot_step = 0.01;

      double raw  = risk_money / money_per_lot;
      double lots = MathFloor(raw / lot_step) * lot_step;
      lots = MathMin(lots, max_lot);

      //--- rounding artefacts: normalise to the step's decimal count
      int step_digits = (int)MathMax(0, MathCeil(-MathLog10(lot_step)));
      lots = NormalizeDouble(lots, step_digits);

      if(lots < min_lot)
        {
         //--- can we afford the broker's minimum at all?
         double min_risk     = min_lot * money_per_lot;
         double min_risk_pct = (basis > 0.0 ? min_risk / basis * 100.0 : 100.0);
         err = StringFormat("min lot %.2f risks %.2f (%.3f%%) > allowed %.2f (%.3f%%)",
                            min_lot, min_risk, min_risk_pct, risk_money, risk_pct);
         intent.lots       = 0.0;
         intent.risk_money = min_risk;
         intent.risk_pct   = min_risk_pct;
         return false;
        }

      intent.lots       = lots;
      intent.risk_money = lots * money_per_lot;
      intent.risk_pct   = (basis > 0.0 ? intent.risk_money / basis * 100.0 : 0.0);
      return true;
     }

   //+---------------------------------------------------------------+
   //| The gate. Every strategy calls this before every entry.        |
   //+---------------------------------------------------------------+
   SRiskVerdict      Approve(STradeIntent &intent, const SMarketContext &ctx,
                             const double external_risk_mult = 1.0)
     {
      SRiskVerdict v;
      v.approved      = false;
      v.approved_lots = 0.0;
      v.reason        = BLOCK_NONE;
      v.detail        = "";

      //--- 1. global locks --------------------------------------------
      if(m_killed)
        {
         v.reason = BLOCK_KILL_SWITCH;
         v.detail = StringFormat("equity dd %.2f%%", m_effective_dd_pct);
         return Reject(v, intent);
        }
      if(m_daily_locked)
        {
         v.reason = BLOCK_DAILY_LOCK;
         v.detail = StringFormat("day pnl %.2f%%", m_day_pnl_pct);
         return Reject(v, intent);
        }

      //--- 2. news blackout -------------------------------------------
      if(ctx.news_blackout)
        {
         v.reason = BLOCK_NEWS_BLACKOUT;
         v.detail = ctx.news_label;
         return Reject(v, intent);
        }

      //--- 3. a stop is not optional ----------------------------------
      if(m_cfg.Risk().require_stop_loss && intent.stop_loss <= 0.0)
        {
         v.reason = BLOCK_INVALID_STOP;
         v.detail = "no stop loss on intent";
         return Reject(v, intent);
        }

      //--- 4. broker minimum stop distance ----------------------------
      double stop_dist_pts = MathAbs(intent.entry_price - intent.stop_loss) / ctx.point;
      if(ctx.stops_level_points > 0 && stop_dist_pts < (double)ctx.stops_level_points)
        {
         v.reason = BLOCK_INVALID_STOP;
         v.detail = StringFormat("stop %.0f pts < broker minimum %I64d",
                                 stop_dist_pts, ctx.stops_level_points);
         return Reject(v, intent);
        }

      //--- 4b. a stop closer than a fraction of ATR is noise, not a stop.
      //--- Independent of the strategy-side floor on purpose: this is the
      //--- backstop that makes a tiny-stop/huge-lots trade impossible even
      //--- if a new strategy forgets to apply the floor, and it also covers
      //--- brokers that report SYMBOL_TRADE_STOPS_LEVEL as 0.
      if(ctx.atr_ref > 0.0 && m_cfg.Risk().min_stop_atr_mult > 0.0)
        {
         double min_dist = m_cfg.Risk().min_stop_atr_mult * ctx.atr_ref;
         double dist     = MathAbs(intent.entry_price - intent.stop_loss);
         if(dist < min_dist)
           {
            v.reason = BLOCK_INVALID_STOP;
            v.detail = StringFormat("stop %.5f is %.2f ATR from entry, minimum %.2f",
                                    dist, dist / ctx.atr_ref, m_cfg.Risk().min_stop_atr_mult);
            return Reject(v, intent);
           }
        }

      //--- 5. spread sanity -------------------------------------------
      double max_spread = (StringFind(intent.symbol, "XAU") >= 0
                           ? m_cfg.Risk().max_spread_points_xau
                           : m_cfg.Risk().max_spread_points_idx);
      if(ctx.spread_points > max_spread)
        {
         v.reason = BLOCK_SPREAD;
         v.detail = StringFormat("spread %.0f > max %.0f", ctx.spread_points, max_spread);
         return Reject(v, intent);
        }

      //--- 6. size the trade ------------------------------------------
      //--- external_risk_mult carries the portfolio mode and the
      //--- strategy's health state. It can only ever REDUCE size: the
      //--- phase cap and the 1% per-strategy ceiling still bind above it.
      double risk_pct = PhaseRiskPct(m_phase) * ctx.news_size_mult
                        * MathMax(0.0, MathMin(1.0, external_risk_mult));
      risk_pct = MathMin(risk_pct, m_cfg.Risk().strategy_max_risk_pct);
      if(risk_pct <= 0.0)
        {
         v.reason = BLOCK_TRADE_RISK_CAP;
         v.detail = StringFormat("risk multiplier %.3f leaves no size", external_risk_mult);
         return Reject(v, intent);
        }

      string err = "";
      if(!CalcLots(intent, risk_pct, err))
        {
         v.reason = BLOCK_LOT_TOO_SMALL;
         v.detail = err;
         return Reject(v, intent);
        }

      //--- 7. per-trade ceiling (belt and braces after sizing) --------
      if(intent.risk_pct > m_cfg.Risk().strategy_max_risk_pct + 1e-6)
        {
         v.reason = BLOCK_TRADE_RISK_CAP;
         v.detail = StringFormat("%.3f%% > %.3f%%", intent.risk_pct,
                                 m_cfg.Risk().strategy_max_risk_pct);
         return Reject(v, intent);
        }

      //--- 8. per-strategy budget -------------------------------------
      int slot = ExposureSlot(intent.strategy_id);
      double basis = RiskBasis();
      double strat_risk_pct_after = (basis > 0.0
                                     ? (m_exposure[slot].risk_money + intent.risk_money) / basis * 100.0
                                     : 100.0);
      if(strat_risk_pct_after > m_cfg.Risk().strategy_max_risk_pct + 1e-6)
        {
         v.reason = BLOCK_STRATEGY_RISK_CAP;
         v.detail = StringFormat("strategy open+new %.3f%% > %.3f%%",
                                 strat_risk_pct_after, m_cfg.Risk().strategy_max_risk_pct);
         return Reject(v, intent);
        }
      if(m_exposure[slot].positions >= m_cfg.Risk().max_positions_per_strategy)
        {
         v.reason = BLOCK_MAX_POSITIONS;
         v.detail = StringFormat("strategy already holds %d", m_exposure[slot].positions);
         return Reject(v, intent);
        }

      //--- 9. aggregate sum-of-stops cap ------------------------------
      double agg_pct_after = (basis > 0.0
                              ? (m_open_risk_money + intent.risk_money) / basis * 100.0 : 100.0);
      if(agg_pct_after > m_cfg.Risk().aggregate_stop_cap_pct + 1e-6)
        {
         v.reason = BLOCK_AGGREGATE_STOP_CAP;
         v.detail = StringFormat("open+new %.3f%% > %.3f%%",
                                 agg_pct_after, m_cfg.Risk().aggregate_stop_cap_pct);
         return Reject(v, intent);
        }

      //--- also: the aggregate must not be able to break the day ------
      if(m_open_risk_money + intent.risk_money > MathMax(0.0, m_equity - DailyFloorEquity()))
        {
         v.reason = BLOCK_AGGREGATE_STOP_CAP;
         v.detail = StringFormat("open+new %.2f exceeds room to daily floor %.2f",
                                 m_open_risk_money + intent.risk_money,
                                 m_equity - DailyFloorEquity());
         return Reject(v, intent);
        }

      //--- 10. position counts ----------------------------------------
      if(m_open_positions >= m_cfg.Risk().max_positions_total)
        {
         v.reason = BLOCK_MAX_POSITIONS;
         v.detail = StringFormat("total %d", m_open_positions);
         return Reject(v, intent);
        }
      if(SymbolPositionCount(intent.symbol) >= m_cfg.Risk().max_positions_per_symbol)
        {
         v.reason = BLOCK_MAX_POSITIONS;
         v.detail = StringFormat("symbol %s at cap", intent.symbol);
         return Reject(v, intent);
        }

      //--- 11. correlation-adjusted concentration ----------------------
      //--- This is an ADDITIONAL constraint on top of the absolute
      //--- sum-of-stops cap above, never a relaxation of it: correlation
      //--- describes typical behaviour, and what breaches a prop account
      //--- is the atypical day when everything gaps at once.
      if(!CheckCorrelationCap(intent, v.detail))
        {
         v.reason = BLOCK_CORRELATION;
         return Reject(v, intent);
        }

      //--- 12. margin ---------------------------------------------------
      double margin_required = 0.0;
      if(!OrderCalcMargin(intent.direction, intent.symbol, intent.lots,
                          (intent.direction == ORDER_TYPE_BUY ? ctx.ask : ctx.bid),
                          margin_required))
        {
         v.reason = BLOCK_MARGIN;
         v.detail = StringFormat("OrderCalcMargin failed err=%d", GetLastError());
         return Reject(v, intent);
        }
      double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
      if(margin_required > free_margin * 0.5)   // keep half the free margin spare
        {
         v.reason = BLOCK_MARGIN;
         v.detail = StringFormat("need %.2f, free %.2f", margin_required, free_margin);
         return Reject(v, intent);
        }

      //--- approved -----------------------------------------------------
      v.approved      = true;
      v.approved_lots = intent.lots;
      v.reason        = BLOCK_NONE;
      v.detail        = StringFormat("risk %.2f (%.3f%%) phase=%d agg_after=%.3f%%",
                                     intent.risk_money, intent.risk_pct, (int)m_phase, agg_pct_after);

      if(m_log != NULL)
         m_log.Risk("APPROVE", intent.strategy_id, intent.symbol, BLOCK_NONE,
                    intent.lots, intent.lots, intent.risk_money, intent.risk_pct,
                    m_equity, m_day_pnl_pct, m_effective_dd_pct, v.detail);
      return v;
     }

private:
   SRiskVerdict      Reject(SRiskVerdict &v, const STradeIntent &intent)
     {
      v.approved      = false;
      v.approved_lots = 0.0;
      if(m_log != NULL)
         m_log.Risk("BLOCK", intent.strategy_id, intent.symbol, v.reason,
                    intent.lots, 0.0, intent.risk_money, intent.risk_pct,
                    m_equity, m_day_pnl_pct, m_effective_dd_pct, v.detail);
      return v;
     }

   int               SymbolPositionCount(const string symbol) const
     {
      int n = 0;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0)
            continue;
         if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
            continue;
         if(PositionGetString(POSITION_SYMBOL) == symbol)
            n++;
        }
      return n;
     }

   //+---------------------------------------------------------------+
   //| Correlation-adjusted concentration cap.                        |
   //|                                                                |
   //| Builds the signed risk vector across open positions plus the   |
   //| proposed one, collapses same-symbol exposure, and asks the      |
   //| correlation model for the portfolio risk. Two 1% longs in       |
   //| instruments correlated at 0.8 come out near 1.9%, not 2.0%;     |
   //| a genuine long/short hedge comes out near zero.                 |
   //+---------------------------------------------------------------+
   bool              CheckCorrelationCap(const STradeIntent &intent, string &detail)
     {
      if(m_corr == NULL || !m_corr.Enabled())
         return true;

      //--- one slot per configured symbol; net the signed risk into it
      int nsym = m_cfg.SymbolCount();
      if(nsym <= 0)
         return true;

      string syms[];
      double signed_risk[];
      ArrayResize(syms, nsym);
      ArrayResize(signed_risk, nsym);
      for(int i = 0; i < nsym; i++)
        {
         syms[i] = m_cfg.SymbolAt(i);
         signed_risk[i] = 0.0;
        }

      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !IsOurMagic(PositionGetInteger(POSITION_MAGIC)))
            continue;

         string sym = PositionGetString(POSITION_SYMBOL);
         int slot = -1;
         for(int k = 0; k < nsym; k++)
            if(syms[k] == sym)
              {
               slot = k;
               break;
              }
         if(slot < 0)
            continue;

         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double risk = PositionRiskMoney(sym, ptype,
                                         PositionGetDouble(POSITION_VOLUME),
                                         PositionGetDouble(POSITION_PRICE_OPEN),
                                         PositionGetDouble(POSITION_SL));
         signed_risk[slot] += (ptype == POSITION_TYPE_BUY ? risk : -risk);
        }

      //--- add the trade being proposed
      for(int k = 0; k < nsym; k++)
         if(syms[k] == intent.symbol)
           {
            signed_risk[k] += (intent.direction == ORDER_TYPE_BUY
                               ? intent.risk_money : -intent.risk_money);
            break;
           }

      double basis = RiskBasis();
      if(basis <= 0.0)
         return true;

      double port = m_corr.PortfolioRisk(syms, signed_risk, nsym);
      double pct  = port / basis * 100.0;

      if(pct > m_cfg.Risk().correlation_cap_pct + 1e-6)
        {
         detail = StringFormat("correlation-adjusted concentration %.3f%% > cap %.3f%% [%s]",
                               pct, m_cfg.Risk().correlation_cap_pct, m_corr.Describe());
         return false;
        }
      return true;
     }

public:
   //--- accessors used by the orchestrator and the logger -------------
   bool              IsDailyLocked(void)   const { return m_daily_locked; }
   bool              IsKilled(void)        const { return m_killed; }
   bool              NeedsFlatten(void)    const { return m_flatten_requested; }
   ENUM_BLOCK_REASON FlattenReason(void)   const { return m_flatten_reason; }
   void              ClearFlattenRequest(void)   { m_flatten_requested = false; m_flatten_reason = BLOCK_NONE; }

   double            Equity(void)          const { return m_equity; }
   double            Balance(void)         const { return m_balance; }
   double            DayPnl(void)          const { return m_day_pnl; }
   double            DayPnlPct(void)       const { return m_day_pnl_pct; }
   double            DrawdownPct(void)     const { return m_effective_dd_pct; }
   double            DrawdownInitialPct(void) const { return m_dd_initial_pct; }
   double            DrawdownPeakPct(void) const { return m_dd_peak_pct; }
   double            OpenRiskMoney(void)   const { return m_open_risk_money; }
   double            OpenRiskPct(void)     const { return m_open_risk_pct; }
   int               OpenPositions(void)   const { return m_open_positions; }
   ENUM_RISK_PHASE   Phase(void)           const { return m_phase; }
   double            CurrentRiskPct(void)  const { return PhaseRiskPct(m_phase); }
   int               MaxConcurrentStrategies(void) const { return PhaseMaxStrategies(m_phase); }

   //--- fed by the orchestrator so phase promotion can require evidence
   void              RecordLiveTrade(void)      { m_live_trades++; }
   void              RecordRiskViolation(void)  { m_violations_since_phase++; }
   int               LiveTrades(void)     const { return m_live_trades; }

   //--- deliberate manual intervention only
   void              ResetKillSwitch(const string who)
     {
      m_killed      = false;
      m_peak_equity = MathMax(m_equity, m_initial_balance);
      PersistState();
      if(m_log != NULL)
         m_log.Risk("KILL_RESET", "", "", BLOCK_NONE, 0, 0, 0, 0, m_equity, m_day_pnl_pct,
                    m_effective_dd_pct, "reset by " + who);
     }

   void              LogHeartbeat(void)
     {
      if(m_log == NULL)
         return;
      m_log.Equity(m_balance, m_equity, m_equity - m_balance, m_day_pnl, m_day_pnl_pct,
                   m_dd_initial_pct, m_dd_peak_pct, m_open_positions, m_open_risk_money,
                   m_open_risk_pct, m_daily_locked, m_killed);
     }
  };

#endif // __ADAPTIVE_RISKMANAGER_MQH__

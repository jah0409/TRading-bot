//+------------------------------------------------------------------+
//| Orchestrator.mqh - owns every component and runs the main loop    |
//|                                                                    |
//| ON THREADING: the brief asks for one thread per strategy. MQL5     |
//| does not have threads. An EA is a single-threaded event handler;   |
//| OnTick/OnTimer must return before the next event is delivered, and |
//| there is no way to spawn a worker. What we do instead:             |
//|                                                                    |
//|   * a 5s OnTimer drives a cooperative round-robin over strategies  |
//|   * each pass has a time budget; strategies that do not get their  |
//|     slice go first on the next pass (m_rotation), so no strategy   |
//|     can be starved by one that sits ahead of it                    |
//|   * per-bar work is gated by IsNewBar(), so the per-pass cost is   |
//|     a handful of CopyBuffer calls, not a full recompute            |
//|                                                                    |
//| This gives concurrency in the sense that matters - every strategy  |
//| is evaluated every few seconds against fresh data - without        |
//| pretending to a parallelism the platform cannot deliver. If you    |
//| genuinely need OS threads, the EA has to become a bridge to an     |
//| external process; see ARCHITECTURE.md "Threading".                 |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_ORCHESTRATOR_MQH__
#define __ADAPTIVE_ORCHESTRATOR_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "../Regime/RegimeDetector.mqh"
#include "../Risk/RiskManager.mqh"
#include "../Risk/CorrelationModel.mqh"
#include "../Risk/PortfolioState.mqh"
#include "TradeGate.mqh"
#include "../News/NewsFilter.mqh"
#include "../Execution/OrderExecutor.mqh"
#include "../Portfolio/PerformanceTracker.mqh"
#include "../Portfolio/StrategyAllocator.mqh"
#include "../Strategies/StrategyFactory.mqh"

//--- a fill we have sent but not yet seen come back as a deal -------
struct SPendingFill
  {
   string            strategy_id;
   string            symbol;
   long              magic;
   double            risk_money;
   ENUM_REGIME       regime;
   datetime          ts;
   bool              active;
  };

class COrchestrator
  {
private:
   CConfig              m_cfg;
   CLogger              m_log;
   CRegimeDetector      m_regime;
   CRiskManager         m_risk;
   CCorrelationModel    m_corr;
   CNewsFilter          m_news;
   COrderExecutor       m_exec;
   CPerformanceTracker  m_perf;
   CStrategyAllocator   m_alloc;
   CPortfolioState      m_portfolio;
   CTradeGate           m_gate;

   CStrategyBase       *m_strategies[];

   bool                 m_ready;
   int                  m_rotation;        // round-robin cursor
   uint                 m_pass_budget_ms;
   datetime             m_last_heartbeat;

   //--- pending fills waiting to be bound to a position id
   SPendingFill         m_pending[];

   void                 QueuePending(const STradeIntent &intent, const ENUM_REGIME regime)
     {
      int slot = -1;
      for(int i = 0; i < ArraySize(m_pending); i++)
         if(!m_pending[i].active)
           {
            slot = i;
            break;
           }
      if(slot < 0)
        {
         slot = ArraySize(m_pending);
         ArrayResize(m_pending, slot + 1);
        }
      m_pending[slot].strategy_id = intent.strategy_id;
      m_pending[slot].symbol      = intent.symbol;
      m_pending[slot].magic       = intent.magic;
      m_pending[slot].risk_money  = intent.risk_money;
      m_pending[slot].regime      = regime;
      m_pending[slot].ts          = TimeCurrent();
      m_pending[slot].active      = true;
     }

   bool                 TakePending(const string symbol, const long magic, SPendingFill &out)
     {
      //--- oldest match wins
      int best = -1;
      for(int i = 0; i < ArraySize(m_pending); i++)
        {
         if(!m_pending[i].active)
            continue;
         if(m_pending[i].symbol != symbol || m_pending[i].magic != magic)
            continue;
         if(best < 0 || m_pending[i].ts < m_pending[best].ts)
            best = i;
        }
      if(best < 0)
         return false;
      out = m_pending[best];
      m_pending[best].active = false;
      return true;
     }

   CStrategyBase       *FindByMagic(const long magic)
     {
      for(int i = 0; i < ArraySize(m_strategies); i++)
         if(m_strategies[i].Magic() == magic)
            return m_strategies[i];
      return NULL;
     }

   //+---------------------------------------------------------------+
   //| Assemble everything a strategy needs to make a decision.       |
   //+---------------------------------------------------------------+
   bool                 BuildContext(const string symbol, SMarketContext &ctx)
     {
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick))
         return false;

      ctx.symbol = symbol;
      ctx.now    = TimeCurrent();
      ctx.bid    = tick.bid;
      ctx.ask    = tick.ask;
      ctx.point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
      ctx.digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      ctx.spread_points = (ctx.point > 0.0 ? (tick.ask - tick.bid) / ctx.point : 0.0);
      ctx.tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      ctx.tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      ctx.min_lot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      ctx.max_lot    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      ctx.lot_step   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      ctx.stops_level_points = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

      ctx.phase              = m_risk.Phase();
      ctx.risk_pct_per_trade = m_risk.CurrentRiskPct();

      SNewsState ns = m_news.Evaluate(symbol);
      ctx.news_blackout  = ns.blackout;
      ctx.news_caution   = ns.caution;
      ctx.news_size_mult = ns.size_mult;
      ctx.news_stop_mult = ns.stop_mult;
      ctx.news_label     = ns.label;

      if(!m_regime.Snapshot(symbol, ctx.regime))
         return false;

      //--- H1 ATR is the reference for stop-distance sanity checks; fall
      //--- back down the timeframes while the H1 indicator is still warming
      ctx.atr_ref = ctx.regime.tf[TF_SLOT_H1].atr;
      if(ctx.atr_ref <= 0.0)
         ctx.atr_ref = ctx.regime.tf[TF_SLOT_M15].atr;
      if(ctx.atr_ref <= 0.0)
         ctx.atr_ref = ctx.regime.tf[TF_SLOT_H4].atr;

      return true;
     }

   //--- close only the positions on one symbol (news blackout is
   //--- per-symbol; the kill switch is account-wide)
   int                  CloseSymbol(const string symbol, const string reason)
     {
      long base = m_cfg.Exec().magic_base * 100;
      int closed = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic < base || magic >= base + 1000)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != symbol)
            continue;
         if(m_exec.ClosePosition(ticket, 1.0, reason))
            closed++;
        }
      return closed;
     }

   //--- floating P/L for one strategy, for its virtual account
   double               FloatingFor(const long magic) const
     {
      double sum = 0.0;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != magic)
            continue;
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      return sum;
     }

public:
                     COrchestrator(void) : m_ready(false), m_rotation(0),
                                           m_pass_budget_ms(3000), m_last_heartbeat(0) {}

                    ~COrchestrator(void) { Shutdown(); }

   bool              IsReady(void) const { return m_ready; }
   CConfig          *Config(void)        { return GetPointer(m_cfg); }
   CRiskManager     *Risk(void)          { return GetPointer(m_risk); }
   CLogger          *Log(void)           { return GetPointer(m_log); }

   //+---------------------------------------------------------------+
   //| Startup. Any failure here leaves m_ready false and the EA      |
   //| refuses to trade - on a funded account that is the only        |
   //| acceptable behaviour.                                          |
   //+---------------------------------------------------------------+
   bool              Startup(const string config_path, const bool log_to_terminal)
     {
      m_log.Configure("Adaptive\\logs", true, log_to_terminal);
      m_log.Init(StringFormat("%I64d", AccountInfoInteger(ACCOUNT_LOGIN)));

      //--- 1. config ----------------------------------------------------
      if(!m_cfg.Load(config_path))
        {
         m_log.Warn("config load failed: " + m_cfg.LastError());
         return false;
        }

      string problems = "";
      bool valid = m_cfg.Validate(problems);
      if(problems != "")
         m_log.Warn("config validation: " + problems);
      if(!valid)
        {
         m_log.Warn("REFUSING TO TRADE - fix config.json and reload");
         return false;
        }

      //--- 2. components -------------------------------------------------
      //--- correlation first: the risk manager holds a pointer to it
      m_corr.Init(GetPointer(m_cfg), GetPointer(m_log));

      if(!m_risk.Init(GetPointer(m_cfg), GetPointer(m_log), GetPointer(m_corr)))
        {
         m_log.Warn("risk manager init failed");
         return false;
        }
      if(!m_exec.Init(GetPointer(m_cfg), GetPointer(m_log)))
        {
         m_log.Warn("executor init failed");
         return false;
        }
      if(!m_regime.Init(GetPointer(m_cfg), GetPointer(m_log)))
        {
         m_log.Warn("regime detector init failed");
         return false;
        }
      if(!m_news.Init(GetPointer(m_cfg), GetPointer(m_log)))
        {
         m_log.Warn("news filter init failed");
         return false;
        }
      m_perf.Init(GetPointer(m_log),
                  m_cfg.Json().GetInt("performance.confidence_trades", 20),
                  m_cfg.Json().GetDouble("performance.max_suitability_adjust", 0.5));
      m_alloc.Init(GetPointer(m_cfg), GetPointer(m_log), GetPointer(m_perf));
      m_portfolio.Init(GetPointer(m_cfg), GetPointer(m_log));
      m_gate.Init(GetPointer(m_cfg), GetPointer(m_log));

      //--- 3. strategies -------------------------------------------------
      int n = m_cfg.StrategyCount();
      ArrayResize(m_strategies, 0);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);

      for(int i = 0; i < n; i++)
        {
         SStrategyConfig sc;
         if(!m_cfg.StrategyAt(i, sc))
            continue;
         if(!sc.enabled)
           {
            m_log.Info(StringFormat("strategy '%s' disabled in config, skipped", sc.id));
            continue;
           }

         CStrategyBase *s = CStrategyFactory::Create(sc.type);
         if(s == NULL)
           {
            m_log.Warn(StringFormat("unknown strategy type '%s' for id '%s' (known: %s)",
                                    sc.type, sc.id, CStrategyFactory::KnownTypes()));
            continue;
           }

         s.Bind(sc, GetPointer(m_cfg), GetPointer(m_log), GetPointer(m_risk),
                GetPointer(m_exec), equity * sc.capital_weight);

         if(!s.OnInit())
           {
            m_log.Warn(StringFormat("strategy '%s' OnInit failed - not loaded", sc.id));
            delete s;
            continue;
           }

         int k = ArraySize(m_strategies);
         ArrayResize(m_strategies, k + 1);
         m_strategies[k] = s;
         m_perf.Register(sc.id);
         m_risk.RegisterStrategy(sc.magic, sc.id);

         //--- the validated baseline from walk-forward. A strategy with no
         //--- baseline, or one whose evidence tier never cleared the floor,
         //--- starts on PROBATION rather than ACTIVE.
         SBaseline bl;
         string bp = sc.json_path + ".baseline";
         bl.expectancy_r  = m_cfg.Json().GetDouble(bp + ".expectancy_r", 0.0);
         bl.profit_factor = m_cfg.Json().GetDouble(bp + ".profit_factor", 0.0);
         bl.win_rate      = m_cfg.Json().GetDouble(bp + ".win_rate", 0.0);
         bl.max_dd_r      = m_cfg.Json().GetDouble(bp + ".max_dd_r", 0.0);
         bl.sample_trades = m_cfg.Json().GetInt(bp + ".sample_trades", 0);
         bl.evidence_tier = m_cfg.Json().GetString(bp + ".evidence", "INSUFFICIENT");
         bl.valid         = m_cfg.Json().Exists(bp) && bl.expectancy_r > 0.0;
         s.Health().Init(sc.id, GetPointer(m_cfg), GetPointer(m_log), bl);

         if(!bl.valid)
            m_log.Warn(StringFormat("strategy '%s' has no validated baseline - "
                                    "starting on PROBATION at reduced risk", sc.id));

         m_log.Info(StringFormat("loaded strategy '%s' (%s) magic=%I64d symbols=%s",
                                 sc.id, sc.type, sc.magic, sc.symbols_csv));
        }

      if(ArraySize(m_strategies) == 0)
        {
         m_log.Warn("no strategies loaded - nothing to do");
         return false;
        }

      m_pass_budget_ms = (uint)m_cfg.Json().GetInt("execution.pass_budget_ms", 3000);
      m_ready = true;

      m_log.Info(StringFormat("ready: %d strategies, %d symbols, phase=%d, risk=%.2f%%/trade, "
                              "max concurrent=%d, news feed=%s, corr=%s",
                              ArraySize(m_strategies), m_cfg.SymbolCount(),
                              (int)m_risk.Phase(), m_risk.CurrentRiskPct(),
                              m_risk.MaxConcurrentStrategies(), m_news.FeedSource(),
                              (m_corr.Enabled() ? m_corr.Describe() : "off")));
      return true;
     }

   void              Shutdown(void)
     {
      for(int i = 0; i < ArraySize(m_strategies); i++)
        {
         if(m_strategies[i] == NULL)
            continue;
         m_strategies[i].OnDeinit();
         delete m_strategies[i];
         m_strategies[i] = NULL;
        }
      ArrayResize(m_strategies, 0);
      m_regime.Release();
      m_ready = false;
     }

   //+===============================================================+
   //| THE MAIN LOOP - called from OnTimer every main_loop_seconds   |
   //+===============================================================+
   void              OnTimerCycle(void)
     {
      if(!m_ready)
         return;

      uint pass_start = GetTickCount();

      //--- 1. account state and the hard limits ------------------------
      m_risk.Update();

      //--- 2. calendar and correlation (both self-rate-limiting) -------
      m_news.Refresh(false);
      m_corr.Update(false);

      //--- 3. kill switch / floor breach: flatten before anything else -
      if(m_risk.NeedsFlatten())
        {
         int closed = m_exec.CloseAll("RISK:" + BlockReasonToString(m_risk.FlattenReason()));
         m_risk.ClearFlattenRequest();
         m_risk.RecomputeExposure();
         if(closed > 0)
            m_log.Info(StringFormat("flattened %d positions on risk event", closed));
        }

      //--- 4. per symbol -----------------------------------------------
      //--- reset the distinct-strategy counter so the phase cap is
      //--- enforced across every symbol, not once per symbol
      m_alloc.BeginCycle();

      //--- portfolio posture, recomputed every pass -------------------
      UpdatePortfolioState();

      bool budget_spent = false;

      for(int si = 0; si < m_cfg.SymbolCount() && !budget_spent; si++)
        {
         string symbol = m_cfg.SymbolAt(si);

         //--- regime first: everything downstream depends on it
         SRegimeSnapshot snap;
         if(!m_regime.Evaluate(symbol, snap))
            continue;

         SMarketContext ctx;
         if(!BuildContext(symbol, ctx))
            continue;

         //--- news blackout: flat and no entries -----------------------
         if(ctx.news_blackout)
           {
            if(m_cfg.News().close_positions_on_blackout)
              {
               int closed = CloseSymbol(symbol, "NEWS:" + ctx.news_label);
               if(closed > 0)
                  m_log.Risk("NEWS_FLATTEN", "", symbol, BLOCK_NEWS_BLACKOUT, 0, 0, 0, 0,
                             m_risk.Equity(), m_risk.DayPnlPct(), m_risk.DrawdownPct(),
                             StringFormat("closed %d: %s", closed, ctx.news_label));
              }
            continue;   // no management, no entries, until the window passes
           }

         //--- who is allowed to trade this regime ----------------------
         m_alloc.Allocate(m_strategies, snap, m_risk.MaxConcurrentStrategies(),
                          m_risk.Balance());

         //--- 5. round-robin over strategies ---------------------------
         int n = ArraySize(m_strategies);
         for(int k = 0; k < n; k++)
           {
            int idx = (m_rotation + k) % n;
            CStrategyBase *s = m_strategies[idx];
            if(s == NULL || !s.TradesSymbol(symbol))
               continue;

            //--- management runs even for disabled strategies: a strategy
            //--- that just lost its slot still owns open positions and
            //--- must be allowed to exit and trail them.
            s.ManagePositions(ctx);

            if(s.IsEnabledFor(symbol))
              {
               //--- THE GATE. Fifteen mandatory checks before the strategy
               //--- is even asked for a signal.
               SGateResult g = m_gate.Check(s.Id(), ctx, GetPointer(m_risk),
                                            GetPointer(m_portfolio), s.Health(),
                                            s.Suitability(), s.MinSuitability());
               if(g.passed)
                 {
                  s.SetRiskMultiplier(g.risk_multiplier);
                  if(s.TryEnter(ctx))
                    {
                     STradeIntent filled;
                     if(s.ConsumeLastEntry(filled))
                        QueuePending(filled, snap.composite);
                     m_risk.RecomputeExposure();
                    }
                 }
              }

            //--- cooperative yield: hand the remaining strategies the
            //--- head of the queue next pass rather than starving them
            if(GetTickCount() - pass_start > m_pass_budget_ms)
              {
               m_rotation   = (idx + 1) % n;
               budget_spent = true;   // stop the symbol loop too, not just this one
               m_log.Info(StringFormat("pass budget %ums exceeded; resuming at strategy %d",
                                       m_pass_budget_ms, m_rotation));
               break;
              }
           }
        }

      //--- 6. mark virtual accounts to market --------------------------
      for(int i = 0; i < ArraySize(m_strategies); i++)
         m_strategies[i].Account().MarkToMarket(FloatingFor(m_strategies[i].Magic()));

      //--- 7. heartbeat ------------------------------------------------
      if(TimeCurrent() - m_last_heartbeat >= 60)
        {
         m_risk.LogHeartbeat();
         m_last_heartbeat = TimeCurrent();
        }

      //--- advance the rotation one step on a clean pass. If the budget
      //--- was spent, m_rotation already points at the first strategy
      //--- that missed its slice - do not skip past it.
      if(!budget_spent && ArraySize(m_strategies) > 0)
         m_rotation = (m_rotation + 1) % ArraySize(m_strategies);
     }

   //+---------------------------------------------------------------+
   //| Count strategy health across the book and set the portfolio     |
   //| mode. This is where "several strategies failing at once" gets   |
   //| separated from "one strategy stopped working": the first is a   |
   //| statement about the MARKET and the response is to stop, not to  |
   //| rotate into a fourth way to lose.                               |
   //+---------------------------------------------------------------+
   void              UpdatePortfolioState(void)
     {
      int total = ArraySize(m_strategies);
      int degraded = 0, cooling = 0, eligible = 0;
      bool abnormal = false, spread_bad = false;

      for(int i = 0; i < total; i++)
        {
         CStrategyHealth *h = m_strategies[i].Health();
         ENUM_STRATEGY_STATE st = h.State();
         if(st == STATE_PROBATION || st == STATE_REDUCED_RISK)
            degraded++;
         if(st == STATE_COOL_DOWN || st == STATE_DISABLED)
            cooling++;
         if(h.CanTrade() && m_strategies[i].IsEnabled())
            eligible++;
        }

      //--- market-level sanity, across every traded symbol
      for(int si = 0; si < m_cfg.SymbolCount(); si++)
        {
         string sym = m_cfg.SymbolAt(si);
         SRegimeSnapshot snap;
         if(m_regime.Snapshot(sym, snap))
           {
            for(int t = 0; t < TF_SLOT_COUNT; t++)
               if(snap.tf[t].atr_expansion > m_cfg.Json().GetDouble(
                     "regime.abnormal_atr_expansion", 3.0))
                  abnormal = true;
           }
         MqlTick tk;
         if(SymbolInfoTick(sym, tk))
           {
            double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
            double spread_pts = (pt > 0 ? (tk.ask - tk.bid) / pt : 0);
            double cap = (StringFind(sym, "XAU") >= 0
                          ? m_cfg.Risk().max_spread_points_xau
                          : m_cfg.Risk().max_spread_points_idx);
            if(spread_pts > cap * 2.0)
               spread_bad = true;
           }
        }

      m_portfolio.Update(total, degraded, cooling, eligible,
                         m_risk.DrawdownPct(), abnormal, spread_bad);

      //--- MARKET_UNSAFE is not a pause on new entries only: reduce the
      //--- book as well, because the exposure already on is the problem.
      if(m_portfolio.Mode() == MODE_MARKET_UNSAFE &&
         m_cfg.Json().GetBool("portfolio.flatten_when_unsafe", false))
        {
         int closed = m_exec.CloseAll("MARKET_UNSAFE:" + m_portfolio.Reason());
         if(closed > 0)
            m_log.Risk("UNSAFE_FLATTEN", "", "", BLOCK_NONE, 0, 0, 0, 0,
                       m_risk.Equity(), m_risk.DayPnlPct(), m_risk.DrawdownPct(),
                       StringFormat("closed %d: %s", closed, m_portfolio.Reason()));
        }
     }

   //+---------------------------------------------------------------+
   //| Tick handler: trailing only. Deliberately cheap - the 5s timer |
   //| does the thinking, this just keeps stops current between       |
   //| passes so a fast move does not run past an unmoved stop.       |
   //+---------------------------------------------------------------+
   void              OnTickCycle(void)
     {
      if(!m_ready || !m_cfg.Exec().trade_on_tick_trailing)
         return;
      if(m_risk.IsKilled())
         return;

      for(int si = 0; si < m_cfg.SymbolCount(); si++)
        {
         string symbol = m_cfg.SymbolAt(si);

         //--- cheap pre-check: skip symbols with nothing open
         bool any = false;
         long base = m_cfg.Exec().magic_base * 100;
         for(int i = 0; i < PositionsTotal(); i++)
           {
            ulong t = PositionGetTicket(i);
            if(t == 0)
               continue;
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic >= base && magic < base + 1000 &&
               PositionGetString(POSITION_SYMBOL) == symbol)
              {
               any = true;
               break;
              }
           }
         if(!any)
            continue;

         SMarketContext ctx;
         if(!BuildContext(symbol, ctx))
            continue;

         for(int i = 0; i < ArraySize(m_strategies); i++)
           {
            CStrategyBase *s = m_strategies[i];
            if(s == NULL || !s.TradesSymbol(symbol))
               continue;
            s.ManagePositions(ctx);
           }
        }
     }

   //+---------------------------------------------------------------+
   //| Attribute fills and closes back to strategies.                 |
   //|                                                                |
   //| Binding is by (symbol, magic) against the pending queue rather |
   //| than by ticket, because a netting account merges deals into    |
   //| one position and the order ticket is not the position id.      |
   //+---------------------------------------------------------------+
   void              OnTradeTransactionEvent(const MqlTradeTransaction &trans,
                                             const MqlTradeRequest &request,
                                             const MqlTradeResult &result)
     {
      if(!m_ready || trans.type != TRADE_TRANSACTION_DEAL_ADD)
         return;

      ulong deal = trans.deal;
      if(!HistoryDealSelect(deal))
        {
         //--- the deal may not be in the cache yet
         HistorySelect(TimeCurrent() - 600, TimeCurrent() + 60);
         if(!HistoryDealSelect(deal))
            return;
        }

      long   magic  = HistoryDealGetInteger(deal, DEAL_MAGIC);
      string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
      ulong  posid  = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);

      CStrategyBase *s = FindByMagic(magic);
      if(s == NULL)
         return;   // not ours

      if(entry == DEAL_ENTRY_IN)
        {
         SPendingFill pf;
         if(TakePending(symbol, magic, pf))
            m_perf.OnTradeOpened(posid, pf.strategy_id, symbol, pf.regime, pf.risk_money);
         else
           {
            //--- no pending record (restart mid-trade): fall back to the
            //--- live regime and the position's own stop distance
            SRegimeSnapshot snap;
            ENUM_REGIME r = (m_regime.Snapshot(symbol, snap) ? snap.composite : REGIME_UNKNOWN);
            m_perf.OnTradeOpened(posid, s.Id(), symbol, r, 0.0);
           }
         return;
        }

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
        {
         double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT)
                      + HistoryDealGetDouble(deal, DEAL_SWAP)
                      + HistoryDealGetDouble(deal, DEAL_COMMISSION);

         string     sid;
         ENUM_REGIME regime;
         double     r_mult = 0.0, risk = 0.0;

         if(m_perf.OnTradeClosed(posid, pnl, sid, regime, r_mult, risk))
           {
            s.Account().RecordClosedTrade(pnl, risk);
            SPerfStats st = s.Account().Stats();

            m_log.Trade("CLOSED", sid, symbol, magic, posid, "", 0,
                        HistoryDealGetDouble(deal, DEAL_PRICE), 0, 0,
                        risk, 0, r_mult, pnl, RegimeToString(regime),
                        (int)m_risk.Phase(), "", "attributed");

            m_log.Strategy(sid, symbol, "TRADE_RESULT", s.IsEnabled(), s.Suitability(),
                           s.BaseSuitability(regime),
                           m_perf.SuitabilityAdjustment(sid, regime),
                           RegimeToString(regime), s.Account().Equity(),
                           s.Account().DrawdownPct(), st.trades, st.win_rate,
                           st.expectancy_r, StringFormat("pnl=%.2f r=%.2f", pnl, r_mult));
           }
         else
           {
            //--- unattributed close: still record the money
            s.Account().RecordClosedTrade(pnl, 0.0);
           }

         m_risk.RecomputeExposure();
        }
     }

   //+---------------------------------------------------------------+
   //| Operator-facing summary, printed on demand.                    |
   //+---------------------------------------------------------------+
   string            StatusLine(void)
     {
      string s = StringFormat(
                    "eq=%.2f day=%.2f%% dd=%.2f%% openRisk=%.2f%% pos=%d phase=%d "
                    "risk=%.2f%% lock=%s kill=%s news=%s | ",
                    m_risk.Equity(), m_risk.DayPnlPct(), m_risk.DrawdownPct(),
                    m_risk.OpenRiskPct(), m_risk.OpenPositions(), (int)m_risk.Phase(),
                    m_risk.CurrentRiskPct(),
                    (m_risk.IsDailyLocked() ? "YES" : "no"),
                    (m_risk.IsKilled() ? "YES" : "no"),
                    (m_news.FeedOk() ? m_news.FeedSource() : "STALE"));

      if(m_corr.Enabled())
         s += "corr[" + m_corr.Describe() + "] ";

      for(int i = 0; i < ArraySize(m_strategies); i++)
        {
         CStrategyBase *st = m_strategies[i];
         s += StringFormat("%s[%s %.2f] ", st.Id(),
                           (st.IsEnabled() ? "on" : "off"), st.Suitability());
        }
      return s;
     }

   //--- report strategies that have earned a review
   void              ReportPruneCandidates(void)
     {
      int    min_trades = m_cfg.Json().GetInt("performance.prune_min_trades", 40);
      double min_exp    = m_cfg.Json().GetDouble("performance.prune_min_expectancy_r", 0.0);

      for(int i = 0; i < ArraySize(m_strategies); i++)
        {
         string why = "";
         if(m_perf.IsPruneCandidate(m_strategies[i].Id(), min_trades, min_exp, why))
            m_log.Strategy(m_strategies[i].Id(), "", "PRUNE_CANDIDATE",
                           m_strategies[i].IsEnabled(), m_strategies[i].Suitability(),
                           0, 0, "", m_strategies[i].Account().Equity(),
                           m_strategies[i].Account().DrawdownPct(), 0, 0, 0, why);
        }
     }
  };

#endif // __ADAPTIVE_ORCHESTRATOR_MQH__

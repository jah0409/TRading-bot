//+------------------------------------------------------------------+
//| StrategyBase.mqh - the contract every strategy implements         |
//|                                                                    |
//| Lifecycle, in the order the orchestrator calls them:               |
//|                                                                    |
//|   OnInit(cfg,...)        once, create indicator handles here       |
//|   Filter(ctx)            cheap veto: is this market tradable?      |
//|   Entry(ctx, signal)     produce a signal WITH a stop, or nothing  |
//|   ManagePositions(ctx)   -> Exit() and TrailStop() per position    |
//|   OnDeinit()             release handles                           |
//|                                                                    |
//| Rules a subclass must honour:                                      |
//|  * Entry() NEVER sizes a position. It returns a price and a stop;  |
//|    the risk manager owns lots. A strategy cannot overspend.        |
//|  * Entry() MUST set stop_loss. A signal without one is discarded.  |
//|  * Two or three indicators. Not more. If you need a fourth, you    |
//|    are building a curve fit, not a strategy.                       |
//|  * No strategy calls OrderSend. Execution goes through the         |
//|    executor so attribution and logging stay intact.                |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_STRATEGYBASE_MQH__
#define __ADAPTIVE_STRATEGYBASE_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "../Risk/RiskManager.mqh"
#include "../Execution/OrderExecutor.mqh"
#include "../Portfolio/VirtualAccount.mqh"

class CStrategyBase
  {
protected:
   string            m_id;
   string            m_type;
   long              m_magic;
   string            m_json_path;       // where my params live in config.json
   string            m_symbols_csv;     // which symbols I am allowed to trade

   CConfig          *m_cfg;
   CLogger          *m_log;
   CRiskManager     *m_risk;
   COrderExecutor   *m_exec;
   CVirtualAccount   m_account;

   //--- Enablement is PER SYMBOL: XAUUSD can be trending while US100
   //--- ranges, so one global flag would let the second symbol's regime
   //--- silently overwrite the first's decision.
   bool              m_enabled;         // enabled on at least one symbol
   string            m_en_symbols[8];
   bool              m_en_flags[8];
   int               m_en_count;
   double            m_suitability;     // current score for the live regime
   double            m_base_suitability[6];
   double            m_min_suitability;

   //--- new-bar detection, per symbol (index matches config order)
   datetime          m_last_bar[8];

   //--- the last entry we actually sent, so the orchestrator can bind
   //--- it to the resulting position id when the deal arrives
   STradeIntent      m_last_entry;
   bool              m_last_entry_ok;

   //--- convenience: read one of my own params
   double            ParamD(const string key, const double def) const
     {
      return m_cfg.Json().GetDouble(m_json_path + ".params." + key, def);
     }
   int               ParamI(const string key, const int def) const
     {
      return m_cfg.Json().GetInt(m_json_path + ".params." + key, def);
     }
   string            ParamS(const string key, const string def) const
     {
      return m_cfg.Json().GetString(m_json_path + ".params." + key, def);
     }
   bool              ParamB(const string key, const bool def) const
     {
      return m_cfg.Json().GetBool(m_json_path + ".params." + key, def);
     }

   //--- has a new bar closed on this symbol/timeframe since last call?
   bool              IsNewBar(const string symbol, const ENUM_TIMEFRAMES tf, const int slot)
     {
      if(slot < 0 || slot >= 8)
         return true;
      datetime t = iTime(symbol, tf, 0);
      if(t == 0 || t == m_last_bar[slot])
         return false;
      m_last_bar[slot] = t;
      return true;
     }

   //--- the subset of configured symbols this strategy may trade.
   //--- Every subclass builds its indicator handle arrays against this
   //--- list, so index i in m_syms matches index i in every handle array.
   int               BuildSymbolList(string &out[]) const
     {
      ArrayResize(out, 0);
      for(int i = 0; i < m_cfg.SymbolCount(); i++)
        {
         string sym = m_cfg.SymbolAt(i);
         if(!TradesSymbol(sym))
            continue;
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = sym;
        }
      return ArraySize(out);
     }

   static int        IndexOfSymbol(const string &list[], const string symbol)
     {
      for(int i = 0; i < ArraySize(list); i++)
         if(list[i] == symbol)
            return i;
      return -1;
     }

   //--- ATR on the strategy's working timeframe, for stop placement
   double            AtrValue(const int handle, const int shift = 1) const
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(handle, 0, 0, shift + 2, buf) < shift + 1)
         return 0.0;
      return buf[shift];
     }

public:
                     CStrategyBase(void) : m_id(""), m_type(""), m_magic(0), m_json_path(""),
                                           m_symbols_csv(""), m_cfg(NULL), m_log(NULL),
                                           m_risk(NULL), m_exec(NULL), m_last_entry_ok(false),
                                           m_enabled(false), m_en_count(0), m_suitability(0.0),
                                           m_min_suitability(0.5)
     {
      ArrayInitialize(m_last_bar, 0);
      ArrayInitialize(m_base_suitability, 0.0);
      for(int i = 0; i < 8; i++)
        {
         m_en_symbols[i] = "";
         m_en_flags[i]   = false;
        }
     }

   virtual          ~CStrategyBase(void) {}

   //--- identity -----------------------------------------------------
   string            Id(void)          const { return m_id; }
   string            Type(void)        const { return m_type; }
   long              Magic(void)       const { return m_magic; }
   bool              IsEnabled(void)   const { return m_enabled; }

   void              SetEnabledFor(const string symbol, const bool e)
     {
      int slot = -1;
      for(int i = 0; i < m_en_count; i++)
         if(m_en_symbols[i] == symbol)
           {
            slot = i;
            break;
           }
      if(slot < 0)
        {
         if(m_en_count >= 8)
            return;
         slot = m_en_count++;
         m_en_symbols[slot] = symbol;
        }
      m_en_flags[slot] = e;

      //--- m_enabled is the OR across symbols, for status and logging
      m_enabled = false;
      for(int i = 0; i < m_en_count; i++)
         if(m_en_flags[i])
           {
            m_enabled = true;
            break;
           }
     }

   bool              IsEnabledFor(const string symbol) const
     {
      for(int i = 0; i < m_en_count; i++)
         if(m_en_symbols[i] == symbol)
            return m_en_flags[i];
      return false;
     }
   double            Suitability(void) const { return m_suitability; }
   void              SetSuitability(const double s) { m_suitability = s; }
   double            MinSuitability(void) const { return m_min_suitability; }
   CVirtualAccount  *Account(void)           { return GetPointer(m_account); }

   //--- read-and-clear: the orchestrator takes this immediately after a
   //--- successful TryEnter() so it can attribute the fill
   bool              ConsumeLastEntry(STradeIntent &out)
     {
      if(!m_last_entry_ok)
         return false;
      out = m_last_entry;
      m_last_entry_ok = false;
      return true;
     }

   double            BaseSuitability(const ENUM_REGIME r) const
     {
      int i = (int)r;
      return (i >= 0 && i < 6 ? m_base_suitability[i] : 0.0);
     }

   bool              TradesSymbol(const string symbol) const
     {
      return (StringFind("," + m_symbols_csv + ",", "," + symbol + ",") >= 0);
     }

   //+---------------------------------------------------------------+
   //| Wiring. Called once by the factory before OnInit().            |
   //+---------------------------------------------------------------+
   void              Bind(const SStrategyConfig &sc, CConfig *cfg, CLogger *log,
                          CRiskManager *risk, COrderExecutor *exec, const double allocation)
     {
      m_id           = sc.id;
      m_type         = sc.type;
      m_magic        = sc.magic;
      m_json_path    = sc.json_path;
      m_symbols_csv  = sc.symbols_csv;
      m_min_suitability = sc.min_suitability_to_run;
      for(int i = 0; i < 6; i++)
         m_base_suitability[i] = sc.suitability[i];

      m_cfg  = cfg;
      m_log  = log;
      m_risk = risk;
      m_exec = exec;
      m_account.Init(sc.id, sc.magic, allocation);
     }

   //+===============================================================+
   //| THE CONTRACT - subclasses override these four                 |
   //+===============================================================+

   //--- one-off setup: indicator handles, buffers
   virtual bool      OnInit(void) { return true; }

   //--- release handles
   virtual void      OnDeinit(void) {}

   //--- cheap veto. Return false to skip Entry() entirely this pass.
   //--- Session windows, spread, minimum ATR, "do I even like this
   //--- symbol right now" checks belong here.
   virtual bool      Filter(const SMarketContext &ctx) { return false; }

   //--- produce an entry signal, or leave signal.valid = false.
   //--- MUST populate stop_loss when valid.
   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal) { return false; }

   //--- should this open position be closed on strategy grounds?
   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";
      return d;
     }

   //--- return the new stop for this position, or 0 to leave it alone
   virtual double    TrailStop(const SMarketContext &ctx, const ulong ticket) { return 0.0; }

   //+===============================================================+
   //| Shared machinery - normally NOT overridden                    |
   //+===============================================================+

   //--- walk my open positions, applying Exit() then TrailStop()
   virtual void      ManagePositions(const SMarketContext &ctx)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != ctx.symbol)
            continue;

         //--- exits win over trailing
         SExitDecision d = Exit(ctx, ticket);
         if(d.should_exit)
           {
            m_exec.ClosePosition(ticket, d.fraction, m_id + ":" + d.reason);
            continue;
           }

         double new_sl = TrailStop(ctx, ticket);
         if(new_sl > 0.0)
            m_exec.ModifyStop(ticket, new_sl, m_id + ":trail");
        }
     }

   //+---------------------------------------------------------------+
   //| The full entry path: Filter -> Entry -> risk gate -> execute.  |
   //| Every strategy goes through here, so there is exactly one      |
   //| place where a trade can be born.                               |
   //+---------------------------------------------------------------+
   virtual bool      TryEnter(const SMarketContext &ctx)
     {
      if(!IsEnabledFor(ctx.symbol) || !TradesSymbol(ctx.symbol))
         return false;

      //--- news blackout is checked here AND in the risk manager.
      //--- Belt and braces: this saves the indicator work.
      if(ctx.news_blackout)
         return false;

      if(!Filter(ctx))
         return false;

      SEntrySignal sig;
      sig.valid       = false;
      sig.entry_price = 0.0;
      sig.stop_loss   = 0.0;
      sig.take_profit = 0.0;
      sig.confidence  = 0.0;
      sig.reason      = "";

      if(!Entry(ctx, sig) || !sig.valid)
         return false;

      //--- a signal without a stop is a bug, not a trade
      if(sig.stop_loss <= 0.0)
        {
         if(m_log != NULL)
            m_log.Warn(StringFormat("%s produced a signal with no stop loss - discarded", m_id));
         return false;
        }

      //--- Floor the stop distance. A strategy that anchors its stop to a
      //--- LEVEL (a Bollinger band, a channel midpoint) while filling at
      //--- MARKET can have the two collide when price runs past that level:
      //--- the stop lands on top of the entry, risk collapses toward zero,
      //--- and CalcLots then sizes an enormous position off a stop that the
      //--- spread alone will take out. Walk-forward measured 29% of
      //--- mean-reversion signals under 0.5 ATR and 1% on the wrong side
      //--- entirely. Fixed here, centrally, so every strategy inherits it.
      {
       double entry_px = (sig.entry_price > 0.0 ? sig.entry_price
                          : (sig.direction == ORDER_TYPE_BUY ? ctx.ask : ctx.bid));
       double min_dist = m_cfg.Risk().min_stop_atr_mult * ctx.atr_ref;
       if(min_dist > 0.0)
         {
          bool   is_buy = (sig.direction == ORDER_TYPE_BUY);
          double signed_dist = (is_buy ? entry_px - sig.stop_loss : sig.stop_loss - entry_px);
          if(signed_dist < min_dist)
            {
             double fixed = (is_buy ? entry_px - min_dist : entry_px + min_dist);
             if(m_log != NULL && signed_dist <= 0.0)
                m_log.Warn(StringFormat("%s %s: stop was on the wrong side of entry "
                                        "(%.5f vs %.5f); pushed to %.5f",
                                        m_id, ctx.symbol, sig.stop_loss, entry_px, fixed));
             sig.stop_loss = fixed;
            }
         }
      }

      //--- widen the stop when volatility is expected (news caution)
      if(ctx.news_stop_mult > 1.0)
        {
         double entry = (sig.entry_price > 0.0 ? sig.entry_price
                         : (sig.direction == ORDER_TYPE_BUY ? ctx.ask : ctx.bid));
         double dist  = MathAbs(entry - sig.stop_loss) * ctx.news_stop_mult;
         sig.stop_loss = (sig.direction == ORDER_TYPE_BUY ? entry - dist : entry + dist);
        }

      STradeIntent intent;
      intent.symbol      = ctx.symbol;
      intent.strategy_id = m_id;
      intent.magic       = m_magic;
      intent.direction   = sig.direction;
      intent.entry_price = (sig.entry_price > 0.0 ? sig.entry_price
                            : (sig.direction == ORDER_TYPE_BUY ? ctx.ask : ctx.bid));
      intent.stop_loss   = sig.stop_loss;
      intent.take_profit = sig.take_profit;
      intent.lots        = 0.0;
      intent.risk_money  = 0.0;
      intent.risk_pct    = 0.0;

      //--- THE GATE. Nothing reaches the broker without passing here.
      SRiskVerdict v = m_risk.Approve(intent, ctx);
      if(!v.approved)
         return false;

      ulong ticket = m_exec.OpenMarket(intent, m_id + ":" + sig.reason);
      if(ticket == 0)
         return false;

      m_last_entry    = intent;
      m_last_entry_ok = true;
      return true;
     }
  };

#endif // __ADAPTIVE_STRATEGYBASE_MQH__

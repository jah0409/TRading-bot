//+------------------------------------------------------------------+
//| PortfolioStrategies.mqh - the rest of the validated portfolio     |
//|                                                                    |
//| MQL5 mirrors of the strategies_v2 classes that survived            |
//| walk-forward alongside bos_choch. Each one trades on its OWN       |
//| timeframe, set by timeframe_minutes in config.json, which is how   |
//| the same class serves both the H1 and H4 entries in the portfolio. |
//|                                                                    |
//| All four follow the same contract as every other strategy: return  |
//| a price and a stop, never a size. The risk manager owns sizing.    |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_PORTFOLIOSTRATEGIES_MQH__
#define __ADAPTIVE_PORTFOLIOSTRATEGIES_MQH__

#include "StrategyBase.mqh"
#include "StructureTools.mqh"

//--- shared plumbing: per-symbol ATR handle + a working timeframe ----
class CTfStrategyBase : public CStrategyBase
  {
protected:
   string            m_syms[];
   int               m_h_atr[];
   ENUM_TIMEFRAMES   m_tf;
   int               m_swing_k;
   int               m_lookback;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   ENUM_TIMEFRAMES   ResolveTf(const int minutes) const
     {
      if(minutes >= 240) return PERIOD_H4;
      if(minutes >= 60)  return PERIOD_H1;
      if(minutes >= 30)  return PERIOD_M30;
      if(minutes >= 15)  return PERIOD_M15;
      return PERIOD_M5;
     }

   bool              InitCommon(const int default_tf_minutes)
     {
      m_tf       = ResolveTf(ParamI("timeframe_minutes", default_tf_minutes));
      m_swing_k  = ParamI("swing_k", 3);
      m_lookback = ParamI("structure_lookback", 200);

      int n = BuildSymbolList(m_syms);
      ArrayResize(m_h_atr, n);
      for(int k = 0; k < n; k++)
        {
         m_h_atr[k] = iATR(m_syms[k], m_tf, 14);
         if(m_h_atr[k] == INVALID_HANDLE)
           {
            m_log.Warn(StringFormat("%s: ATR handle failed for %s", m_id, m_syms[k]));
            return false;
           }
        }
      return true;
     }

   //--- the minimum-target rule, applied to the trail as well as entry
   double            MinTargetPrice(void) const
     {
      return m_cfg.Json().GetDouble("risk.min_target_pips", 0.0) *
             m_cfg.Json().GetDouble("risk.pip_size", 1.0);
     }

public:
   virtual void      OnDeinit(void)
     {
      for(int i = 0; i < ArraySize(m_syms); i++)
         IndicatorRelease(m_h_atr[i]);
     }

   //--- ATR trail, armed only once past 1 ATR AND past the minimum
   virtual double    TrailStop(const SMarketContext &ctx, const ulong ticket)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0 || !PositionSelectByTicket(ticket))
         return 0.0;
      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return 0.0;

      double mult  = ParamD("trail_atr", 2.0);
      double min_t = MinTargetPrice();
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);

      if(ptype == POSITION_TYPE_BUY)
        {
         double moved = ctx.bid - open;
         if(moved < atr || moved < min_t)
            return 0.0;
         return MathMax(ctx.bid - mult * atr, open + min_t);
        }
      double moved = open - ctx.ask;
      if(moved < atr || moved < min_t)
         return 0.0;
      return MathMin(ctx.ask + mult * atr, open - min_t);
     }
  };

//+------------------------------------------------------------------+
//| Trend continuation - BOS in the direction of an established trend |
//+------------------------------------------------------------------+
class CTrendContinuation : public CTfStrategyBase
  {
public:
   virtual bool      OnInit(void) { return InitCommon(240); }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_TREND_UP && ctx.regime.composite != REGIME_TREND_DOWN)
         return false;
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      if(ctx.regime.tf[TF_SLOT_H1].adx < ParamD("min_adx", 22.0)) return false;
      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0) return false;

      SStructure s;
      if(!BuildStructure(ctx.symbol, m_tf, m_swing_k, 1, m_lookback, s))
         return false;

      double stop_atr = ParamD("stop_atr", 1.5);
      double rr       = ParamD("rr", 2.0);

      if(ctx.regime.composite == REGIME_TREND_UP && s.bos_up)
        {
         double atr_stop = ctx.ask - stop_atr * atr;
         double stop = (s.swing_low > 0.0 ? MathMin(s.swing_low, atr_stop) : atr_stop);
         if(stop >= ctx.ask) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask; signal.stop_loss = stop;
         signal.take_profit = ctx.ask + rr * (ctx.ask - stop);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = "BOS up in uptrend";
         return true;
        }
      if(ctx.regime.composite == REGIME_TREND_DOWN && s.bos_down)
        {
         double atr_stop = ctx.bid + stop_atr * atr;
         double stop = (s.swing_high > 0.0 ? MathMax(s.swing_high, atr_stop) : atr_stop);
         if(stop <= ctx.bid) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid; signal.stop_loss = stop;
         signal.take_profit = ctx.bid - rr * (stop - ctx.bid);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = "BOS down in downtrend";
         return true;
        }
      return false;
     }

   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d; d.should_exit = false; d.fraction = 1.0; d.reason = "";
      if(!PositionSelectByTicket(ticket)) return d;
      SStructure s;
      if(!BuildStructure(ctx.symbol, m_tf, m_swing_k, ParamI("window", 6), m_lookback, s))
         return d;
      ENUM_POSITION_TYPE p = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(p == POSITION_TYPE_BUY  && s.choch_down_recent) { d.should_exit = true; d.reason = "choch_against"; }
      if(p == POSITION_TYPE_SELL && s.choch_up_recent)   { d.should_exit = true; d.reason = "choch_against"; }
      return d;
     }
  };

//+------------------------------------------------------------------+
//| Previous day high/low reaction - rejection at the level           |
//+------------------------------------------------------------------+
class CPdhPdlReaction : public CTfStrategyBase
  {
public:
   virtual bool      OnInit(void) { return InitCommon(60); }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite == REGIME_CHOP_HIVOL || ctx.regime.composite == REGIME_UNKNOWN)
         return false;
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0) return false;

      double pdh, pdl;
      if(!PreviousDayLevels(ctx.symbol, pdh, pdl))
         return false;

      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(ctx.symbol, m_tf, 0, 3, r) < 2) return false;

      double tol      = ParamD("touch_atr", 0.3) * atr;
      double stop_atr = ParamD("stop_atr", 1.0);
      double rr       = ParamD("rr", 2.0);

      //--- tagged the level but closed back inside, with a rejection wick
      if(r[1].high >= pdh - tol && r[1].close < pdh && RejectionBear(ctx.symbol, m_tf))
        {
         double stop = pdh + stop_atr * atr;
         if(stop <= ctx.bid) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid; signal.stop_loss = stop;
         signal.take_profit = ctx.bid - rr * (stop - ctx.bid);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = StringFormat("rejection at PDH %.2f", pdh);
         return true;
        }
      if(r[1].low <= pdl + tol && r[1].close > pdl && RejectionBull(ctx.symbol, m_tf))
        {
         double stop = pdl - stop_atr * atr;
         if(stop >= ctx.ask) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask; signal.stop_loss = stop;
         signal.take_profit = ctx.ask + rr * (ctx.ask - stop);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = StringFormat("rejection at PDL %.2f", pdl);
         return true;
        }
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Session breakout - London breaks the Asian range with force       |
//+------------------------------------------------------------------+
class CSessionBreakout : public CTfStrategyBase
  {
public:
   virtual bool      OnInit(void) { return InitCommon(240); }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite == REGIME_CHOP_HIVOL || ctx.regime.composite == REGIME_UNKNOWN)
         return false;
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;

      //--- only in the hours after the London open, on the server clock
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      int from = ParamI("london_from_hour", 10);
      int to   = ParamI("london_to_hour", 18);
      if(t.hour < from || t.hour >= to) return false;

      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0) return false;

      double ahi, alo;
      if(!AsianRange(ctx.symbol, m_tf, ParamI("asian_from_hour", 1),
                     ParamI("asian_to_hour", 9), ahi, alo))
         return false;

      int dir = 0;
      if(!Displacement(ctx.symbol, m_tf, atr, ParamD("disp_atr", 1.2),
                       ParamD("body_frac", 0.55), dir))
         return false;

      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(ctx.symbol, m_tf, 0, 3, r) < 2) return false;

      double stop_atr = ParamD("stop_atr", 1.5);
      double rr       = ParamD("rr", 2.0);

      if(dir > 0 && r[1].close > ahi)
        {
         double stop = MathMax(alo, ctx.ask - stop_atr * atr);
         if(stop >= ctx.ask) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask; signal.stop_loss = stop;
         signal.take_profit = ctx.ask + rr * (ctx.ask - stop);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = StringFormat("break of Asian high %.2f", ahi);
         return true;
        }
      if(dir < 0 && r[1].close < alo)
        {
         double stop = MathMin(ahi, ctx.bid + stop_atr * atr);
         if(stop <= ctx.bid) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid; signal.stop_loss = stop;
         signal.take_profit = ctx.bid - rr * (stop - ctx.bid);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = StringFormat("break of Asian low %.2f", alo);
         return true;
        }
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Liquidity sweep reversal - the stop raid that fails               |
//+------------------------------------------------------------------+
class CLiquiditySweepRev : public CTfStrategyBase
  {
public:
   virtual bool      OnInit(void) { return InitCommon(60); }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite == REGIME_UNKNOWN) return false;
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0) return false;
      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0) return false;

      SStructure s;
      if(!BuildStructure(ctx.symbol, m_tf, m_swing_k, 1, m_lookback, s))
         return false;

      double pdh, pdl;
      PreviousDayLevels(ctx.symbol, pdh, pdl);

      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(ctx.symbol, m_tf, 0, 3, r) < 2) return false;

      double stop_atr = ParamD("stop_atr", 1.0);
      double rr       = ParamD("rr", 2.5);
      bool   need_rej = (ParamI("require_reject", 1) != 0);

      //--- wick through a level, close back on the origin side
      bool swept_hi = ((s.swing_high > 0.0 && r[1].high > s.swing_high && r[1].close < s.swing_high) ||
                       (pdh > 0.0 && r[1].high > pdh && r[1].close < pdh));
      bool swept_lo = ((s.swing_low > 0.0 && r[1].low < s.swing_low && r[1].close > s.swing_low) ||
                       (pdl > 0.0 && r[1].low < pdl && r[1].close > pdl));
      if(need_rej)
        {
         swept_hi = swept_hi && RejectionBear(ctx.symbol, m_tf);
         swept_lo = swept_lo && RejectionBull(ctx.symbol, m_tf);
        }

      if(swept_hi)
        {
         double stop = r[1].high + stop_atr * atr;
         if(stop <= ctx.bid) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid; signal.stop_loss = stop;
         signal.take_profit = ctx.bid - rr * (stop - ctx.bid);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = "sweep of highs, closed back inside";
         return true;
        }
      if(swept_lo)
        {
         double stop = r[1].low - stop_atr * atr;
         if(stop >= ctx.ask) return false;
         signal.valid = true; signal.direction = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask; signal.stop_loss = stop;
         signal.take_profit = ctx.ask + rr * (ctx.ask - stop);
         signal.confidence = ctx.regime.composite_conf;
         signal.reason = "sweep of lows, closed back inside";
         return true;
        }
      return false;
     }
  };

#endif // __ADAPTIVE_PORTFOLIOSTRATEGIES_MQH__

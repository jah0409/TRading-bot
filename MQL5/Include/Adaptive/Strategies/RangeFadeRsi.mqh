//+------------------------------------------------------------------+
//| RangeFadeRsi.mqh - fade RSI extremes inside a session range       |
//| Indicators: RSI(2) fast, ATR  -> 2                                |
//| Home regime: RANGE (and, cautiously, CHOP_HIVOL with a wide stop) |
//|                                                                    |
//| This is the deliberately different one: a very fast RSI, a hard    |
//| time-based exit, and no trailing. It exists to cover the days      |
//| when nothing trends and the band-fade strategy sits on its hands.  |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_RANGEFADERSI_MQH__
#define __ADAPTIVE_RANGEFADERSI_MQH__

#include "StrategyBase.mqh"

class CRangeFadeRsi : public CStrategyBase
  {
private:
   string            m_syms[];
   int               m_h_rsi[];
   int               m_h_atr[];

   int               m_rsi_period;
   double            m_rsi_low;
   double            m_rsi_high;
   double            m_stop_atr_mult;
   double            m_target_atr_mult;
   int               m_max_hold_bars;
   ENUM_TIMEFRAMES   m_tf;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   double            Rsi(const int idx, const int shift) const
     {
      double r[];
      ArraySetAsSeries(r, true);
      if(CopyBuffer(m_h_rsi[idx], 0, 0, shift + 2, r) < shift + 1)
         return 50.0;
      return r[shift];
     }

public:
   virtual bool      OnInit(void)
     {
      m_tf              = (ParamI("timeframe_minutes", 15) == 60 ? PERIOD_H1 : PERIOD_M15);
      m_rsi_period      = ParamI("rsi_period", 2);
      m_rsi_low         = ParamD("rsi_low", 10.0);
      m_rsi_high        = ParamD("rsi_high", 90.0);
      m_stop_atr_mult   = ParamD("stop_atr_mult", 2.0);
      m_target_atr_mult = ParamD("target_atr_mult", 1.0);
      m_max_hold_bars   = ParamI("max_hold_bars", 8);

      int n = BuildSymbolList(m_syms);
      ArrayResize(m_h_rsi, n);
      ArrayResize(m_h_atr, n);
      for(int k = 0; k < n; k++)
        {
         m_h_rsi[k] = iRSI(m_syms[k], m_tf, m_rsi_period, PRICE_CLOSE);
         m_h_atr[k] = iATR(m_syms[k], m_tf, 14);
         if(m_h_rsi[k] == INVALID_HANDLE || m_h_atr[k] == INVALID_HANDLE)
           {
            m_log.Warn(StringFormat("%s: handle creation failed for %s", m_id, m_syms[k]));
            return false;
           }
        }
      return true;
     }

   virtual void      OnDeinit(void)
     {
      for(int i = 0; i < ArraySize(m_syms); i++)
        {
         IndicatorRelease(m_h_rsi[i]);
         IndicatorRelease(m_h_atr[i]);
        }
     }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_RANGE && ctx.regime.composite != REGIME_CHOP_HIVOL)
         return false;
      //--- never fade into a higher-timeframe trend
      if(ctx.regime.tf[TF_SLOT_H4].regime == REGIME_TREND_UP ||
         ctx.regime.tf[TF_SLOT_H4].regime == REGIME_TREND_DOWN)
         return false;

      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;
      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return false;

      double rsi = Rsi(idx, 1);

      //--- widen the stop when the regime is the nasty one
      double stop_mult = m_stop_atr_mult;
      if(ctx.regime.composite == REGIME_CHOP_HIVOL)
         stop_mult *= 1.5;

      //--- === TUNE ME === RSI(2) below 10 / above 90 is a short-horizon
      //--- exhaustion read. Fast, noisy, and only viable with the hard
      //--- time stop below.
      if(rsi <= m_rsi_low)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask;
         signal.stop_loss   = ctx.ask - stop_mult * atr;
         signal.take_profit = ctx.ask + m_target_atr_mult * atr;
         signal.confidence  = ctx.regime.composite_conf * 0.8;  // lowest-conviction strategy
         signal.reason      = StringFormat("rsi%d=%.1f oversold", m_rsi_period, rsi);
         return true;
        }

      if(rsi >= m_rsi_high)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid;
         signal.stop_loss   = ctx.bid + stop_mult * atr;
         signal.take_profit = ctx.bid - m_target_atr_mult * atr;
         signal.confidence  = ctx.regime.composite_conf * 0.8;
         signal.reason      = StringFormat("rsi%d=%.1f overbought", m_rsi_period, rsi);
         return true;
        }

      return false;
     }

   //--- the hard time stop is this strategy's real risk control
   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";

      if(!PositionSelectByTicket(ticket))
         return d;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int bar_seconds = PeriodSeconds(m_tf);
      if(bar_seconds <= 0)
         return d;

      int bars_held = (int)((TimeCurrent() - opened) / bar_seconds);
      if(bars_held >= m_max_hold_bars)
        {
         d.should_exit = true;
         d.reason      = StringFormat("time_stop_%d_bars", bars_held);
         return d;
        }

      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return d;

      //--- mean reverted back to neutral: take it
      double rsi = Rsi(idx, 1);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype == POSITION_TYPE_BUY && rsi >= 50.0)
        {
         d.should_exit = true;
         d.reason      = "rsi_normalised";
        }
      if(ptype == POSITION_TYPE_SELL && rsi <= 50.0)
        {
         d.should_exit = true;
         d.reason      = "rsi_normalised";
        }
      return d;
     }

   //--- no trailing by design: a fast fade trailed is a fast loss
   virtual double    TrailStop(const SMarketContext &ctx, const ulong ticket) { return 0.0; }
  };

#endif // __ADAPTIVE_RANGEFADERSI_MQH__

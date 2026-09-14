//+------------------------------------------------------------------+
//| BreakoutDonchian.mqh - trade the break of an N-bar range          |
//| Indicators: Donchian channel (from rates), ATR  -> 2              |
//| Home regime: BREAKOUT                                             |
//| Stop: mid-channel, or ATR multiple, whichever is nearer           |
//| Exit: close back inside the channel (failed break)                |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_BREAKOUTDONCHIAN_MQH__
#define __ADAPTIVE_BREAKOUTDONCHIAN_MQH__

#include "StrategyBase.mqh"

class CBreakoutDonchian : public CStrategyBase
  {
private:
   string            m_syms[];
   int               m_h_atr[];

   int               m_channel_bars;
   double            m_atr_stop_mult;
   double            m_trail_atr_mult;
   double            m_min_atr_percentile;  // do not trade a dead-quiet break
   ENUM_TIMEFRAMES   m_tf;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   //--- Donchian has no built-in indicator; compute it from rates.
   //--- Excludes the forming bar so the level cannot move under us.
   bool              Channel(const string symbol, double &hi, double &lo) const
     {
      int ih = iHighest(symbol, m_tf, MODE_HIGH, m_channel_bars, 1);
      int il = iLowest(symbol, m_tf, MODE_LOW, m_channel_bars, 1);
      if(ih < 0 || il < 0)
         return false;
      hi = iHigh(symbol, m_tf, ih);
      lo = iLow(symbol, m_tf, il);
      return (hi > 0.0 && lo > 0.0 && hi > lo);
     }

public:
   virtual bool      OnInit(void)
     {
      m_tf                 = (ParamI("timeframe_minutes", 15) == 60 ? PERIOD_H1 : PERIOD_M15);
      m_channel_bars       = ParamI("channel_bars", 20);
      m_atr_stop_mult      = ParamD("atr_stop_mult", 1.5);
      m_trail_atr_mult     = ParamD("trail_atr_mult", 2.0);
      m_min_atr_percentile = ParamD("min_atr_percentile", 0.60);

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

   virtual void      OnDeinit(void)
     {
      for(int i = 0; i < ArraySize(m_syms); i++)
         IndicatorRelease(m_h_atr[i]);
     }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      //--- a breakout is worth taking out of a range too (the coil that
      //--- has not yet been recognised as a breakout), but never in
      //--- directionless high volatility - that is where fakeouts live.
      if(ctx.regime.composite != REGIME_BREAKOUT && ctx.regime.composite != REGIME_RANGE)
         return false;
      if(ctx.regime.composite == REGIME_CHOP_HIVOL)
         return false;

      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;

      //--- the break needs real volatility behind it
      if(ctx.regime.tf[TF_SLOT_M15].atr_percentile < m_min_atr_percentile)
         return false;

      return IsNewBar(ctx.symbol, m_tf, idx);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;

      double hi, lo;
      if(!Channel(ctx.symbol, hi, lo))
         return false;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return false;

      double close = iClose(ctx.symbol, m_tf, 1);
      double mid   = (hi + lo) / 2.0;

      //--- === TUNE ME === require a CLOSE beyond the channel, not just
      //--- a wick through it. Wick-triggered breakout entries are the
      //--- classic way to donate money to the market.
      if(close > hi)
        {
         double stop_atr = ctx.ask - m_atr_stop_mult * atr;
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask;
         signal.stop_loss   = MathMax(stop_atr, mid);   // nearer of the two
         signal.take_profit = 0.0;                      // let the trail run
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("close>%d-bar high %.5f", m_channel_bars, hi);
         return true;
        }

      if(close < lo)
        {
         double stop_atr = ctx.bid + m_atr_stop_mult * atr;
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid;
         signal.stop_loss   = MathMin(stop_atr, mid);
         signal.take_profit = 0.0;
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("close<%d-bar low %.5f", m_channel_bars, lo);
         return true;
        }

      return false;
     }

   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";

      if(!PositionSelectByTicket(ticket))
         return d;

      double hi, lo;
      if(!Channel(ctx.symbol, hi, lo))
         return d;

      double close = iClose(ctx.symbol, m_tf, 1);
      double mid   = (hi + lo) / 2.0;
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      //--- a break that closes back below the midpoint has failed
      if(ptype == POSITION_TYPE_BUY && close < mid)
        {
         d.should_exit = true;
         d.reason      = "failed_break";
        }
      if(ptype == POSITION_TYPE_SELL && close > mid)
        {
         d.should_exit = true;
         d.reason      = "failed_break";
        }
      return d;
     }

   virtual double    TrailStop(const SMarketContext &ctx, const ulong ticket)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0 || !PositionSelectByTicket(ticket))
         return 0.0;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return 0.0;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);

      //--- breakouts either run or fail fast; trail tight from the start
      if(ptype == POSITION_TYPE_BUY)
        {
         if(ctx.bid - open < 0.5 * atr)
            return 0.0;
         return ctx.bid - m_trail_atr_mult * atr;
        }
      if(open - ctx.ask < 0.5 * atr)
         return 0.0;
      return ctx.ask + m_trail_atr_mult * atr;
     }
  };

#endif // __ADAPTIVE_BREAKOUTDONCHIAN_MQH__

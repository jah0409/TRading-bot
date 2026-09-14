//+------------------------------------------------------------------+
//| TrendFollowEma.mqh - EMA cross with an ADX strength gate          |
//| Indicators: EMA(fast), EMA(slow), ADX  -> 3                       |
//| Home regimes: TREND_UP, TREND_DOWN                                |
//| Stop: ATR-multiple below/above the slow EMA                       |
//| Exit: cross back through the slow EMA, or ADX collapse            |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_TRENDFOLLOWEMA_MQH__
#define __ADAPTIVE_TRENDFOLLOWEMA_MQH__

#include "StrategyBase.mqh"

class CTrendFollowEma : public CStrategyBase
  {
private:
   //--- one handle set per traded symbol
   string            m_syms[];
   int               m_h_fast[];
   int               m_h_slow[];
   int               m_h_adx[];
   int               m_h_atr[];

   int               m_fast_period;
   int               m_slow_period;
   int               m_adx_period;
   int               m_atr_period;
   double            m_adx_min;
   double            m_atr_stop_mult;
   double            m_trail_atr_mult;
   double            m_min_rr;
   ENUM_TIMEFRAMES   m_tf;

   int               SymIndex(const string symbol) const { return IndexOfSymbol(m_syms, symbol); }

   bool              ReadEma(const int idx, double &fast1, double &fast2,
                             double &slow1, double &slow2) const
     {
      double f[], s[];
      ArraySetAsSeries(f, true);
      ArraySetAsSeries(s, true);
      if(CopyBuffer(m_h_fast[idx], 0, 0, 4, f) < 3)
         return false;
      if(CopyBuffer(m_h_slow[idx], 0, 0, 4, s) < 3)
         return false;
      fast1 = f[1]; fast2 = f[2];
      slow1 = s[1]; slow2 = s[2];
      return true;
     }

public:
   virtual bool      OnInit(void)
     {
      m_tf             = (ENUM_TIMEFRAMES)ParamI("timeframe_minutes", 60) == 60
                         ? PERIOD_H1 : PERIOD_M15;
      m_fast_period    = ParamI("ema_fast", 21);
      m_slow_period    = ParamI("ema_slow", 55);
      m_adx_period     = ParamI("adx_period", 14);
      m_atr_period     = ParamI("atr_period", 14);
      m_adx_min        = ParamD("adx_min", 25.0);
      m_atr_stop_mult  = ParamD("atr_stop_mult", 2.0);
      m_trail_atr_mult = ParamD("trail_atr_mult", 2.5);
      m_min_rr         = ParamD("min_rr", 1.5);

      //--- build handles for every symbol I am allowed to trade
      int n = BuildSymbolList(m_syms);
      ArrayResize(m_h_fast, n);
      ArrayResize(m_h_slow, n);
      ArrayResize(m_h_adx, n);
      ArrayResize(m_h_atr, n);

      for(int k = 0; k < n; k++)
        {
         string sym = m_syms[k];
         m_h_fast[k] = iMA(sym, m_tf, m_fast_period, 0, MODE_EMA, PRICE_CLOSE);
         m_h_slow[k] = iMA(sym, m_tf, m_slow_period, 0, MODE_EMA, PRICE_CLOSE);
         m_h_adx[k]  = iADX(sym, m_tf, m_adx_period);
         m_h_atr[k]  = iATR(sym, m_tf, m_atr_period);

         if(m_h_fast[k] == INVALID_HANDLE || m_h_slow[k] == INVALID_HANDLE ||
            m_h_adx[k] == INVALID_HANDLE  || m_h_atr[k] == INVALID_HANDLE)
           {
            m_log.Warn(StringFormat("%s: handle creation failed for %s", m_id, sym));
            return false;
           }
        }
      return true;
     }

   virtual void      OnDeinit(void)
     {
      for(int i = 0; i < ArraySize(m_syms); i++)
        {
         IndicatorRelease(m_h_fast[i]);
         IndicatorRelease(m_h_slow[i]);
         IndicatorRelease(m_h_adx[i]);
         IndicatorRelease(m_h_atr[i]);
        }
     }

   //--- only trade a trend that the regime detector also sees
   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_TREND_UP && ctx.regime.composite != REGIME_TREND_DOWN)
         return false;

      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;

      //--- act once per closed bar, not on every 5s tick
      if(!IsNewBar(ctx.symbol, m_tf, idx))
         return false;

      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(m_h_adx[idx], 0, 0, 3, adx) < 2)
         return false;

      return (adx[1] >= m_adx_min);
     }

   virtual bool      Entry(const SMarketContext &ctx, SEntrySignal &signal)
     {
      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return false;

      double f1, f2, s1, s2;
      if(!ReadEma(idx, f1, f2, s1, s2))
         return false;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return false;

      //--- === TUNE ME === cross of fast through slow, confirmed by the
      //--- regime direction. Requiring both keeps us out of the counter-
      //--- trend crosses that chop produces.
      bool cross_up   = (f2 <= s2 && f1 > s1);
      bool cross_down = (f2 >= s2 && f1 < s1);

      if(cross_up && ctx.regime.composite == REGIME_TREND_UP)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask;
         signal.stop_loss   = s1 - m_atr_stop_mult * atr;
         signal.take_profit = ctx.ask + m_min_rr * (ctx.ask - signal.stop_loss);
         signal.confidence  = ctx.regime.composite_conf * (ctx.regime.aligned ? 1.0 : 0.75);
         signal.reason      = StringFormat("ema%d>%d cross, adx ok, atr=%.5f",
                                           m_fast_period, m_slow_period, atr);
         return true;
        }

      if(cross_down && ctx.regime.composite == REGIME_TREND_DOWN)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid;
         signal.stop_loss   = s1 + m_atr_stop_mult * atr;
         signal.take_profit = ctx.bid - m_min_rr * (signal.stop_loss - ctx.bid);
         signal.confidence  = ctx.regime.composite_conf * (ctx.regime.aligned ? 1.0 : 0.75);
         signal.reason      = StringFormat("ema%d<%d cross, adx ok, atr=%.5f",
                                           m_fast_period, m_slow_period, atr);
         return true;
        }

      return false;
     }

   //--- leave when the trend thesis dies
   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";

      int idx = SymIndex(ctx.symbol);
      if(idx < 0 || !PositionSelectByTicket(ticket))
         return d;

      double f1, f2, s1, s2;
      if(!ReadEma(idx, f1, f2, s1, s2))
         return d;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(ptype == POSITION_TYPE_BUY && f1 < s1)
        {
         d.should_exit = true;
         d.reason      = "ema_cross_against";
        }
      if(ptype == POSITION_TYPE_SELL && f1 > s1)
        {
         d.should_exit = true;
         d.reason      = "ema_cross_against";
        }

      //--- regime flipped out from under us
      if(!d.should_exit &&
         ctx.regime.composite != REGIME_TREND_UP && ctx.regime.composite != REGIME_TREND_DOWN)
        {
         d.should_exit = true;
         d.fraction    = 0.5;      // scale out rather than slam the exit
         d.reason      = "regime_left_trend";
        }

      return d;
     }

   //--- chandelier-style trail off ATR
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

      if(ptype == POSITION_TYPE_BUY)
        {
         //--- only start trailing once we are 1 ATR in profit
         if(ctx.bid - open < atr)
            return 0.0;
         return ctx.bid - m_trail_atr_mult * atr;
        }

      if(open - ctx.ask < atr)
         return 0.0;
      return ctx.ask + m_trail_atr_mult * atr;
     }
  };

#endif // __ADAPTIVE_TRENDFOLLOWEMA_MQH__

//+------------------------------------------------------------------+
//| MomentumPullback.mqh - buy the dip inside an established trend    |
//| Indicators: EMA(50), Stochastic(14,3,3), ATR  -> 3                |
//| Home regimes: TREND_UP, TREND_DOWN                                |
//| Differs from TrendFollowEma: that one enters on the cross (early, |
//| more signals); this one waits for a pullback to the EMA and a     |
//| momentum turn (later, fewer, better average entry).               |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_MOMENTUMPULLBACK_MQH__
#define __ADAPTIVE_MOMENTUMPULLBACK_MQH__

#include "StrategyBase.mqh"

class CMomentumPullback : public CStrategyBase
  {
private:
   string            m_syms[];
   int               m_h_ema[];
   int               m_h_stoch[];
   int               m_h_atr[];

   int               m_ema_period;
   int               m_stoch_k;
   int               m_stoch_d;
   int               m_stoch_slow;
   double            m_stoch_oversold;
   double            m_stoch_overbought;
   double            m_pullback_atr;     // how close to the EMA counts as a pullback
   double            m_stop_atr_mult;
   double            m_trail_atr_mult;
   ENUM_TIMEFRAMES   m_tf;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   double            Ema(const int idx) const
     {
      double b[];
      ArraySetAsSeries(b, true);
      if(CopyBuffer(m_h_ema[idx], 0, 0, 3, b) < 2)
         return 0.0;
      return b[1];
     }

   bool              Stoch(const int idx, double &k1, double &k2, double &d1) const
     {
      double k[], d[];
      ArraySetAsSeries(k, true);
      ArraySetAsSeries(d, true);
      if(CopyBuffer(m_h_stoch[idx], 0, 0, 4, k) < 3) return false;
      if(CopyBuffer(m_h_stoch[idx], 1, 0, 4, d) < 3) return false;
      k1 = k[1]; k2 = k[2]; d1 = d[1];
      return true;
     }

public:
   virtual bool      OnInit(void)
     {
      m_tf               = (ParamI("timeframe_minutes", 60) == 15 ? PERIOD_M15 : PERIOD_H1);
      m_ema_period       = ParamI("ema_period", 50);
      m_stoch_k          = ParamI("stoch_k", 14);
      m_stoch_d          = ParamI("stoch_d", 3);
      m_stoch_slow       = ParamI("stoch_slowing", 3);
      m_stoch_oversold   = ParamD("stoch_oversold", 25.0);
      m_stoch_overbought = ParamD("stoch_overbought", 75.0);
      m_pullback_atr     = ParamD("pullback_atr", 0.75);
      m_stop_atr_mult    = ParamD("stop_atr_mult", 1.5);
      m_trail_atr_mult   = ParamD("trail_atr_mult", 2.0);

      int n = BuildSymbolList(m_syms);
      ArrayResize(m_h_ema, n);
      ArrayResize(m_h_stoch, n);
      ArrayResize(m_h_atr, n);

      for(int k = 0; k < n; k++)
        {
         m_h_ema[k]   = iMA(m_syms[k], m_tf, m_ema_period, 0, MODE_EMA, PRICE_CLOSE);
         m_h_stoch[k] = iStochastic(m_syms[k], m_tf, m_stoch_k, m_stoch_d, m_stoch_slow,
                                    MODE_SMA, STO_LOWHIGH);
         m_h_atr[k]   = iATR(m_syms[k], m_tf, 14);
         if(m_h_ema[k] == INVALID_HANDLE || m_h_stoch[k] == INVALID_HANDLE ||
            m_h_atr[k] == INVALID_HANDLE)
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
         IndicatorRelease(m_h_ema[i]);
         IndicatorRelease(m_h_stoch[i]);
         IndicatorRelease(m_h_atr[i]);
        }
     }

   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_TREND_UP && ctx.regime.composite != REGIME_TREND_DOWN)
         return false;
      //--- pullback entries want multi-timeframe agreement; without it
      //--- the "pullback" is usually the start of the reversal
      if(!ctx.regime.aligned)
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

      double ema = Ema(idx);
      double atr = AtrValue(m_h_atr[idx], 1);
      if(ema <= 0.0 || atr <= 0.0)
         return false;

      double k1, k2, d1;
      if(!Stoch(idx, k1, k2, d1))
         return false;

      double close = iClose(ctx.symbol, m_tf, 1);
      double low   = iLow(ctx.symbol, m_tf, 1);
      double high  = iHigh(ctx.symbol, m_tf, 1);
      if(close <= 0.0)
         return false;

      //--- === TUNE ME === three conditions, all required:
      //---   1. price pulled back to within m_pullback_atr of the EMA
      //---   2. stochastic was at an extreme and is turning back
      //---   3. we are still on the right side of the EMA (trend intact)
      if(ctx.regime.composite == REGIME_TREND_UP)
        {
         bool pulled_back = (low <= ema + m_pullback_atr * atr);
         bool turning_up  = (k2 <= m_stoch_oversold && k1 > k2);
         bool trend_intact = (close > ema);

         if(pulled_back && turning_up && trend_intact)
           {
            signal.valid       = true;
            signal.direction   = ORDER_TYPE_BUY;
            signal.entry_price = ctx.ask;
            signal.stop_loss   = MathMin(low, ema) - m_stop_atr_mult * atr;
            signal.take_profit = 0.0;
            signal.confidence  = ctx.regime.composite_conf;
            signal.reason      = StringFormat("pullback to ema%d, stoch %.1f->%.1f",
                                              m_ema_period, k2, k1);
            return true;
           }
        }
      else
        {
         bool pulled_back  = (high >= ema - m_pullback_atr * atr);
         bool turning_down = (k2 >= m_stoch_overbought && k1 < k2);
         bool trend_intact = (close < ema);

         if(pulled_back && turning_down && trend_intact)
           {
            signal.valid       = true;
            signal.direction   = ORDER_TYPE_SELL;
            signal.entry_price = ctx.bid;
            signal.stop_loss   = MathMax(high, ema) + m_stop_atr_mult * atr;
            signal.take_profit = 0.0;
            signal.confidence  = ctx.regime.composite_conf;
            signal.reason      = StringFormat("pullback to ema%d, stoch %.1f->%.1f",
                                              m_ema_period, k2, k1);
            return true;
           }
        }

      return false;
     }

   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";

      int idx = SymIndex(ctx.symbol);
      if(idx < 0 || !PositionSelectByTicket(ticket))
         return d;

      double ema   = Ema(idx);
      double close = iClose(ctx.symbol, m_tf, 1);
      if(ema <= 0.0 || close <= 0.0)
         return d;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      //--- a decisive close through the EMA ends the trend thesis
      if(ptype == POSITION_TYPE_BUY && close < ema)
        {
         d.should_exit = true;
         d.reason      = "close_below_ema";
        }
      if(ptype == POSITION_TYPE_SELL && close > ema)
        {
         d.should_exit = true;
         d.reason      = "close_above_ema";
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

      if(ptype == POSITION_TYPE_BUY)
        {
         if(ctx.bid - open < atr)
            return 0.0;
         return ctx.bid - m_trail_atr_mult * atr;
        }
      if(open - ctx.ask < atr)
         return 0.0;
      return ctx.ask + m_trail_atr_mult * atr;
     }
  };

#endif // __ADAPTIVE_MOMENTUMPULLBACK_MQH__

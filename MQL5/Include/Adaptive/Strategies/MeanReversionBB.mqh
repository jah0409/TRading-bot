//+------------------------------------------------------------------+
//| MeanReversionBB.mqh - fade the band edge, exit at the mean        |
//| Indicators: Bollinger(20,2), RSI(14)  -> 2                        |
//| Home regime: RANGE                                                |
//| Stop: beyond the band edge by an ATR fraction                     |
//| Exit: touch of the middle band, or regime leaves RANGE            |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_MEANREVERSIONBB_MQH__
#define __ADAPTIVE_MEANREVERSIONBB_MQH__

#include "StrategyBase.mqh"

class CMeanReversionBB : public CStrategyBase
  {
private:
   string            m_syms[];
   int               m_h_bb[];
   int               m_h_rsi[];
   int               m_h_atr[];

   int               m_bb_period;
   double            m_bb_dev;
   int               m_rsi_period;
   double            m_rsi_oversold;
   double            m_rsi_overbought;
   double            m_stop_atr_mult;
   ENUM_TIMEFRAMES   m_tf;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   bool              ReadBands(const int idx, double &upper, double &middle, double &lower) const
     {
      double u[], m[], l[];
      ArraySetAsSeries(u, true);
      ArraySetAsSeries(m, true);
      ArraySetAsSeries(l, true);
      //--- iBands buffers: 0 = base/middle, 1 = upper, 2 = lower
      if(CopyBuffer(m_h_bb[idx], 0, 0, 3, m) < 2) return false;
      if(CopyBuffer(m_h_bb[idx], 1, 0, 3, u) < 2) return false;
      if(CopyBuffer(m_h_bb[idx], 2, 0, 3, l) < 2) return false;
      middle = m[1];
      upper  = u[1];
      lower  = l[1];
      return true;
     }

   double            Rsi(const int idx) const
     {
      double r[];
      ArraySetAsSeries(r, true);
      if(CopyBuffer(m_h_rsi[idx], 0, 0, 3, r) < 2)
         return 50.0;
      return r[1];
     }

public:
   virtual bool      OnInit(void)
     {
      m_tf             = (ParamI("timeframe_minutes", 15) == 60 ? PERIOD_H1 : PERIOD_M15);
      m_bb_period      = ParamI("bb_period", 20);
      m_bb_dev         = ParamD("bb_deviation", 2.0);
      m_rsi_period     = ParamI("rsi_period", 14);
      m_rsi_oversold   = ParamD("rsi_oversold", 30.0);
      m_rsi_overbought = ParamD("rsi_overbought", 70.0);
      m_stop_atr_mult  = ParamD("stop_atr_mult", 1.0);

      int n = BuildSymbolList(m_syms);
      ArrayResize(m_h_bb, n);
      ArrayResize(m_h_rsi, n);
      ArrayResize(m_h_atr, n);

      for(int k = 0; k < n; k++)
        {
         m_h_bb[k]  = iBands(m_syms[k], m_tf, m_bb_period, 0, m_bb_dev, PRICE_CLOSE);
         m_h_rsi[k] = iRSI(m_syms[k], m_tf, m_rsi_period, PRICE_CLOSE);
         m_h_atr[k] = iATR(m_syms[k], m_tf, 14);
         if(m_h_bb[k] == INVALID_HANDLE || m_h_rsi[k] == INVALID_HANDLE ||
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
         IndicatorRelease(m_h_bb[i]);
         IndicatorRelease(m_h_rsi[i]);
         IndicatorRelease(m_h_atr[i]);
        }
     }

   //--- mean reversion needs a range. In a trend it is a losing bet,
   //--- and in high-vol chop the band edge is not a wall.
   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_RANGE)
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

      double upper, middle, lower;
      if(!ReadBands(idx, upper, middle, lower))
         return false;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return false;

      double rsi   = Rsi(idx);
      double close = iClose(ctx.symbol, m_tf, 1);
      if(close <= 0.0)
         return false;

      //--- === TUNE ME === close outside the band AND an RSI extreme.
      //--- Requiring both halves the signal count and roughly doubles
      //--- the hit rate in backtests of this family; verify per symbol.
      if(close <= lower && rsi <= m_rsi_oversold)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask;
         signal.stop_loss   = lower - m_stop_atr_mult * atr;
         signal.take_profit = middle;              // mean is the target
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("close<lower band, rsi=%.1f", rsi);
         return true;
        }

      if(close >= upper && rsi >= m_rsi_overbought)
        {
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid;
         signal.stop_loss   = upper + m_stop_atr_mult * atr;
         signal.take_profit = middle;
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("close>upper band, rsi=%.1f", rsi);
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

      int idx = SymIndex(ctx.symbol);
      if(idx < 0 || !PositionSelectByTicket(ticket))
         return d;

      //--- the thesis is "price returns to the mean". If the market
      //--- stops ranging, the thesis is void - leave immediately.
      if(ctx.regime.composite != REGIME_RANGE)
        {
         d.should_exit = true;
         d.reason      = "regime_left_range";
         return d;
        }

      double upper, middle, lower;
      if(!ReadBands(idx, upper, middle, lower))
         return d;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype == POSITION_TYPE_BUY && ctx.bid >= middle)
        {
         d.should_exit = true;
         d.reason      = "reached_mean";
        }
      if(ptype == POSITION_TYPE_SELL && ctx.ask <= middle)
        {
         d.should_exit = true;
         d.reason      = "reached_mean";
        }
      return d;
     }

   //--- mean reversion trades are short and targeted: break-even only,
   //--- no trailing (trailing a fade just gets you stopped on noise)
   virtual double    TrailStop(const SMarketContext &ctx, const ulong ticket)
     {
      if(!PositionSelectByTicket(ticket))
         return 0.0;
      int idx = SymIndex(ctx.symbol);
      if(idx < 0)
         return 0.0;

      double atr = AtrValue(m_h_atr[idx], 1);
      if(atr <= 0.0)
         return 0.0;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);

      if(ptype == POSITION_TYPE_BUY && ctx.bid - open > atr)
         return open;     // to break-even, then leave it alone
      if(ptype == POSITION_TYPE_SELL && open - ctx.ask > atr)
         return open;
      return 0.0;
     }
  };

#endif // __ADAPTIVE_MEANREVERSIONBB_MQH__

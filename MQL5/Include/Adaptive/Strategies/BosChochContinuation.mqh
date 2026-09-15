//+------------------------------------------------------------------+
//| BosChochContinuation.mqh - the strategy that actually validated   |
//|                                                                    |
//| MQL5 mirror of strategies_v2.BosChochContinuation, which is the    |
//| only candidate that survived walk-forward on real XAUUSD H4 data   |
//| (+0.081R over 281 trades, PF 1.22, zero unstable parameters).      |
//|                                                                    |
//| Until this existed, config.json pointed bos_choch_h4 at            |
//| "breakout_donchian" - a different strategy entirely. The EA would  |
//| have traded something that was never validated.                    |
//|                                                                    |
//| Rules:                                                             |
//|   CHoCH  a break of structure AGAINST the prevailing bias: the     |
//|          first evidence the trend is changing hands                 |
//|   BOS    a later break in the NEW direction confirms it            |
//|   entry  on that confirming BOS, within `window` bars of the CHoCH |
//|   stop   beyond the opposing swing, or an ATR multiple, whichever  |
//|          is further                                                 |
//|   target rr x risk;  trail at trail_atr once 1 ATR in profit       |
//|                                                                    |
//| Swings are confirmed only k bars AFTER they form. That lag is      |
//| deliberate and matches the research: treating an unconfirmed swing  |
//| as known would read k bars of future into every signal.            |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_BOSCHOCH_MQH__
#define __ADAPTIVE_BOSCHOCH_MQH__

#include "StrategyBase.mqh"

class CBosChochContinuation : public CStrategyBase
  {
private:
   string            m_syms[];
   int               m_h_atr[];

   int               m_swing_k;
   int               m_window;
   double            m_stop_atr;
   double            m_trail_atr;
   double            m_rr;
   ENUM_TIMEFRAMES   m_tf;
   int               m_lookback;

   int               SymIndex(const string s) const { return IndexOfSymbol(m_syms, s); }

   //+---------------------------------------------------------------+
   //| Structure over the last m_lookback closed bars.                |
   //|                                                                |
   //| rates[] is series-ordered (index 0 = forming bar), so index 1  |
   //| is the last closed bar and larger indices go further back.     |
   //| Everything below reads index >= 1 only.                        |
   //+---------------------------------------------------------------+
   bool              Structure(const string symbol, double &swing_high, double &swing_low,
                               int &bias, bool &bos_up, bool &bos_dn,
                               bool &choch_up_recent, bool &choch_dn_recent)
     {
      swing_high = 0.0; swing_low = 0.0; bias = 0;
      bos_up = false; bos_dn = false;
      choch_up_recent = false; choch_dn_recent = false;

      MqlRates r[];
      ArraySetAsSeries(r, true);
      int need = m_lookback + m_swing_k + 4;
      if(CopyRates(symbol, m_tf, 0, need, r) < need)
         return false;

      //--- walk forward in time from oldest to newest closed bar,
      //--- rebuilding the same state machine the research used
      double last_sh = 0.0, last_sl = 0.0, prev_sh = 0.0, prev_sl = 0.0;
      int    cur_bias = 0;
      bool   above = false, below = false;
      int    choch_up_bar = -1, choch_dn_bar = -1;
      int    bos_up_bar = -1, bos_dn_bar = -1;

      //--- i is a series index; iterate from old (high i) to new (i = 1)
      for(int i = m_lookback + m_swing_k; i >= 1; i--)
        {
         //--- confirm the swing that sat k bars ago
         int c = i + m_swing_k;               // candidate swing bar
         if(c + m_swing_k < ArraySize(r))
           {
            bool is_sh = true, is_sl = true;
            for(int j = 1; j <= m_swing_k; j++)
              {
               if(r[c].high <= r[c + j].high || r[c].high <= r[c - j].high) is_sh = false;
               if(r[c].low  >= r[c + j].low  || r[c].low  >= r[c - j].low)  is_sl = false;
              }
            if(is_sh) { prev_sh = last_sh; last_sh = r[c].high; }
            if(is_sl) { prev_sl = last_sl; last_sl = r[c].low;  }

            //--- HH+HL => bullish structure, LH+LL => bearish
            if(last_sh > 0 && prev_sh > 0 && last_sl > 0 && prev_sl > 0)
              {
               if(last_sh > prev_sh && last_sl > prev_sl)      cur_bias = 1;
               else if(last_sh < prev_sh && last_sl < prev_sl) cur_bias = -1;
              }
           }

         //--- BOS as an EVENT: the bar that first closes through the level
         bool now_above = (last_sh > 0.0 && r[i].close > last_sh);
         bool now_below = (last_sl > 0.0 && r[i].close < last_sl);
         bool ev_up = (now_above && !above);
         bool ev_dn = (now_below && !below);
         above = now_above;
         below = now_below;

         if(ev_up)
           {
            bos_up_bar = i;
            if(cur_bias < 0) choch_up_bar = i;   // break against a bearish bias
           }
         if(ev_dn)
           {
            bos_dn_bar = i;
            if(cur_bias > 0) choch_dn_bar = i;
           }
        }

      swing_high = last_sh;
      swing_low  = last_sl;
      bias       = cur_bias;
      //--- "now" means the last CLOSED bar, index 1
      bos_up = (bos_up_bar == 1);
      bos_dn = (bos_dn_bar == 1);
      //--- a CHoCH still counts if it fired within the window (series
      //--- indices count DOWN as time moves forward, so a bar is inside
      //--- the window when its index is at most window bars above 1)
      choch_up_recent = (choch_up_bar >= 1 && choch_up_bar <= m_window);
      choch_dn_recent = (choch_dn_bar >= 1 && choch_dn_bar <= m_window);
      return true;
     }

public:
   virtual bool      OnInit(void)
     {
      int tf_min   = ParamI("timeframe_minutes", 240);
      m_tf         = (tf_min >= 240 ? PERIOD_H4 : (tf_min >= 60 ? PERIOD_H1 : PERIOD_M15));
      m_swing_k    = ParamI("swing_k", 3);
      m_window     = ParamI("window", 6);
      m_stop_atr   = ParamD("stop_atr", 1.0);
      m_trail_atr  = ParamD("trail_atr", 2.0);
      m_rr         = ParamD("rr", 1.5);
      m_lookback   = ParamI("structure_lookback", 200);

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
      m_log.Info(StringFormat("%s ready on %s: window=%d stop=%.2fATR rr=%.2f",
                              m_id, EnumToString(m_tf), m_window, m_stop_atr, m_rr));
      return true;
     }

   virtual void      OnDeinit(void)
     {
      for(int i = 0; i < ArraySize(m_syms); i++)
         IndicatorRelease(m_h_atr[i]);
     }

   //--- act once per closed bar, and only in the regimes it validated in
   virtual bool      Filter(const SMarketContext &ctx)
     {
      if(ctx.regime.composite != REGIME_TREND_UP &&
         ctx.regime.composite != REGIME_TREND_DOWN &&
         ctx.regime.composite != REGIME_BREAKOUT)
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

      double sh, sl;
      int bias;
      bool bos_up, bos_dn, ch_up, ch_dn;
      if(!Structure(ctx.symbol, sh, sl, bias, bos_up, bos_dn, ch_up, ch_dn))
         return false;

      double close = iClose(ctx.symbol, m_tf, 1);
      if(close <= 0.0)
         return false;

      //--- long: structure turned up recently, and this bar confirms it
      if(ch_up && bos_up)
        {
         double atr_stop = close - m_stop_atr * atr;
         double stop = (sl > 0.0 ? MathMin(sl, atr_stop) : atr_stop);
         if(stop >= ctx.ask)
            return false;
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_BUY;
         signal.entry_price = ctx.ask;
         signal.stop_loss   = stop;
         signal.take_profit = ctx.ask + m_rr * (ctx.ask - stop);
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("CHoCH up then BOS, swing_low=%.2f atr=%.2f", sl, atr);
         return true;
        }

      if(ch_dn && bos_dn)
        {
         double atr_stop = close + m_stop_atr * atr;
         double stop = (sh > 0.0 ? MathMax(sh, atr_stop) : atr_stop);
         if(stop <= ctx.bid)
            return false;
         signal.valid       = true;
         signal.direction   = ORDER_TYPE_SELL;
         signal.entry_price = ctx.bid;
         signal.stop_loss   = stop;
         signal.take_profit = ctx.bid - m_rr * (stop - ctx.bid);
         signal.confidence  = ctx.regime.composite_conf;
         signal.reason      = StringFormat("CHoCH down then BOS, swing_high=%.2f atr=%.2f", sh, atr);
         return true;
        }

      return false;
     }

   //--- leave when structure turns against the position
   virtual SExitDecision Exit(const SMarketContext &ctx, const ulong ticket)
     {
      SExitDecision d;
      d.should_exit = false;
      d.fraction    = 1.0;
      d.reason      = "";

      if(!PositionSelectByTicket(ticket))
         return d;

      double sh, sl;
      int bias;
      bool bu, bd, cu, cd;
      if(!Structure(ctx.symbol, sh, sl, bias, bu, bd, cu, cd))
         return d;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype == POSITION_TYPE_BUY && bd)
        {
         d.should_exit = true;
         d.reason      = "structure_broke_down";
        }
      if(ptype == POSITION_TYPE_SELL && bu)
        {
         d.should_exit = true;
         d.reason      = "structure_broke_up";
        }
      return d;
     }

   //--- ATR trail, armed only once 1 ATR in profit
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

      //--- the research also required a trailed exit to keep the minimum
      //--- target, so do not arm the trail until the trade is past it
      double pip   = m_cfg.Json().GetDouble("risk.pip_size", 1.0);
      double min_t = m_cfg.Json().GetDouble("risk.min_target_pips", 0.0) * pip;

      if(ptype == POSITION_TYPE_BUY)
        {
         double moved = ctx.bid - open;
         if(moved < atr || moved < min_t)
            return 0.0;
         double cand = ctx.bid - m_trail_atr * atr;
         return MathMax(cand, open + min_t);
        }

      double moved = open - ctx.ask;
      if(moved < atr || moved < min_t)
         return 0.0;
      double cand = ctx.ask + m_trail_atr * atr;
      return MathMin(cand, open - min_t);
     }
  };

#endif // __ADAPTIVE_BOSCHOCH_MQH__

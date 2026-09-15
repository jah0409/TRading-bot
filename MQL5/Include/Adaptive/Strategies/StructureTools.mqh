//+------------------------------------------------------------------+
//| StructureTools.mqh - market structure primitives, shared          |
//|                                                                    |
//| Swings, BOS, CHoCH, previous-day levels and session ranges, in one |
//| place so the strategies that need them cannot drift apart. Mirrors |
//| tools/feature_engine.py, which is what the research measured.      |
//|                                                                    |
//| Causality rule enforced throughout: a swing is only reported once  |
//| it has been CONFIRMED by k bars on both sides, and every read is   |
//| from bar index >= 1 (the last CLOSED bar). Index 0 is the forming  |
//| bar and is never touched.                                          |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_STRUCTURETOOLS_MQH__
#define __ADAPTIVE_STRUCTURETOOLS_MQH__

#include "../Core/Types.mqh"

struct SStructure
  {
   double            swing_high;      // last confirmed
   double            swing_low;
   int               bias;            // +1 bullish, -1 bearish, 0 undecided
   bool              bos_up;          // fired on the last closed bar
   bool              bos_down;
   bool              choch_up_recent; // within the window
   bool              choch_down_recent;
   bool              valid;
  };

//+------------------------------------------------------------------+
//| Rebuild structure over the last `lookback` closed bars.           |
//|                                                                   |
//| rates[] is series-ordered (0 = forming). Iterating from high index |
//| to low walks forward in time, which is what lets BOS be detected  |
//| as an EVENT - the bar that FIRST closes through the level - rather |
//| than a state that stays true while price sits beyond it.          |
//+------------------------------------------------------------------+
bool BuildStructure(const string symbol, const ENUM_TIMEFRAMES tf,
                    const int swing_k, const int window, const int lookback,
                    SStructure &out)
  {
   out.swing_high = 0.0; out.swing_low = 0.0; out.bias = 0;
   out.bos_up = false; out.bos_down = false;
   out.choch_up_recent = false; out.choch_down_recent = false;
   out.valid = false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int need = lookback + swing_k + 4;
   if(CopyRates(symbol, tf, 0, need, r) < need)
      return false;

   double last_sh = 0.0, last_sl = 0.0, prev_sh = 0.0, prev_sl = 0.0;
   int    bias = 0;
   bool   above = false, below = false;
   int    choch_up_bar = -1, choch_dn_bar = -1, bos_up_bar = -1, bos_dn_bar = -1;

   for(int i = lookback + swing_k; i >= 1; i--)
     {
      int c = i + swing_k;                      // the bar being confirmed
      if(c + swing_k < ArraySize(r))
        {
         bool is_sh = true, is_sl = true;
         for(int j = 1; j <= swing_k; j++)
           {
            if(r[c].high <= r[c + j].high || r[c].high <= r[c - j].high) is_sh = false;
            if(r[c].low  >= r[c + j].low  || r[c].low  >= r[c - j].low)  is_sl = false;
           }
         if(is_sh) { prev_sh = last_sh; last_sh = r[c].high; }
         if(is_sl) { prev_sl = last_sl; last_sl = r[c].low;  }

         if(last_sh > 0 && prev_sh > 0 && last_sl > 0 && prev_sl > 0)
           {
            if(last_sh > prev_sh && last_sl > prev_sl)      bias = 1;   // HH + HL
            else if(last_sh < prev_sh && last_sl < prev_sl) bias = -1;  // LH + LL
           }
        }

      bool now_above = (last_sh > 0.0 && r[i].close > last_sh);
      bool now_below = (last_sl > 0.0 && r[i].close < last_sl);
      if(now_above && !above) { bos_up_bar = i; if(bias < 0) choch_up_bar = i; }
      if(now_below && !below) { bos_dn_bar = i; if(bias > 0) choch_dn_bar = i; }
      above = now_above;
      below = now_below;
     }

   out.swing_high = last_sh;
   out.swing_low  = last_sl;
   out.bias       = bias;
   out.bos_up     = (bos_up_bar == 1);
   out.bos_down   = (bos_dn_bar == 1);
   out.choch_up_recent   = (choch_up_bar >= 1 && choch_up_bar <= window);
   out.choch_down_recent = (choch_dn_bar >= 1 && choch_dn_bar <= window);
   out.valid = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Previous COMPLETED day's high and low.                            |
//+------------------------------------------------------------------+
bool PreviousDayLevels(const string symbol, double &pdh, double &pdl)
  {
   pdh = 0.0; pdl = 0.0;
   MqlRates d[];
   ArraySetAsSeries(d, true);
   if(CopyRates(symbol, PERIOD_D1, 0, 3, d) < 2)
      return false;
   pdh = d[1].high;     // d[0] is today, still forming
   pdl = d[1].low;
   return (pdh > 0.0 && pdl > 0.0 && pdh > pdl);
  }

//+------------------------------------------------------------------+
//| High/low of the Asian session for the CURRENT day, up to now.     |
//|                                                                   |
//| Hours are on the data/server clock. On an EET/EEST broker the      |
//| Asian window sits roughly 01:00-09:00 server time; adjust via      |
//| config if your server differs.                                    |
//+------------------------------------------------------------------+
bool AsianRange(const string symbol, const ENUM_TIMEFRAMES tf,
                const int from_hour, const int to_hour, double &hi, double &lo)
  {
   hi = 0.0; lo = 0.0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int bars = (int)(24 * 60 / PeriodSeconds(tf) * 60) + 8;
   if(bars < 12) bars = 12;
   if(CopyRates(symbol, tf, 0, bars, r) < 12)
      return false;

   MqlDateTime now;
   TimeToStruct(r[1].time, now);

   for(int i = 1; i < ArraySize(r); i++)
     {
      MqlDateTime t;
      TimeToStruct(r[i].time, t);
      if(t.day != now.day || t.mon != now.mon)
         break;                                  // stop at the day boundary
      if(t.hour < from_hour || t.hour >= to_hour)
         continue;
      if(hi == 0.0 || r[i].high > hi) hi = r[i].high;
      if(lo == 0.0 || r[i].low  < lo) lo = r[i].low;
     }
   return (hi > 0.0 && lo > 0.0 && hi > lo);
  }

//--- rejection candles on the last closed bar -----------------------
bool RejectionBull(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(symbol, tf, 0, 3, r) < 2) return false;
   double body  = MathAbs(r[1].close - r[1].open);
   double lower = MathMin(r[1].open, r[1].close) - r[1].low;
   double upper = r[1].high - MathMax(r[1].open, r[1].close);
   return (lower >= 2.0 * body && lower > upper);
  }

bool RejectionBear(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(symbol, tf, 0, 3, r) < 2) return false;
   double body  = MathAbs(r[1].close - r[1].open);
   double lower = MathMin(r[1].open, r[1].close) - r[1].low;
   double upper = r[1].high - MathMax(r[1].open, r[1].close);
   return (upper >= 2.0 * body && upper > lower);
  }

//--- displacement: a wide-range, strong-bodied bar -------------------
bool Displacement(const string symbol, const ENUM_TIMEFRAMES tf,
                  const double atr, const double atr_mult, const double body_frac, int &dir)
  {
   dir = 0;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(symbol, tf, 0, 3, r) < 2 || atr <= 0.0) return false;
   double rng = r[1].high - r[1].low;
   if(rng <= 0.0) return false;
   double body = MathAbs(r[1].close - r[1].open);
   if(rng < atr_mult * atr || body / rng < body_frac) return false;
   dir = (r[1].close > r[1].open ? 1 : -1);
   return true;
  }

#endif // __ADAPTIVE_STRUCTURETOOLS_MQH__

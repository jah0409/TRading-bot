//+------------------------------------------------------------------+
//| RegimeFeatures.mqh - the regime scoring maths, and nothing else   |
//|                                                                    |
//| Shared verbatim by the live CRegimeDetector and by the offline     |
//| exporter (tools/RegimeExport.mq5). That sharing is the point: if   |
//| calibration fits thresholds against features computed even         |
//| slightly differently from the ones used live, the fitted numbers   |
//| are worthless. One implementation, two callers.                    |
//|                                                                    |
//| No indicator handles, no history access, no state - pure functions |
//| over an SRegimeTF that somebody else has already filled in.        |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_REGIMEFEATURES_MQH__
#define __ADAPTIVE_REGIMEFEATURES_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"

//+------------------------------------------------------------------+
//| Linear ramp: 0 at or below lo, 1 at or above hi.                  |
//| Every threshold in this system is one of these rather than a hard |
//| cutoff, so a bar sitting one ADX point either side of a boundary  |
//| does not flip the whole strategy mix.                             |
//+------------------------------------------------------------------+
double RegimeRamp(const double x, const double lo, const double hi)
  {
   if(hi <= lo)
      return (x >= hi ? 1.0 : 0.0);
   if(x <= lo)
      return 0.0;
   if(x >= hi)
      return 1.0;
   return (x - lo) / (hi - lo);
  }

//+------------------------------------------------------------------+
//| Continuous score for each regime, all on a comparable 0..1 scale. |
//+------------------------------------------------------------------+
void ComputeRegimeScores(const SRegimeTF &m, const SRegimeConfig &rc, SRegimeScores &out)
  {
   out.trend_up   = 0.0;
   out.trend_down = 0.0;
   out.range      = 0.0;
   out.breakout   = 0.0;
   out.chop       = 0.0;

   //--- primitives -------------------------------------------------
   double adx_strength = RegimeRamp(m.adx, rc.adx_trend_lo, rc.adx_trend_hi);
   double adx_weakness = 1.0 - RegimeRamp(m.adx, rc.adx_range_lo, rc.adx_range_hi);
   double directional  = RegimeRamp(m.di_spread_norm, rc.di_spread_lo, rc.di_spread_hi);
   double vol_high     = RegimeRamp(m.atr_percentile, rc.atr_vol_lo, rc.atr_vol_hi);
   double expansion    = RegimeRamp(m.atr_expansion, rc.atr_expansion_lo, rc.atr_expansion_hi);

   //--- candle evidence, as gentle nudges rather than gates --------
   bool   coiled_now   = ((m.candle_flags & (CANDLE_NR7 | CANDLE_INSIDE_BAR)) != 0);
   bool   expanding_now= ((m.candle_flags & (CANDLE_WIDE_RANGE | CANDLE_OUTSIDE_BAR)) != 0);

   //--- TREND: strong ADX with one side of DI clearly dominant ------
   double trend = adx_strength * directional;
   if(m.di_plus > m.di_minus)
      out.trend_up = trend;
   else
      out.trend_down = trend;

   //--- RANGE: weak ADX, contained volatility, ideally coiled -------
   out.range = adx_weakness * (1.0 - vol_high);
   if(coiled_now)
      out.range = MathMin(1.0, out.range * 1.15);

   //--- BREAKOUT: volatility expanding OUT OF a prior compression.
   //--- m.compression is measured over the bars BEFORE this one - the
   //--- breakout bar itself is never an inside bar, so testing the
   //--- current bar for a coil (as the first draft did) could never
   //--- fire. It also decays with established trend: a trend that has
   //--- been running for hours printing a wide bar is still a trend,
   //--- not a fresh breakout.
   double coil = RegimeRamp(m.compression, rc.compression_min, 1.0);
   out.breakout = expansion * coil * (1.0 - adx_strength);
   if(expanding_now)
      out.breakout = MathMin(1.0, out.breakout * 1.20);

   //--- CHOP: high volatility going nowhere. The account killer, so
   //--- it gets its own class rather than being lumped into RANGE.
   out.chop = vol_high * adx_weakness * (1.0 - directional);
  }

//+------------------------------------------------------------------+
//| argmax over the scores.                                           |
//|                                                                   |
//| Confidence is the MARGIN between the winner and the runner-up,    |
//| blended with the winner's absolute level. A bar where trend=0.9   |
//| and range=0.85 is genuinely ambiguous and should not be traded    |
//| with the same conviction as trend=0.9, range=0.05 - the first     |
//| draft's per-branch confidence formulas could not express that,    |
//| and they were not comparable between branches either.             |
//+------------------------------------------------------------------+
ENUM_REGIME ClassifyFromScores(const SRegimeScores &s, const SRegimeConfig &rc, double &confidence)
  {
   double        vals[5];
   ENUM_REGIME   regs[5];

   vals[0] = s.trend_up;   regs[0] = REGIME_TREND_UP;
   vals[1] = s.trend_down; regs[1] = REGIME_TREND_DOWN;
   vals[2] = s.range;      regs[2] = REGIME_RANGE;
   vals[3] = s.breakout;   regs[3] = REGIME_BREAKOUT;
   vals[4] = s.chop;       regs[4] = REGIME_CHOP_HIVOL;

   int    best = 0;
   double best_v = vals[0];
   for(int i = 1; i < 5; i++)
      if(vals[i] > best_v)
        {
         best_v = vals[i];
         best   = i;
        }

   double second = 0.0;
   for(int i = 0; i < 5; i++)
      if(i != best && vals[i] > second)
         second = vals[i];

   //--- nothing scored high enough to be worth acting on
   if(best_v < rc.min_score_to_classify)
     {
      confidence = 0.0;
      return REGIME_UNKNOWN;
     }

   double margin = (best_v > 0.0 ? (best_v - second) / best_v : 0.0);
   confidence = MathMax(0.0, MathMin(1.0, 0.5 * best_v + 0.5 * margin));
   return regs[best];
  }

//+------------------------------------------------------------------+
//| Candle pattern flags for one bar, given the 8 bars ending at it.  |
//| r[0] must be the bar being classified, r[1] the one before it,    |
//| and so on - i.e. series order. Kept here so the exporter and the  |
//| detector cannot drift apart.                                      |
//+------------------------------------------------------------------+
int ComputeCandleFlags(const MqlRates &r[], const int offset)
  {
   //--- need the bar plus six of history for NR7 and the range mean
   if(ArraySize(r) < offset + 8)
      return CANDLE_NONE;

   int    flags = CANDLE_NONE;
   double hi = r[offset].high, lo = r[offset].low;
   double op = r[offset].open, cl = r[offset].close;
   double rng = hi - lo;
   if(rng <= 0.0)
      return CANDLE_NONE;

   double body       = MathAbs(cl - op);
   double upper_wick = hi - MathMax(op, cl);
   double lower_wick = MathMin(op, cl) - lo;

   int p = offset + 1;   // the previous bar

   if(hi <= r[p].high && lo >= r[p].low)
      flags |= CANDLE_INSIDE_BAR;
   if(hi > r[p].high && lo < r[p].low)
      flags |= CANDLE_OUTSIDE_BAR;

   //--- NR7: narrowest range of the last seven
   bool nr7 = true;
   for(int i = offset + 1; i <= offset + 6; i++)
      if((r[i].high - r[i].low) <= rng)
        {
         nr7 = false;
         break;
        }
   if(nr7)
      flags |= CANDLE_NR7;

   //--- wide range: > 1.5x the mean of the prior six
   double mean = 0.0;
   for(int i = offset + 1; i <= offset + 6; i++)
      mean += (r[i].high - r[i].low);
   mean /= 6.0;
   if(mean > 0.0 && rng > 1.5 * mean)
      flags |= CANDLE_WIDE_RANGE;

   if(body <= 0.1 * rng)
      flags |= CANDLE_DOJI;
   if(lower_wick >= 2.0 * body && lower_wick > upper_wick)
      flags |= CANDLE_PIN_BULL;
   if(upper_wick >= 2.0 * body && upper_wick > lower_wick)
      flags |= CANDLE_PIN_BEAR;

   double pbody_hi = MathMax(r[p].open, r[p].close);
   double pbody_lo = MathMin(r[p].open, r[p].close);
   if(cl > op && cl >= pbody_hi && op <= pbody_lo)
      flags |= CANDLE_ENGULF_BULL;
   if(cl < op && op >= pbody_hi && cl <= pbody_lo)
      flags |= CANDLE_ENGULF_BEAR;

   return flags;
  }

//+------------------------------------------------------------------+
//| Compression over the bars BEFORE `offset`: the fraction of the    |
//| lookback window whose range sat below the window's own median.    |
//| Scale-free, so it transfers between instruments unchanged.        |
//+------------------------------------------------------------------+
double ComputeCompression(const MqlRates &r[], const int offset, const int lookback)
  {
   int n = lookback;
   if(n < 3 || ArraySize(r) < offset + 1 + n)
      return 0.0;

   double ranges[];
   ArrayResize(ranges, n);
   for(int i = 0; i < n; i++)
      ranges[i] = r[offset + 1 + i].high - r[offset + 1 + i].low;

   double sorted[];
   ArrayResize(sorted, n);
   ArrayCopy(sorted, ranges);
   ArraySort(sorted);
   double median = sorted[n / 2];
   if(median <= 0.0)
      return 0.0;

   //--- how tightly the window was coiled: mean range vs its median,
   //--- inverted and clamped. 1.0 = very quiet, 0.0 = not quiet.
   double mean = 0.0;
   for(int i = 0; i < n; i++)
      mean += ranges[i];
   mean /= (double)n;

   double ratio = mean / median;
   return MathMax(0.0, MathMin(1.0, 1.5 - ratio));
  }

#endif // __ADAPTIVE_REGIMEFEATURES_MQH__

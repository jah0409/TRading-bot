//+------------------------------------------------------------------+
//| RegimeDetector.mqh - classify market conditions per symbol        |
//|                                                                    |
//| Inputs per timeframe (M15, H1, H4):                                |
//|   ATR   -> volatility level, ranked against its own history        |
//|   ADX   -> trend strength, +DI/-DI -> direction                    |
//|   candles -> inside/outside bars, NR7 coils, wide-range expansion  |
//|                                                                    |
//| Output: one ENUM_REGIME per timeframe plus a weighted composite.   |
//| Hysteresis (min_bars_in_regime) stops the classification flapping  |
//| between bars and churning the active strategy set.                 |
//|                                                                    |
//| Indicator plumbing and the candle maths are REAL. The classifier   |
//| thresholds are first-guess defaults - they are what the walk-      |
//| forward study in docs/ is meant to calibrate.                      |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_REGIMEDETECTOR_MQH__
#define __ADAPTIVE_REGIMEDETECTOR_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"

//--- indicator handles + state for one (symbol, timeframe) pair -----
struct SRegimeSlot
  {
   string            symbol;
   ENUM_TF_SLOT      slot;
   int               h_atr;
   int               h_adx;
   ENUM_REGIME       current;      // regime after hysteresis
   ENUM_REGIME       pending;      // candidate waiting to be confirmed
   int               pending_bars;
   datetime          last_bar;
  };

class CRegimeDetector
  {
private:
   CConfig          *m_cfg;
   CLogger          *m_log;
   SRegimeSlot       m_slots[];
   SRegimeSnapshot   m_snapshots[];   // one per symbol, last computed

   int               FindSlot(const string symbol, const ENUM_TF_SLOT slot) const
     {
      for(int i = 0; i < ArraySize(m_slots); i++)
         if(m_slots[i].symbol == symbol && m_slots[i].slot == slot)
            return i;
      return -1;
     }

   int               FindSnapshot(const string symbol) const
     {
      for(int i = 0; i < ArraySize(m_snapshots); i++)
         if(m_snapshots[i].symbol == symbol)
            return i;
      return -1;
     }

   //+---------------------------------------------------------------+
   //| ATR percentile: where does today's ATR sit inside its own      |
   //| recent distribution? Comparable across symbols and eras, which |
   //| a raw ATR value is not.                                        |
   //+---------------------------------------------------------------+
   double            AtrPercentile(const int handle, const int lookback, const double current) const
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      int want = lookback + 1;
      if(CopyBuffer(handle, 0, 0, want, buf) < want)
         return 0.5;   // not enough history yet: assume mid-range

      int below = 0;
      int counted = 0;
      for(int i = 1; i < want; i++)     // skip [0], the forming bar
        {
         if(buf[i] <= 0.0)
            continue;
         counted++;
         if(buf[i] < current)
            below++;
        }
      if(counted == 0)
         return 0.5;
      return (double)below / (double)counted;
     }

   //+---------------------------------------------------------------+
   //| Candle pattern flags on the last closed bar.                   |
   //+---------------------------------------------------------------+
   int               CandleFlags(const string symbol, const ENUM_TIMEFRAMES tf) const
     {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(symbol, tf, 0, 10, r) < 9)
         return CANDLE_NONE;

      //--- r[0] is forming; r[1] is the last closed bar
      int flags = CANDLE_NONE;
      double hi = r[1].high, lo = r[1].low, op = r[1].open, cl = r[1].close;
      double rng = hi - lo;
      if(rng <= 0.0)
         return CANDLE_NONE;

      double body = MathAbs(cl - op);
      double upper_wick = hi - MathMax(op, cl);
      double lower_wick = MathMin(op, cl) - lo;

      //--- inside / outside relative to the prior bar
      if(hi <= r[2].high && lo >= r[2].low)
         flags |= CANDLE_INSIDE_BAR;
      if(hi > r[2].high && lo < r[2].low)
         flags |= CANDLE_OUTSIDE_BAR;

      //--- NR7: narrowest range of the last seven closed bars -> coil
      bool nr7 = true;
      for(int i = 2; i <= 7; i++)
         if((r[i].high - r[i].low) <= rng)
           {
            nr7 = false;
            break;
           }
      if(nr7)
         flags |= CANDLE_NR7;

      //--- wide range: more than 1.5x the mean of the prior six
      double mean = 0.0;
      for(int i = 2; i <= 7; i++)
         mean += (r[i].high - r[i].low);
      mean /= 6.0;
      if(mean > 0.0 && rng > 1.5 * mean)
         flags |= CANDLE_WIDE_RANGE;

      //--- doji / pins
      if(body <= 0.1 * rng)
         flags |= CANDLE_DOJI;
      if(lower_wick >= 2.0 * body && lower_wick > upper_wick)
         flags |= CANDLE_PIN_BULL;
      if(upper_wick >= 2.0 * body && upper_wick > lower_wick)
         flags |= CANDLE_PIN_BEAR;

      //--- engulfing
      double pbody_hi = MathMax(r[2].open, r[2].close);
      double pbody_lo = MathMin(r[2].open, r[2].close);
      if(cl > op && cl >= pbody_hi && op <= pbody_lo)
         flags |= CANDLE_ENGULF_BULL;
      if(cl < op && op >= pbody_hi && cl <= pbody_lo)
         flags |= CANDLE_ENGULF_BEAR;

      return flags;
     }

   //+---------------------------------------------------------------+
   //| The classifier. ATR percentile + ADX + candle flags -> regime. |
   //|                                                                |
   //| === TUNE ME === thresholds are first-guess defaults. The whole |
   //| point of the walk-forward harness is to calibrate these per    |
   //| symbol; XAUUSD and US100 almost certainly want different ones. |
   //+---------------------------------------------------------------+
   ENUM_REGIME       Classify(const SRegimeTF &m, double &confidence) const
     {
      SRegimeConfig rc = m_cfg.Regime();
      confidence = 0.0;

      bool trending    = (m.adx >= rc.adx_trend_threshold);
      bool ranging     = (m.adx <= rc.adx_range_threshold);
      bool vol_high    = (m.atr_percentile >= rc.atr_high_percentile);
      bool vol_low     = (m.atr_percentile <= rc.atr_low_percentile);
      bool coiled      = ((m.candle_flags & (CANDLE_NR7 | CANDLE_INSIDE_BAR)) != 0);
      bool expanding   = ((m.candle_flags & (CANDLE_WIDE_RANGE | CANDLE_OUTSIDE_BAR)) != 0);
      double di_spread = MathAbs(m.di_plus - m.di_minus);

      //--- breakout: volatility expanding out of a coil -------------
      if(expanding && vol_high && !ranging)
        {
         //--- confidence scales with how far past the threshold we are
         confidence = MathMin(1.0, 0.5 + (m.atr_percentile - rc.atr_high_percentile) * 2.0);
         return REGIME_BREAKOUT;
        }

      //--- directional trend ----------------------------------------
      if(trending && di_spread >= 5.0)
        {
         double adx_conf = MathMin(1.0, (m.adx - rc.adx_trend_threshold) / 25.0 + 0.5);
         double di_conf  = MathMin(1.0, di_spread / 30.0);
         confidence = MathMin(1.0, 0.5 * adx_conf + 0.5 * di_conf);
         return (m.di_plus > m.di_minus ? REGIME_TREND_UP : REGIME_TREND_DOWN);
        }

      //--- high volatility with no direction: the account killer ----
      if(vol_high && ranging)
        {
         confidence = MathMin(1.0, 0.5 + (m.atr_percentile - rc.atr_high_percentile) * 2.0);
         return REGIME_CHOP_HIVOL;
        }

      //--- quiet range ----------------------------------------------
      if(ranging && (vol_low || coiled))
        {
         double adx_conf = MathMin(1.0, (rc.adx_range_threshold - m.adx) / 15.0 + 0.5);
         confidence = MathMax(0.3, MathMin(1.0, adx_conf));
         return REGIME_RANGE;
        }

      confidence = 0.25;
      return REGIME_UNKNOWN;
     }

   //+---------------------------------------------------------------+
   //| Weighted vote across M15/H1/H4 -> one composite regime.        |
   //+---------------------------------------------------------------+
   void              Composite(SRegimeSnapshot &snap) const
     {
      //--- copy the config struct out before touching its array member:
      //--- indexing an array on a returned temporary is not portable
      SRegimeConfig rc = m_cfg.Regime();

      double score[6];
      ArrayInitialize(score, 0.0);

      double total_w = 0.0;
      for(int s = 0; s < TF_SLOT_COUNT; s++)
        {
         double w = rc.tf_weight[s] * snap.tf[s].confidence;
         score[(int)snap.tf[s].regime] += w;
         total_w += rc.tf_weight[s];
        }

      int    best = (int)REGIME_UNKNOWN;
      double best_score = -1.0;
      for(int r = 0; r < 6; r++)
         if(score[r] > best_score)
           {
            best_score = score[r];
            best = r;
           }

      snap.composite      = (ENUM_REGIME)best;
      snap.composite_conf = (total_w > 0.0 ? MathMin(1.0, best_score / total_w) : 0.0);

      //--- "aligned" = every timeframe agrees on the same regime.
      //--- Strategies use this to size conviction, not just to gate.
      snap.aligned = (snap.tf[0].regime == snap.tf[1].regime &&
                      snap.tf[1].regime == snap.tf[2].regime);

      if(snap.composite_conf < rc.min_composite_confidence)
         snap.composite = REGIME_UNKNOWN;
     }

public:
                     CRegimeDetector(void) : m_cfg(NULL), m_log(NULL) {}

                    ~CRegimeDetector(void) { Release(); }

   //+---------------------------------------------------------------+
   //| Create every indicator handle up front. Doing this per tick    |
   //| would be a performance disaster.                               |
   //+---------------------------------------------------------------+
   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;

      int nsym = m_cfg.SymbolCount();
      ArrayResize(m_slots, nsym * TF_SLOT_COUNT);
      ArrayResize(m_snapshots, nsym);

      int k = 0;
      for(int s = 0; s < nsym; s++)
        {
         string sym = m_cfg.SymbolAt(s);
         m_snapshots[s].symbol       = sym;
         m_snapshots[s].composite    = REGIME_UNKNOWN;
         m_snapshots[s].evaluated_at = 0;

         for(int t = 0; t < TF_SLOT_COUNT; t++)
           {
            ENUM_TF_SLOT    slot = (ENUM_TF_SLOT)t;
            ENUM_TIMEFRAMES tf   = TfSlotToTimeframe(slot);

            m_slots[k].symbol       = sym;
            m_slots[k].slot         = slot;
            m_slots[k].current      = REGIME_UNKNOWN;
            m_slots[k].pending      = REGIME_UNKNOWN;
            m_slots[k].pending_bars = 0;
            m_slots[k].last_bar     = 0;

            m_slots[k].h_atr = iATR(sym, tf, m_cfg.Regime().atr_period);
            m_slots[k].h_adx = iADX(sym, tf, m_cfg.Regime().adx_period);

            if(m_slots[k].h_atr == INVALID_HANDLE || m_slots[k].h_adx == INVALID_HANDLE)
              {
               if(m_log != NULL)
                  m_log.Warn(StringFormat("indicator handle failed for %s %s (err %d)",
                                          sym, TfSlotToString(slot), GetLastError()));
               return false;
              }
            k++;
           }
        }

      if(m_log != NULL)
         m_log.Info(StringFormat("regime detector ready: %d symbols x %d timeframes",
                                 nsym, TF_SLOT_COUNT));
      return true;
     }

   void              Release(void)
     {
      for(int i = 0; i < ArraySize(m_slots); i++)
        {
         if(m_slots[i].h_atr != INVALID_HANDLE)
            IndicatorRelease(m_slots[i].h_atr);
         if(m_slots[i].h_adx != INVALID_HANDLE)
            IndicatorRelease(m_slots[i].h_adx);
        }
      ArrayResize(m_slots, 0);
     }

   //+---------------------------------------------------------------+
   //| Evaluate one symbol across all three timeframes.               |
   //+---------------------------------------------------------------+
   bool              Evaluate(const string symbol, SRegimeSnapshot &out)
     {
      int si = FindSnapshot(symbol);
      if(si < 0)
         return false;

      SRegimeSnapshot snap;
      snap.symbol       = symbol;
      snap.evaluated_at = TimeCurrent();

      for(int t = 0; t < TF_SLOT_COUNT; t++)
        {
         ENUM_TF_SLOT slot = (ENUM_TF_SLOT)t;
         int idx = FindSlot(symbol, slot);
         if(idx < 0)
            return false;

         ENUM_TIMEFRAMES tf = TfSlotToTimeframe(slot);

         double atr_buf[], adx_buf[], dip_buf[], dim_buf[];
         ArraySetAsSeries(atr_buf, true);
         ArraySetAsSeries(adx_buf, true);
         ArraySetAsSeries(dip_buf, true);
         ArraySetAsSeries(dim_buf, true);

         //--- index 1 = last closed bar; never classify on a forming bar
         if(CopyBuffer(m_slots[idx].h_atr, 0, 0, 3, atr_buf) < 3 ||
            CopyBuffer(m_slots[idx].h_adx, 0, 0, 3, adx_buf) < 3 ||
            CopyBuffer(m_slots[idx].h_adx, 1, 0, 3, dip_buf) < 3 ||
            CopyBuffer(m_slots[idx].h_adx, 2, 0, 3, dim_buf) < 3)
           {
            //--- indicators still warming up
            snap.tf[t].regime     = REGIME_UNKNOWN;
            snap.tf[t].confidence = 0.0;
            continue;
           }

         double price = SymbolInfoDouble(symbol, SYMBOL_BID);

         SRegimeTF m;
         m.atr            = atr_buf[1];
         m.atr_pct        = (price > 0.0 ? m.atr / price : 0.0);
         m.atr_percentile = AtrPercentile(m_slots[idx].h_atr,
                                          m_cfg.Regime().atr_percentile_lookback, m.atr);
         m.adx            = adx_buf[1];
         m.di_plus        = dip_buf[1];
         m.di_minus       = dim_buf[1];
         m.candle_flags   = CandleFlags(symbol, tf);

         double conf = 0.0;
         ENUM_REGIME raw = Classify(m, conf);
         m.confidence = conf;

         //--- hysteresis: a new regime must persist before we act on it
         datetime bar_time = iTime(symbol, tf, 0);
         bool new_bar = (bar_time != m_slots[idx].last_bar);
         if(new_bar)
            m_slots[idx].last_bar = bar_time;

         ENUM_REGIME prev = m_slots[idx].current;

         if(raw == m_slots[idx].current)
           {
            m_slots[idx].pending      = raw;
            m_slots[idx].pending_bars = 0;
           }
         else
           {
            if(raw == m_slots[idx].pending)
              {
               if(new_bar)
                  m_slots[idx].pending_bars++;
              }
            else
              {
               m_slots[idx].pending      = raw;
               m_slots[idx].pending_bars = 0;
              }

            if(m_slots[idx].pending_bars >= m_cfg.Regime().min_bars_in_regime)
              {
               m_slots[idx].current      = raw;
               m_slots[idx].pending_bars = 0;
              }
           }

         m.regime   = m_slots[idx].current;
         snap.tf[t] = m;

         //--- log only genuine transitions, not every heartbeat
         if(m_log != NULL && prev != m_slots[idx].current)
            m_log.Regime(symbol, slot, m, prev, snap);
        }

      Composite(snap);
      m_snapshots[si] = snap;
      out = snap;
      return true;
     }

   bool              Snapshot(const string symbol, SRegimeSnapshot &out) const
     {
      int i = FindSnapshot(symbol);
      if(i < 0)
         return false;
      out = m_snapshots[i];
      return true;
     }
  };

#endif // __ADAPTIVE_REGIMEDETECTOR_MQH__

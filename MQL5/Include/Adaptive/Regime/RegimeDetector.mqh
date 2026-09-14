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
#include "RegimeFeatures.mqh"

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
   SRegimeConfig     rc;           // per-symbol, resolved once at Init
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
   //| ATR expansion: current ATR against its own recent mean. Scale-  |
   //| free, so the same ramp bounds work on gold and on an index.     |
   //+---------------------------------------------------------------+
   double            AtrExpansion(const int handle, const int lookback, const double current) const
     {
      double buf[];
      ArraySetAsSeries(buf, true);
      int want = lookback + 2;
      if(CopyBuffer(handle, 0, 0, want, buf) < want)
         return 1.0;

      double sum = 0.0;
      int    n = 0;
      for(int i = 2; i < want; i++)     // skip [0] forming and [1] current
        {
         if(buf[i] <= 0.0)
            continue;
         sum += buf[i];
         n++;
        }
      if(n == 0 || sum <= 0.0)
         return 1.0;
      double mean = sum / (double)n;
      return (mean > 0.0 ? current / mean : 1.0);
     }

   //+---------------------------------------------------------------+
   //| Weighted vote across M15/H1/H4 -> one composite regime.        |
   //+---------------------------------------------------------------+
   void              Composite(SRegimeSnapshot &snap, const SRegimeConfig &rc) const
     {
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
         SRegimeConfig rc = m_cfg.RegimeFor(sym);
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
            m_slots[k].rc           = rc;

            m_slots[k].h_atr = iATR(sym, tf, rc.atr_period);
            m_slots[k].h_adx = iADX(sym, tf, rc.adx_period);

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

      //--- one resolved config for this symbol, used by every timeframe
      //--- and by the composite vote below
      int h1 = FindSlot(symbol, TF_SLOT_H1);
      if(h1 < 0)
         return false;
      SRegimeConfig sym_rc = m_slots[h1].rc;

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
         SRegimeConfig rc = m_slots[idx].rc;

         //--- the bars the candle and compression features need.
         //--- r[0] is forming, so classify r[1]: offset 1 throughout.
         MqlRates rates[];
         ArraySetAsSeries(rates, true);
         int need = rc.compression_lookback + 10;
         if(CopyRates(symbol, tf, 0, need, rates) < need)
           {
            snap.tf[t].regime     = REGIME_UNKNOWN;
            snap.tf[t].confidence = 0.0;
            continue;
           }

         SRegimeTF m;
         m.atr            = atr_buf[1];
         m.atr_pct        = (price > 0.0 ? m.atr / price : 0.0);
         m.atr_percentile = AtrPercentile(m_slots[idx].h_atr, rc.atr_percentile_lookback, m.atr);
         m.atr_expansion  = AtrExpansion(m_slots[idx].h_atr, rc.atr_percentile_lookback, m.atr);
         m.adx            = adx_buf[1];
         m.di_plus        = dip_buf[1];
         m.di_minus       = dim_buf[1];

         double di_sum    = m.di_plus + m.di_minus;
         m.di_spread_norm = (di_sum > 0.0 ? MathAbs(m.di_plus - m.di_minus) / di_sum : 0.0);

         m.candle_flags   = ComputeCandleFlags(rates, 1);
         m.compression    = ComputeCompression(rates, 1, rc.compression_lookback);

         //--- identical call to the one the offline exporter makes
         SRegimeScores scores;
         ComputeRegimeScores(m, rc, scores);
         double conf = 0.0;
         ENUM_REGIME raw = ClassifyFromScores(scores, rc, conf);
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

            if(m_slots[idx].pending_bars >= rc.min_bars_in_regime)
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

      Composite(snap, sym_rc);
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

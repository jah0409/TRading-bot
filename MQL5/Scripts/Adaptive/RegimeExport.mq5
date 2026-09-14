//+------------------------------------------------------------------+
//|                                                  RegimeExport.mq5 |
//|  Dump regime features + forward outcomes to CSV for calibration.  |
//|                                                                    |
//|  Run this as a SCRIPT (not an EA) on any chart. For each symbol    |
//|  and timeframe it walks history, computes the features EXACTLY as  |
//|  CRegimeDetector does live - same shared functions, same bar       |
//|  offsets - and writes them alongside forward-looking outcome       |
//|  columns that tools/calibrate_regime.py turns into ground truth.   |
//|                                                                    |
//|  Output: MQL5/Files/Adaptive/calib/features_<SYMBOL>_<TF>.csv      |
//|                                                                    |
//|  Then, outside the terminal:                                       |
//|    python3 tools/calibrate_regime.py --features <that file> \      |
//|            --symbol XAUUSD --emit-config                           |
//+------------------------------------------------------------------+
#property copyright "Adaptive EA"
#property version   "1.00"
#property script_show_inputs

#include <Adaptive/Core/Types.mqh>
#include <Adaptive/Core/Config.mqh>
#include <Adaptive/Regime/RegimeFeatures.mqh>

input string InpConfigPath   = "Adaptive\\config.json"; // Config (for periods/ramps)
input string InpSymbols      = "";                      // Symbols CSV ("" = use config)
input int    InpBars         = 20000;                   // Bars of history per timeframe
input int    InpForwardBars  = 24;                      // Forward horizon for outcomes
input string InpOutDir       = "Adaptive\\calib";       // Output folder under MQL5/Files

//+------------------------------------------------------------------+
//| Forward-looking outcome columns.                                  |
//|                                                                   |
//| These are what make calibration possible: for each bar we record  |
//| what the market ACTUALLY did next, so the Python side can derive  |
//| ground-truth labels and measure what each strategy family would   |
//| have earned. Nothing here is available to the live EA - that is   |
//| the point, and it is also why this must never leak into the       |
//| detector.                                                         |
//+------------------------------------------------------------------+
struct SForward
  {
   double            ret;              // close[t+H]/close[t] - 1
   double            efficiency;       // |net move| / sum|bar moves|  (0..1)
   double            mae;              // max adverse excursion, in ATR
   double            mfe;              // max favourable excursion, in ATR
   double            realised_vol;     // stdev of forward bar returns
   double            vol_ratio;        // forward realised vol / trailing ATR%
   bool              valid;
  };

//--- r is series-ordered (r[0] newest). `offset` is the bar we are
//--- classifying; the future is at LOWER indices.
bool ComputeForward(const MqlRates &r[], const int offset, const int horizon,
                    const double atr, SForward &out)
  {
   out.valid = false;
   if(offset - horizon < 0 || atr <= 0.0)
      return false;

   double c0 = r[offset].close;
   if(c0 <= 0.0)
      return false;

   double cH = r[offset - horizon].close;

   double path = 0.0;
   double hi   = c0, lo = c0;
   double sum = 0.0, sumsq = 0.0;
   int    n = 0;

   for(int i = offset; i > offset - horizon; i--)
     {
      double a = r[i].close;
      double b = r[i - 1].close;
      if(a <= 0.0 || b <= 0.0)
         return false;
      path += MathAbs(b - a);
      double rr = b / a - 1.0;
      sum   += rr;
      sumsq += rr * rr;
      n++;
      if(r[i - 1].high > hi) hi = r[i - 1].high;
      if(r[i - 1].low  < lo) lo = r[i - 1].low;
     }
   if(n < 2)
      return false;

   out.ret        = cH / c0 - 1.0;
   out.efficiency = (path > 0.0 ? MathAbs(cH - c0) / path : 0.0);
   out.mfe        = (hi - c0) / atr;
   out.mae        = (c0 - lo) / atr;

   double mean = sum / (double)n;
   double var  = MathMax(0.0, sumsq / (double)n - mean * mean);
   out.realised_vol = MathSqrt(var);
   out.vol_ratio    = (atr / c0 > 0.0 ? out.realised_vol / (atr / c0) : 0.0);
   out.valid = true;
   return true;
  }

//+------------------------------------------------------------------+
int ExportOne(CConfig &cfg, const string symbol, const ENUM_TF_SLOT slot)
  {
   ENUM_TIMEFRAMES tf = TfSlotToTimeframe(slot);
   SRegimeConfig   rc = cfg.RegimeFor(symbol);

   if(!SymbolSelect(symbol, true))
     {
      PrintFormat("RegimeExport: symbol '%s' unavailable", symbol);
      return 0;
     }

   int h_atr = iATR(symbol, tf, rc.atr_period);
   int h_adx = iADX(symbol, tf, rc.adx_period);
   if(h_atr == INVALID_HANDLE || h_adx == INVALID_HANDLE)
     {
      PrintFormat("RegimeExport: indicator handles failed for %s %s", symbol, TfSlotToString(slot));
      return 0;
     }

   //--- give the indicators time to calculate over the full range
   int warm = 0;
   while(BarsCalculated(h_atr) < 0 && warm++ < 50) Sleep(200);
   while(BarsCalculated(h_adx) < 0 && warm++ < 100) Sleep(200);

   int want = MathMin(InpBars, Bars(symbol, tf));
   if(want < 500)
     {
      PrintFormat("RegimeExport: only %d bars for %s %s, skipping", want, symbol, TfSlotToString(slot));
      IndicatorRelease(h_atr); IndicatorRelease(h_adx);
      return 0;
     }

   MqlRates rates[];
   double   atr[], adx[], dip[], dim[];
   ArraySetAsSeries(rates, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(adx, true);
   ArraySetAsSeries(dip, true);
   ArraySetAsSeries(dim, true);

   if(CopyRates(symbol, tf, 0, want, rates) < want ||
      CopyBuffer(h_atr, 0, 0, want, atr) < want ||
      CopyBuffer(h_adx, 0, 0, want, adx) < want ||
      CopyBuffer(h_adx, 1, 0, want, dip) < want ||
      CopyBuffer(h_adx, 2, 0, want, dim) < want)
     {
      PrintFormat("RegimeExport: history copy failed for %s %s (err %d)",
                  symbol, TfSlotToString(slot), GetLastError());
      IndicatorRelease(h_atr); IndicatorRelease(h_adx);
      return 0;
     }

   string path = StringFormat("%s\\features_%s_%s.csv", InpOutDir, symbol, TfSlotToString(slot));
   int f = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(f == INVALID_HANDLE)
     {
      PrintFormat("RegimeExport: cannot write %s (err %d)", path, GetLastError());
      IndicatorRelease(h_atr); IndicatorRelease(h_adx);
      return 0;
     }

   FileWriteString(f,
      "time,symbol,tf,close,atr,atr_pct,atr_percentile,atr_expansion,adx,di_plus,di_minus,"
      "di_spread_norm,candle_flags,compression,"
      "score_trend_up,score_trend_down,score_range,score_breakout,score_chop,"
      "regime_live,confidence,"
      "fwd_ret,fwd_efficiency,fwd_mae_atr,fwd_mfe_atr,fwd_vol_ratio\r\n");

   //--- leave room for the percentile/compression lookback at the old
   //--- end and the forward horizon at the new end
   int lookback_pad = MathMax(rc.atr_percentile_lookback, rc.compression_lookback) + 12;
   int rows = 0;

   for(int i = want - lookback_pad; i > InpForwardBars; i--)
     {
      if(atr[i] <= 0.0 || rates[i].close <= 0.0)
         continue;

      //--- ATR percentile over the window that PRECEDES bar i
      int    below = 0, counted = 0;
      for(int k = i + 1; k <= i + rc.atr_percentile_lookback && k < want; k++)
        {
         if(atr[k] <= 0.0)
            continue;
         counted++;
         if(atr[k] < atr[i])
            below++;
        }
      double pct = (counted > 0 ? (double)below / (double)counted : 0.5);

      //--- ATR expansion against the same preceding window
      double sum = 0.0;
      int    n = 0;
      for(int k = i + 1; k <= i + rc.atr_percentile_lookback && k < want; k++)
        {
         if(atr[k] <= 0.0)
            continue;
         sum += atr[k];
         n++;
        }
      double expansion = (n > 0 && sum > 0.0 ? atr[i] / (sum / (double)n) : 1.0);

      SRegimeTF m;
      m.atr            = atr[i];
      m.atr_pct        = atr[i] / rates[i].close;
      m.atr_percentile = pct;
      m.atr_expansion  = expansion;
      m.adx            = adx[i];
      m.di_plus        = dip[i];
      m.di_minus       = dim[i];
      double di_sum    = dip[i] + dim[i];
      m.di_spread_norm = (di_sum > 0.0 ? MathAbs(dip[i] - dim[i]) / di_sum : 0.0);
      m.candle_flags   = ComputeCandleFlags(rates, i);
      m.compression    = ComputeCompression(rates, i, rc.compression_lookback);
      m.regime         = REGIME_UNKNOWN;
      m.confidence     = 0.0;

      //--- the very same calls the live detector makes
      SRegimeScores sc;
      ComputeRegimeScores(m, rc, sc);
      double conf = 0.0;
      ENUM_REGIME live = ClassifyFromScores(sc, rc, conf);

      SForward fw;
      if(!ComputeForward(rates, i, InpForwardBars, atr[i], fw))
         continue;

      FileWriteString(f, StringFormat(
         "%s,%s,%s,%.5f,%.6f,%.8f,%.5f,%.5f,%.3f,%.3f,%.3f,%.5f,%d,%.5f,"
         "%.5f,%.5f,%.5f,%.5f,%.5f,%s,%.5f,"
         "%.8f,%.5f,%.5f,%.5f,%.5f\r\n",
         TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES), symbol, TfSlotToString(slot),
         rates[i].close, m.atr, m.atr_pct, m.atr_percentile, m.atr_expansion,
         m.adx, m.di_plus, m.di_minus, m.di_spread_norm, m.candle_flags, m.compression,
         sc.trend_up, sc.trend_down, sc.range, sc.breakout, sc.chop,
         RegimeToString(live), conf,
         fw.ret, fw.efficiency, fw.mae, fw.mfe, fw.vol_ratio));
      rows++;
     }

   FileClose(f);
   IndicatorRelease(h_atr);
   IndicatorRelease(h_adx);

   PrintFormat("RegimeExport: %s %s -> %s (%d rows)", symbol, TfSlotToString(slot), path, rows);
   return rows;
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   CConfig cfg;
   if(!cfg.Load(InpConfigPath))
     {
      Print("RegimeExport: config load failed: ", cfg.LastError());
      return;
     }

   if(!FolderCreate(InpOutDir, 0))
     {
      int err = GetLastError();
      if(err != 0 && err != 5019)
         PrintFormat("RegimeExport: FolderCreate('%s') err %d", InpOutDir, err);
      ResetLastError();
     }

   string syms[];
   if(InpSymbols != "")
      StringSplit(InpSymbols, ',', syms);
   else
     {
      ArrayResize(syms, cfg.SymbolCount());
      for(int i = 0; i < cfg.SymbolCount(); i++)
         syms[i] = cfg.SymbolAt(i);
     }

   int total = 0;
   for(int i = 0; i < ArraySize(syms); i++)
     {
      string sym = syms[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(sym == "")
         continue;
      for(int t = 0; t < TF_SLOT_COUNT; t++)
         total += ExportOne(cfg, sym, (ENUM_TF_SLOT)t);
     }

   PrintFormat("RegimeExport: done, %d rows total. Next: "
               "python3 tools/calibrate_regime.py --features <file> --symbol <SYM> --emit-config",
               total);
  }
//+------------------------------------------------------------------+

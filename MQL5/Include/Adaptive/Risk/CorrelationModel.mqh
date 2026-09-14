//+------------------------------------------------------------------+
//| CorrelationModel.mqh - rolling correlation between traded symbols |
//|                                                                    |
//| XAUUSD and US100 are not independent bets. Both carry a large USD  |
//| and real-rates factor and both go risk-off together, so being long |
//| each of them at 1% is not 2% spread across two ideas - much of the |
//| time it is closer to a single 2% bet on one factor.                |
//|                                                                    |
//| This estimates that, and the risk manager uses it to cap           |
//| CONCENTRATED directional exposure:                                 |
//|                                                                    |
//|     portfolio risk = sqrt( SUM_i SUM_j  r_i r_j rho_ij )           |
//|                                                                    |
//| with r signed (+ for long, - for short), so an actual hedge shows  |
//| up as a small number and a doubled-up bet shows up as a large one. |
//|                                                                    |
//| IMPORTANT - this only ever ADDS a constraint. The aggregate        |
//| sum-of-stops cap stays the plain arithmetic sum of absolute risks,  |
//| because correlation is an estimate of TYPICAL behaviour and the    |
//| thing that breaches a prop account is the atypical day when        |
//| everything gaps through its stop at once. A correlation estimate   |
//| must never be allowed to justify carrying more total risk.         |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_CORRELATIONMODEL_MQH__
#define __ADAPTIVE_CORRELATIONMODEL_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"

class CCorrelationModel
  {
private:
   CConfig          *m_cfg;
   CLogger          *m_log;

   string            m_symbols[];
   int               m_n;

   //--- flat n*n matrices; index with Idx(i,j)
   double            m_rho[];
   bool              m_known[];

   datetime          m_last_update;
   bool              m_enabled;
   ENUM_TIMEFRAMES   m_tf;
   int               m_lookback;
   int               m_min_samples;
   int               m_refresh_minutes;
   double            m_assume_unknown;

   int               Idx(const int i, const int j) const { return i * m_n + j; }

   int               SymbolIndex(const string s) const
     {
      for(int i = 0; i < m_n; i++)
         if(m_symbols[i] == s)
            return i;
      return -1;
     }

   //+---------------------------------------------------------------+
   //| Pearson correlation of log returns, aligned on BAR TIME.       |
   //|                                                                |
   //| Aligning matters: two symbols can have different session       |
   //| breaks and missing bars, and correlating index-by-index across  |
   //| a holiday gap silently compares Tuesday with Wednesday.         |
   //+---------------------------------------------------------------+
   bool              PairCorrelation(const datetime &ta[], const double &ra[], const int na,
                                     const datetime &tb[], const double &rb[], const int nb,
                                     double &rho, int &used) const
     {
      rho = 0.0;
      used = 0;
      if(na < 2 || nb < 2)
         return false;

      double sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0;

      //--- two-pointer merge over sorted (chronological) times
      int i = 0, j = 0;
      while(i < na && j < nb)
        {
         if(ta[i] < tb[j])      { i++; continue; }
         if(ta[i] > tb[j])      { j++; continue; }
         double x = ra[i], y = rb[j];
         sa  += x;   sb  += y;
         saa += x*x; sbb += y*y; sab += x*y;
         used++;
         i++; j++;
        }

      if(used < m_min_samples)
         return false;

      double n   = (double)used;
      double cov = sab / n - (sa / n) * (sb / n);
      double va  = saa / n - (sa / n) * (sa / n);
      double vb  = sbb / n - (sb / n) * (sb / n);
      if(va <= 0.0 || vb <= 0.0)
         return false;

      rho = cov / MathSqrt(va * vb);
      rho = MathMax(-1.0, MathMin(1.0, rho));
      return true;
     }

   //--- log returns for one symbol, chronological order
   int               LoadReturns(const string symbol, datetime &times[], double &rets[]) const
     {
      MqlRates r[];
      ArraySetAsSeries(r, false);            // oldest first
      int got = CopyRates(symbol, m_tf, 0, m_lookback + 1, r);
      if(got < 2)
         return 0;

      ArrayResize(times, got - 1);
      ArrayResize(rets, got - 1);
      int k = 0;
      for(int i = 1; i < got; i++)
        {
         if(r[i - 1].close <= 0.0 || r[i].close <= 0.0)
            continue;
         times[k] = r[i].time;
         rets[k]  = MathLog(r[i].close / r[i - 1].close);
         k++;
        }
      ArrayResize(times, k);
      ArrayResize(rets, k);
      return k;
     }

public:
                     CCorrelationModel(void) : m_cfg(NULL), m_log(NULL), m_n(0),
                                               m_last_update(0), m_enabled(true),
                                               m_tf(PERIOD_H1), m_lookback(500),
                                               m_min_samples(100), m_refresh_minutes(15),
                                               m_assume_unknown(1.0) {}

   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;

      m_enabled         = m_cfg.Json().GetBool("correlation.enabled", true);
      int tf_min        = m_cfg.Json().GetInt("correlation.timeframe_minutes", 60);
      m_tf              = (tf_min >= 240 ? PERIOD_H4 : (tf_min >= 60 ? PERIOD_H1 : PERIOD_M15));
      m_lookback        = m_cfg.Json().GetInt("correlation.lookback_bars", 500);
      m_min_samples     = m_cfg.Json().GetInt("correlation.min_samples", 100);
      m_refresh_minutes = m_cfg.Json().GetInt("correlation.refresh_minutes", 15);
      //--- what to assume for a pair we cannot measure. Default +1.0:
      //--- treat unknown as perfectly correlated, i.e. fail safe.
      m_assume_unknown  = m_cfg.Json().GetDouble("correlation.assume_when_unknown", 1.0);

      m_n = m_cfg.SymbolCount();
      ArrayResize(m_symbols, m_n);
      for(int i = 0; i < m_n; i++)
         m_symbols[i] = m_cfg.SymbolAt(i);

      ArrayResize(m_rho, m_n * m_n);
      ArrayResize(m_known, m_n * m_n);
      for(int i = 0; i < m_n; i++)
         for(int j = 0; j < m_n; j++)
           {
            m_rho[Idx(i, j)]   = (i == j ? 1.0 : m_assume_unknown);
            m_known[Idx(i, j)] = (i == j);
           }

      Update(true);
      return true;
     }

   //+---------------------------------------------------------------+
   //| Recompute the matrix. Self-rate-limiting.                      |
   //+---------------------------------------------------------------+
   void              Update(const bool force = false)
     {
      if(!m_enabled || m_n < 2)
         return;
      datetime now = TimeCurrent();
      if(!force && m_last_update > 0 &&
         (now - m_last_update) < m_refresh_minutes * 60)
         return;
      m_last_update = now;

      //--- load every symbol once, not once per pair
      datetime times[];
      double   rets[];
      int      counts[];
      ArrayResize(counts, m_n);

      //--- flat storage: symbol i occupies [i*m_lookback, i*m_lookback+counts[i])
      datetime all_t[];
      double   all_r[];
      ArrayResize(all_t, m_n * (m_lookback + 2));
      ArrayResize(all_r, m_n * (m_lookback + 2));

      for(int i = 0; i < m_n; i++)
        {
         counts[i] = LoadReturns(m_symbols[i], times, rets);
         int base = i * (m_lookback + 2);
         for(int k = 0; k < counts[i]; k++)
           {
            all_t[base + k] = times[k];
            all_r[base + k] = rets[k];
           }
        }

      string report = "";
      for(int i = 0; i < m_n; i++)
        {
         for(int j = i + 1; j < m_n; j++)
           {
            datetime ta[], tb[];
            double   ra[], rb[];
            ArrayResize(ta, counts[i]); ArrayResize(ra, counts[i]);
            ArrayResize(tb, counts[j]); ArrayResize(rb, counts[j]);
            int bi = i * (m_lookback + 2), bj = j * (m_lookback + 2);
            for(int k = 0; k < counts[i]; k++) { ta[k] = all_t[bi + k]; ra[k] = all_r[bi + k]; }
            for(int k = 0; k < counts[j]; k++) { tb[k] = all_t[bj + k]; rb[k] = all_r[bj + k]; }

            double rho = 0.0;
            int    used = 0;
            bool   ok = PairCorrelation(ta, ra, counts[i], tb, rb, counts[j], rho, used);

            if(ok)
              {
               m_rho[Idx(i, j)]   = rho;
               m_rho[Idx(j, i)]   = rho;
               m_known[Idx(i, j)] = true;
               m_known[Idx(j, i)] = true;
              }
            else
              {
               //--- not enough overlap: assume the worst rather than zero
               m_rho[Idx(i, j)]   = m_assume_unknown;
               m_rho[Idx(j, i)]   = m_assume_unknown;
               m_known[Idx(i, j)] = false;
               m_known[Idx(j, i)] = false;
              }

            report += StringFormat("%s/%s=%.3f%s(n=%d) ",
                                   m_symbols[i], m_symbols[j],
                                   m_rho[Idx(i, j)], (ok ? "" : "*assumed*"), used);
           }
        }

      if(m_log != NULL && report != "")
         m_log.Risk("CORRELATION", "", "", BLOCK_NONE, 0, 0, 0, 0,
                    AccountInfoDouble(ACCOUNT_EQUITY), 0, 0, report);
     }

   //--- rho between two symbols; +1 (worst case) when unmeasurable
   double            Rho(const string a, const string b) const
     {
      if(a == b)
         return 1.0;
      int i = SymbolIndex(a), j = SymbolIndex(b);
      if(i < 0 || j < 0)
         return m_assume_unknown;
      return m_rho[Idx(i, j)];
     }

   bool              IsKnown(const string a, const string b) const
     {
      int i = SymbolIndex(a), j = SymbolIndex(b);
      if(i < 0 || j < 0)
         return false;
      return m_known[Idx(i, j)];
     }

   //+---------------------------------------------------------------+
   //| Correlation-adjusted portfolio risk.                           |
   //|                                                                |
   //|   sqrt( SUM_i SUM_j  r_i r_j rho_ij )                          |
   //|                                                                |
   //| r must be SIGNED: + for a long, - for a short. Two longs in    |
   //| correlated instruments add; a long and a short partly cancel.  |
   //|                                                                |
   //| Pairwise sample correlations need not form a positive          |
   //| semi-definite matrix once there are three or more symbols, so  |
   //| the sum can come out negative. Clamp at zero rather than       |
   //| returning a NaN into a risk check.                             |
   //+---------------------------------------------------------------+
   double            PortfolioRisk(const string &syms[], const double &signed_risk[],
                                   const int count) const
     {
      double total = 0.0;
      for(int i = 0; i < count; i++)
         for(int j = 0; j < count; j++)
           {
            double rho = (i == j ? 1.0 : Rho(syms[i], syms[j]));
            total += signed_risk[i] * signed_risk[j] * rho;
           }
      if(total <= 0.0)
         return 0.0;
      return MathSqrt(total);
     }

   bool              Enabled(void) const { return m_enabled; }

   string            Describe(void) const
     {
      string s = "";
      for(int i = 0; i < m_n; i++)
         for(int j = i + 1; j < m_n; j++)
            s += StringFormat("%s/%s %.2f%s ", m_symbols[i], m_symbols[j],
                              m_rho[Idx(i, j)], (m_known[Idx(i, j)] ? "" : "?"));
      return s;
     }
  };

#endif // __ADAPTIVE_CORRELATIONMODEL_MQH__

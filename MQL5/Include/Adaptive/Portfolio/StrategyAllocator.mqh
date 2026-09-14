//+------------------------------------------------------------------+
//| StrategyAllocator.mqh - who trades right now, and with how much   |
//|                                                                    |
//| Each cycle:                                                        |
//|   score = base_suitability[regime] x performance_adjustment        |
//|   keep scores >= the strategy's own min_suitability_to_run         |
//|   drop anything incompatible with a higher-scoring survivor        |
//|   take the top N, where N comes from the risk phase (2/3/5)        |
//|   split capital between survivors by score x configured weight     |
//|                                                                    |
//| Enable/disable transitions are logged, so the CSV shows exactly    |
//| why the mix changed on any given day.                              |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_STRATEGYALLOCATOR_MQH__
#define __ADAPTIVE_STRATEGYALLOCATOR_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "../Strategies/StrategyBase.mqh"
#include "PerformanceTracker.mqh"

struct SAllocationRow
  {
   string            strategy_id;
   double            base_score;
   double            perf_adj;
   double            final_score;
   bool              enabled;
   double            capital_share;
   string            note;
  };

class CStrategyAllocator
  {
private:
   CConfig              *m_cfg;
   CLogger              *m_log;
   CPerformanceTracker  *m_perf;

   SAllocationRow        m_rows[];
   ENUM_REGIME           m_last_regime;
   string                m_last_symbol;

   //--- distinct strategies enabled anywhere this cycle. The phase cap
   //--- ("max 3 concurrent strategies") counts STRATEGIES, not
   //--- strategy-symbol pairs, so a strategy already live on XAUUSD
   //--- costs nothing extra to also enable on US100.
   string                m_cycle_enabled[];

   //--- config-declared conflicts, e.g. do not run a trend strategy
   //--- and a counter-trend fade on the same symbol at once
   bool                  Incompatible(const string a, const string b) const
     {
      if(a == b)
         return false;
      //--- look up "strategies.<n>.incompatible_with": ["id", ...]
      for(int i = 0; i < m_cfg.StrategyCount(); i++)
        {
         SStrategyConfig sc;
         if(!m_cfg.StrategyAt(i, sc) || sc.id != a)
            continue;
         string list[];
         m_cfg.Json().GetStringArray(sc.json_path + ".incompatible_with", list);
         for(int k = 0; k < ArraySize(list); k++)
            if(list[k] == b)
               return true;
        }
      return false;
     }

   bool                  AlreadyEnabledThisCycle(const string id) const
     {
      for(int i = 0; i < ArraySize(m_cycle_enabled); i++)
         if(m_cycle_enabled[i] == id)
            return true;
      return false;
     }

   void                  MarkEnabledThisCycle(const string id)
     {
      if(AlreadyEnabledThisCycle(id))
         return;
      int n = ArraySize(m_cycle_enabled);
      ArrayResize(m_cycle_enabled, n + 1);
      m_cycle_enabled[n] = id;
     }

   int                   RowIndex(const string id) const
     {
      for(int i = 0; i < ArraySize(m_rows); i++)
         if(m_rows[i].strategy_id == id)
            return i;
      return -1;
     }

public:
                     CStrategyAllocator(void) : m_cfg(NULL), m_log(NULL), m_perf(NULL),
                                                m_last_regime(REGIME_UNKNOWN), m_last_symbol("") {}

   bool              Init(CConfig *cfg, CLogger *log, CPerformanceTracker *perf)
     {
      m_cfg  = cfg;
      m_log  = log;
      m_perf = perf;
      return true;
     }

   //--- call once per main-loop pass, BEFORE the per-symbol Allocate()
   //--- calls, so the concurrency cap is counted across all symbols
   void              BeginCycle(void) { ArrayResize(m_cycle_enabled, 0); }

   int               DistinctEnabled(void) const { return ArraySize(m_cycle_enabled); }

   int               RowCount(void) const { return ArraySize(m_rows); }
   bool              RowAt(const int i, SAllocationRow &out) const
     {
      if(i < 0 || i >= ArraySize(m_rows))
         return false;
      out = m_rows[i];
      return true;
     }

   //+---------------------------------------------------------------+
   //| Score every strategy for the current regime and set the        |
   //| enabled flag on each. Returns how many ended up enabled.       |
   //+---------------------------------------------------------------+
   int               Allocate(CStrategyBase *&strategies[], const SRegimeSnapshot &regime,
                              const int max_concurrent, const double total_capital)
     {
      int n = ArraySize(strategies);
      ArrayResize(m_rows, n);

      //--- 1. raw scores ------------------------------------------------
      for(int i = 0; i < n; i++)
        {
         CStrategyBase *s = strategies[i];
         double base = s.BaseSuitability(regime.composite);
         double adj  = (m_perf != NULL
                        ? m_perf.SuitabilityAdjustment(s.Id(), regime.composite) : 1.0);

         m_rows[i].strategy_id   = s.Id();
         m_rows[i].base_score    = base;
         m_rows[i].perf_adj      = adj;
         m_rows[i].final_score   = base * adj;
         m_rows[i].enabled       = false;
         m_rows[i].capital_share = 0.0;
         m_rows[i].note          = "";

         //--- low-confidence regime reading: nobody trades on a guess
         if(regime.composite == REGIME_UNKNOWN)
           {
            m_rows[i].final_score = 0.0;
            m_rows[i].note        = "regime_unknown";
           }
         else if(base < s.MinSuitability())
            m_rows[i].note = StringFormat("below_min(%.2f<%.2f)", base, s.MinSuitability());
        }

      //--- 2. sort row indices by score, descending ---------------------
      int order[];
      ArrayResize(order, n);
      for(int i = 0; i < n; i++)
         order[i] = i;
      for(int i = 1; i < n; i++)
        {
         int key = order[i];
         int j = i - 1;
         while(j >= 0 && m_rows[order[j]].final_score < m_rows[key].final_score)
           {
            order[j + 1] = order[j];
            j--;
           }
         order[j + 1] = key;
        }

      //--- 3. select, respecting the phase cap and incompatibilities ----
      int    selected = 0;
      double score_sum = 0.0;

      for(int k = 0; k < n; k++)
        {
         int i = order[k];
         CStrategyBase *s = strategies[i];

         if(m_rows[i].final_score <= 0.0)
            continue;
         if(m_rows[i].base_score < s.MinSuitability())
            continue;
         if(!s.TradesSymbol(regime.symbol))
           {
            m_rows[i].note = "symbol_not_allowed";
            continue;
           }

         //--- the cap is on DISTINCT strategies across all symbols
         if(!AlreadyEnabledThisCycle(m_rows[i].strategy_id) &&
            DistinctEnabled() >= max_concurrent)
           {
            m_rows[i].note = StringFormat("phase_cap(%d)", max_concurrent);
            continue;
           }

         //--- does a already-selected, higher-scoring strategy conflict?
         bool conflict = false;
         for(int j = 0; j < k; j++)
           {
            int pi = order[j];
            if(!m_rows[pi].enabled)
               continue;
            if(Incompatible(m_rows[i].strategy_id, m_rows[pi].strategy_id) ||
               Incompatible(m_rows[pi].strategy_id, m_rows[i].strategy_id))
              {
               conflict = true;
               m_rows[i].note = "incompatible_with:" + m_rows[pi].strategy_id;
               break;
              }
           }
         if(conflict)
            continue;

         m_rows[i].enabled = true;
         MarkEnabledThisCycle(m_rows[i].strategy_id);
         selected++;
         score_sum += m_rows[i].final_score;
        }

      //--- 4. split capital across the survivors ------------------------
      for(int i = 0; i < n; i++)
        {
         if(!m_rows[i].enabled || score_sum <= 0.0)
            continue;
         m_rows[i].capital_share = total_capital * (m_rows[i].final_score / score_sum);
        }

      //--- 5. apply, logging only genuine transitions -------------------
      bool regime_changed = (regime.composite != m_last_regime || regime.symbol != m_last_symbol);

      for(int i = 0; i < n; i++)
        {
         CStrategyBase *s = strategies[i];
         bool was = s.IsEnabledFor(regime.symbol);

         s.SetEnabledFor(regime.symbol, m_rows[i].enabled);
         s.SetSuitability(m_rows[i].final_score);
         if(m_rows[i].enabled)
            s.Account().SetAllocation(m_rows[i].capital_share);

         if(m_log != NULL && (was != m_rows[i].enabled || regime_changed))
           {
            SPerfStats st = s.Account().Stats();
            m_log.Strategy(s.Id(), regime.symbol,
                           (was == m_rows[i].enabled ? "RESCORE"
                            : (m_rows[i].enabled ? "ENABLE" : "DISABLE")),
                           m_rows[i].enabled, m_rows[i].final_score, m_rows[i].base_score,
                           m_rows[i].perf_adj, RegimeToString(regime.composite),
                           s.Account().Equity(), s.Account().DrawdownPct(),
                           st.trades, st.win_rate, st.expectancy_r,
                           StringFormat("share=%.2f conf=%.2f %s",
                                        m_rows[i].capital_share, regime.composite_conf,
                                        m_rows[i].note));
           }
        }

      m_last_regime = regime.composite;
      m_last_symbol = regime.symbol;
      return selected;
     }
  };

#endif // __ADAPTIVE_STRATEGYALLOCATOR_MQH__

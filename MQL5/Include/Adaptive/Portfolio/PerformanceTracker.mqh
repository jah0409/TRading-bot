//+------------------------------------------------------------------+
//| PerformanceTracker.mqh - "how has this strategy done HERE?"       |
//|                                                                    |
//| Overall P/L is the wrong question. A trend strategy that loses     |
//| money overall may still be the best thing available when the H1    |
//| is trending - it just spent too long enabled in ranges. So every   |
//| closed trade is filed against the regime that was live when it     |
//| was OPENED, giving a [strategy x regime] expectancy matrix.        |
//|                                                                    |
//| That matrix feeds back into the suitability scores, which is the   |
//| "continuous improvement" loop: strategies earn or lose the right   |
//| to be enabled in a given regime based on what they actually did.   |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_PERFORMANCETRACKER_MQH__
#define __ADAPTIVE_PERFORMANCETRACKER_MQH__

#include "../Core/Types.mqh"
#include "../Core/Logger.mqh"

//--- an open trade we are waiting to see the result of --------------
struct SOpenTradeRecord
  {
   ulong             ticket;
   string            strategy_id;
   string            symbol;
   ENUM_REGIME       regime_at_entry;
   double            risk_money;
   datetime          opened;
   bool              active;
  };

//--- rolling stats for one (strategy, regime) cell -------------------
struct SRegimeCell
  {
   int               trades;
   int               wins;
   double            sum_r;
   double            sum_r_sq;
  };

class CPerformanceTracker
  {
private:
   CLogger          *m_log;

   string            m_strategy_ids[];
   SRegimeCell       m_cells[];          // flat [strategy * 6 + regime]
   SOpenTradeRecord  m_open[];

   //--- shrinkage: with few trades, trust the prior (the configured
   //--- base score) rather than the sample. 20 trades gets you half
   //--- way to trusting the data.
   int               m_confidence_trades;
   double            m_max_adjust;       // clamp on the multiplier

   int               StrategyIndex(const string id) const
     {
      for(int i = 0; i < ArraySize(m_strategy_ids); i++)
         if(m_strategy_ids[i] == id)
            return i;
      return -1;
     }

   int               CellIndex(const string id, const ENUM_REGIME r) const
     {
      int si = StrategyIndex(id);
      if(si < 0)
         return -1;
      return si * 6 + (int)r;
     }

public:
                     CPerformanceTracker(void) : m_log(NULL), m_confidence_trades(20),
                                                 m_max_adjust(0.5) {}

   bool              Init(CLogger *log, const int confidence_trades = 20,
                          const double max_adjust = 0.5)
     {
      m_log               = log;
      m_confidence_trades = MathMax(1, confidence_trades);
      m_max_adjust        = max_adjust;
      ArrayResize(m_strategy_ids, 0);
      ArrayResize(m_cells, 0);
      ArrayResize(m_open, 0);
      return true;
     }

   void              Register(const string strategy_id)
     {
      if(StrategyIndex(strategy_id) >= 0)
         return;
      int n = ArraySize(m_strategy_ids);
      ArrayResize(m_strategy_ids, n + 1);
      m_strategy_ids[n] = strategy_id;

      ArrayResize(m_cells, (n + 1) * 6);
      for(int r = 0; r < 6; r++)
        {
         int c = n * 6 + r;
         m_cells[c].trades   = 0;
         m_cells[c].wins     = 0;
         m_cells[c].sum_r    = 0.0;
         m_cells[c].sum_r_sq = 0.0;
        }
     }

   //+---------------------------------------------------------------+
   //| Trade lifecycle                                                |
   //+---------------------------------------------------------------+
   void              OnTradeOpened(const ulong ticket, const string strategy_id,
                                   const string symbol, const ENUM_REGIME regime,
                                   const double risk_money)
     {
      //--- reuse a dead slot if one is free
      int slot = -1;
      for(int i = 0; i < ArraySize(m_open); i++)
         if(!m_open[i].active)
           {
            slot = i;
            break;
           }
      if(slot < 0)
        {
         slot = ArraySize(m_open);
         ArrayResize(m_open, slot + 1);
        }

      m_open[slot].ticket          = ticket;
      m_open[slot].strategy_id     = strategy_id;
      m_open[slot].symbol          = symbol;
      m_open[slot].regime_at_entry = regime;
      m_open[slot].risk_money      = risk_money;
      m_open[slot].opened          = TimeCurrent();
      m_open[slot].active          = true;
     }

   //--- returns false when we have no record of this ticket
   bool              OnTradeClosed(const ulong ticket, const double pnl,
                                   string &out_strategy, ENUM_REGIME &out_regime,
                                   double &out_r, double &out_risk)
     {
      for(int i = 0; i < ArraySize(m_open); i++)
        {
         if(!m_open[i].active || m_open[i].ticket != ticket)
            continue;

         out_strategy = m_open[i].strategy_id;
         out_regime   = m_open[i].regime_at_entry;
         out_risk     = m_open[i].risk_money;
         out_r        = (m_open[i].risk_money > 0.0 ? pnl / m_open[i].risk_money : 0.0);

         int c = CellIndex(out_strategy, out_regime);
         if(c >= 0)
           {
            m_cells[c].trades++;
            if(pnl > 0.0)
               m_cells[c].wins++;
            m_cells[c].sum_r    += out_r;
            m_cells[c].sum_r_sq += out_r * out_r;
           }

         m_open[i].active = false;
         return true;
        }
      return false;
     }

   bool              LookupOpen(const ulong ticket, SOpenTradeRecord &out) const
     {
      for(int i = 0; i < ArraySize(m_open); i++)
         if(m_open[i].active && m_open[i].ticket == ticket)
           {
            out = m_open[i];
            return true;
           }
      return false;
     }

   //+---------------------------------------------------------------+
   //| The feedback signal. Returns a multiplier applied to the       |
   //| configured base suitability for this (strategy, regime).       |
   //|                                                                |
   //| 1.0 = no opinion (no data, or expectancy exactly at breakeven) |
   //| >1  = doing better here than the config assumed                |
   //| <1  = doing worse; drops toward 1 - m_max_adjust               |
   //+---------------------------------------------------------------+
   double            SuitabilityAdjustment(const string strategy_id, const ENUM_REGIME regime) const
     {
      int c = CellIndex(strategy_id, regime);
      if(c < 0 || m_cells[c].trades == 0)
         return 1.0;

      double n            = (double)m_cells[c].trades;
      double expectancy_r = m_cells[c].sum_r / n;

      //--- shrink toward "no opinion" until we have a real sample
      double weight = n / (n + (double)m_confidence_trades);

      //--- map expectancy to a multiplier. +0.25R average is a good
      //--- strategy; treat that as the top of the useful range.
      double raw = MathMax(-1.0, MathMin(1.0, expectancy_r / 0.25));

      return 1.0 + weight * raw * m_max_adjust;
     }

   SPerfStats        CellStats(const string strategy_id, const ENUM_REGIME regime) const
     {
      SPerfStats s;
      s.trades = 0; s.wins = 0; s.gross_profit = 0; s.gross_loss = 0;
      s.net_profit = 0; s.max_drawdown = 0; s.expectancy_r = 0;
      s.win_rate = 0; s.profit_factor = 0; s.last_update = TimeCurrent();

      int c = CellIndex(strategy_id, regime);
      if(c < 0 || m_cells[c].trades == 0)
         return s;

      double n = (double)m_cells[c].trades;
      s.trades       = m_cells[c].trades;
      s.wins         = m_cells[c].wins;
      s.win_rate     = m_cells[c].wins / n;
      s.expectancy_r = m_cells[c].sum_r / n;
      return s;
     }

   //+---------------------------------------------------------------+
   //| Pruning candidate: enough trades to judge, and losing.         |
   //| The orchestrator reports these; a human decides.               |
   //| === STUB === auto-disable is deliberately NOT wired up. Pull   |
   //| the trigger yourself until the walk-forward harness exists.    |
   //+---------------------------------------------------------------+
   bool              IsPruneCandidate(const string strategy_id, const int min_trades,
                                      const double min_expectancy_r, string &why) const
     {
      int si = StrategyIndex(strategy_id);
      if(si < 0)
         return false;

      int    total_trades = 0;
      double total_r      = 0.0;
      for(int r = 0; r < 6; r++)
        {
         total_trades += m_cells[si * 6 + r].trades;
         total_r      += m_cells[si * 6 + r].sum_r;
        }

      if(total_trades < min_trades)
         return false;

      double exp_r = total_r / (double)total_trades;
      if(exp_r >= min_expectancy_r)
         return false;

      why = StringFormat("%d trades, expectancy %.3fR < %.3fR",
                         total_trades, exp_r, min_expectancy_r);
      return true;
     }
  };

#endif // __ADAPTIVE_PERFORMANCETRACKER_MQH__

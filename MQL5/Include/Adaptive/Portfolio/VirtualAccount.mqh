//+------------------------------------------------------------------+
//| VirtualAccount.mqh - per-strategy P/L, equity and drawdown        |
//|                                                                    |
//| The real account is one pot. To decide which strategies deserve    |
//| capital we need to know what each one earned on its own, so every  |
//| strategy gets a virtual account seeded with its share of the       |
//| balance. Realised P/L comes from the deal history (matched by      |
//| magic); floating P/L is marked to market each loop.                |
//|                                                                    |
//| These numbers drive capital allocation, suitability adjustment and |
//| pruning. They never place an order.                                |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_VIRTUALACCOUNT_MQH__
#define __ADAPTIVE_VIRTUALACCOUNT_MQH__

#include "../Core/Types.mqh"

class CVirtualAccount
  {
private:
   string            m_strategy_id;
   long              m_magic;
   double            m_allocated;        // notional capital share
   double            m_realised;         // closed P/L since inception
   double            m_floating;         // open P/L, refreshed each loop
   double            m_peak_equity;
   double            m_max_drawdown;
   datetime          m_inception;
   ulong             m_last_deal_seen;   // cursor into the deal history

   //--- rolling trade record, newest last
   double            m_r_multiples[];
   int               m_max_history;

   SPerfStats        m_stats;

   void              Recompute(void)
     {
      int n = ArraySize(m_r_multiples);
      m_stats.trades       = n;
      m_stats.wins         = 0;
      m_stats.gross_profit = 0.0;
      m_stats.gross_loss   = 0.0;
      double sum_r = 0.0;

      for(int i = 0; i < n; i++)
        {
         double r = m_r_multiples[i];
         sum_r += r;
         if(r > 0.0)
           {
            m_stats.wins++;
            m_stats.gross_profit += r;
           }
         else
            m_stats.gross_loss += -r;
        }

      m_stats.net_profit   = m_realised;
      m_stats.win_rate     = (n > 0 ? (double)m_stats.wins / (double)n : 0.0);
      m_stats.expectancy_r = (n > 0 ? sum_r / (double)n : 0.0);
      m_stats.profit_factor = (m_stats.gross_loss > 0.0
                               ? m_stats.gross_profit / m_stats.gross_loss
                               : (m_stats.gross_profit > 0.0 ? 99.0 : 0.0));
      m_stats.max_drawdown = m_max_drawdown;
      m_stats.last_update  = TimeCurrent();
     }

public:
                     CVirtualAccount(void) : m_strategy_id(""), m_magic(0), m_allocated(0),
                                             m_realised(0), m_floating(0), m_peak_equity(0),
                                             m_max_drawdown(0), m_inception(0),
                                             m_last_deal_seen(0), m_max_history(200) {}

   void              Init(const string strategy_id, const long magic, const double allocated)
     {
      m_strategy_id = strategy_id;
      m_magic       = magic;
      m_allocated   = allocated;
      m_peak_equity = allocated;
      m_inception   = TimeCurrent();
      ArrayResize(m_r_multiples, 0);
      Recompute();
     }

   string            StrategyId(void)  const { return m_strategy_id; }
   double            Allocated(void)   const { return m_allocated; }
   double            Realised(void)    const { return m_realised; }
   double            Floating(void)    const { return m_floating; }
   double            Equity(void)      const { return m_allocated + m_realised + m_floating; }
   double            MaxDrawdown(void) const { return m_max_drawdown; }

   double            DrawdownPct(void) const
     {
      if(m_peak_equity <= 0.0)
         return 0.0;
      return (m_peak_equity - Equity()) / m_peak_equity * 100.0;
     }

   double            ReturnPct(void) const
     {
      if(m_allocated <= 0.0)
         return 0.0;
      return (m_realised + m_floating) / m_allocated * 100.0;
     }

   SPerfStats        Stats(void) const { return m_stats; }

   void              SetAllocation(const double allocated) { m_allocated = allocated; }

   //--- called when a position owned by this strategy closes ---------
   void              RecordClosedTrade(const double pnl, const double risk_money)
     {
      m_realised += pnl;

      //--- express the result in R so strategies with different stop
      //--- sizes stay comparable
      double r = (risk_money > 0.0 ? pnl / risk_money : 0.0);
      int n = ArraySize(m_r_multiples);
      if(n >= m_max_history)
        {
         //--- drop the oldest
         for(int i = 1; i < n; i++)
            m_r_multiples[i - 1] = m_r_multiples[i];
         m_r_multiples[n - 1] = r;
        }
      else
        {
         ArrayResize(m_r_multiples, n + 1);
         m_r_multiples[n] = r;
        }

      MarkToMarket(m_floating);
      Recompute();
     }

   //--- called every main-loop pass with this strategy's open P/L ----
   void              MarkToMarket(const double floating_pnl)
     {
      m_floating = floating_pnl;
      double eq = Equity();
      if(eq > m_peak_equity)
         m_peak_equity = eq;
      double dd = m_peak_equity - eq;
      if(dd > m_max_drawdown)
         m_max_drawdown = dd;
     }
  };

#endif // __ADAPTIVE_VIRTUALACCOUNT_MQH__

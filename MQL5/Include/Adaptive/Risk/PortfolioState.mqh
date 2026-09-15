//+------------------------------------------------------------------+
//| PortfolioState.mqh - the account's posture, above any strategy    |
//|                                                                    |
//| NORMAL                everything validated and behaving            |
//| CAPITAL_PRESERVATION  several strategies degrading, or drawdown    |
//|                       building: smaller size, fewer positions,     |
//|                       stronger signals required                    |
//| NO_VALID_EDGE         nothing has sufficient evidence for the      |
//|                       current regime. The account stays FLAT.      |
//|                       This is a legitimate resting state, not a    |
//|                       failure - and it is mandatory, not advisory. |
//| MARKET_UNSAFE         the market, not the strategies, is the       |
//|                       problem: abnormal volatility, spread blowout,|
//|                       several independent strategies failing at    |
//|                       once. Stop, do not rotate.                   |
//|                                                                    |
//| The distinction between CAPITAL_PRESERVATION and MARKET_UNSAFE is  |
//| the point of this module. If three unrelated strategies fail       |
//| simultaneously the likely cause is not three coincidental strategy |
//| failures - it is that conditions changed. Cycling to a fourth      |
//| strategy in that situation just finds a fourth way to lose.        |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_PORTFOLIOSTATE_MQH__
#define __ADAPTIVE_PORTFOLIOSTATE_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "../Portfolio/StrategyHealth.mqh"

enum ENUM_PORTFOLIO_MODE
  {
   MODE_NORMAL = 0,
   MODE_CAPITAL_PRESERVATION,
   MODE_NO_VALID_EDGE,
   MODE_MARKET_UNSAFE
  };

string ModeToString(const ENUM_PORTFOLIO_MODE m)
  {
   switch(m)
     {
      case MODE_NORMAL:               return "NORMAL";
      case MODE_CAPITAL_PRESERVATION: return "CAPITAL_PRESERVATION";
      case MODE_NO_VALID_EDGE:        return "NO_VALID_EDGE";
      case MODE_MARKET_UNSAFE:        return "MARKET_UNSAFE";
     }
   return "?";
  }

class CPortfolioState
  {
private:
   CConfig             *m_cfg;
   CLogger             *m_log;

   ENUM_PORTFOLIO_MODE  m_mode;
   datetime             m_since;
   string               m_reason;
   datetime             m_unsafe_until;

   //--- thresholds
   int                  m_degraded_for_preservation;
   int                  m_failures_for_unsafe;
   int                  m_unsafe_minutes;
   double               m_preservation_dd_pct;
   double               m_preservation_risk_mult;
   double               m_preservation_conf_bonus;
   int                  m_preservation_max_positions;

   void                 Set(const ENUM_PORTFOLIO_MODE m, const string why)
     {
      if(m == m_mode)
         return;
      ENUM_PORTFOLIO_MODE prev = m_mode;
      m_mode = m;
      m_since = TimeCurrent();
      m_reason = why;
      if(m_log != NULL)
         m_log.Risk("PORTFOLIO_MODE", "", "", BLOCK_NONE, 0, 0, 0, 0,
                    AccountInfoDouble(ACCOUNT_EQUITY), 0, 0,
                    StringFormat("%s -> %s: %s", ModeToString(prev),
                                 ModeToString(m), why));
     }

public:
                     CPortfolioState(void) : m_cfg(NULL), m_log(NULL), m_mode(MODE_NORMAL),
                                             m_since(0), m_unsafe_until(0),
                                             m_degraded_for_preservation(2),
                                             m_failures_for_unsafe(3),
                                             m_unsafe_minutes(120),
                                             m_preservation_dd_pct(3.0),
                                             m_preservation_risk_mult(0.5),
                                             m_preservation_conf_bonus(0.15),
                                             m_preservation_max_positions(1) {}

   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;
      m_since = TimeCurrent();
      CJson *j = cfg.Json();
      m_degraded_for_preservation  = j.GetInt("portfolio.degraded_for_preservation", 2);
      m_failures_for_unsafe        = j.GetInt("portfolio.failures_for_unsafe", 3);
      m_unsafe_minutes             = j.GetInt("portfolio.unsafe_minutes", 120);
      m_preservation_dd_pct        = j.GetDouble("portfolio.preservation_dd_pct", 3.0);
      m_preservation_risk_mult     = j.GetDouble("portfolio.preservation_risk_mult", 0.5);
      m_preservation_conf_bonus    = j.GetDouble("portfolio.preservation_confidence_bonus", 0.15);
      m_preservation_max_positions = j.GetInt("portfolio.preservation_max_positions", 1);
      return true;
     }

   ENUM_PORTFOLIO_MODE Mode(void)   const { return m_mode; }
   string            ModeName(void) const { return ModeToString(m_mode); }
   string            Reason(void)   const { return m_reason; }

   bool              AllowsNewTrades(void) const
     {
      return (m_mode == MODE_NORMAL || m_mode == MODE_CAPITAL_PRESERVATION);
     }

   double            RiskMultiplier(void) const
     {
      if(m_mode == MODE_CAPITAL_PRESERVATION)
         return m_preservation_risk_mult;
      if(m_mode == MODE_NORMAL)
         return 1.0;
      return 0.0;
     }

   //--- preservation demands a cleaner signal, not just a smaller one
   double            ExtraConfidenceRequired(void) const
     {
      return (m_mode == MODE_CAPITAL_PRESERVATION ? m_preservation_conf_bonus : 0.0);
     }

   int               MaxPositionsOverride(const int normal) const
     {
      if(m_mode == MODE_CAPITAL_PRESERVATION)
         return MathMin(normal, m_preservation_max_positions);
      if(m_mode == MODE_NORMAL)
         return normal;
      return 0;
     }

   //+---------------------------------------------------------------+
   //| Re-evaluate each main-loop pass.                               |
   //|                                                                |
   //| `eligible_now` is how many strategies are BOTH healthy enough  |
   //| to trade AND suited to the live regime. Zero is not an error   |
   //| condition - it is NO_VALID_EDGE, and the correct response is   |
   //| to sit flat.                                                   |
   //+---------------------------------------------------------------+
   void              Update(const int total_strategies, const int degraded,
                            const int cooling, const int eligible_now,
                            const double account_dd_pct, const bool market_abnormal,
                            const bool spread_abnormal)
     {
      //--- MARKET_UNSAFE outranks everything and is time-boxed --------
      if(m_mode == MODE_MARKET_UNSAFE && TimeCurrent() < m_unsafe_until)
         return;

      int simultaneous_failures = degraded + cooling;
      bool many_failing = (simultaneous_failures >= m_failures_for_unsafe);

      if(market_abnormal || spread_abnormal || many_failing)
        {
         m_unsafe_until = TimeCurrent() + m_unsafe_minutes * 60;
         string why = market_abnormal ? "abnormal volatility regime"
                      : (spread_abnormal ? "spread outside tolerance"
                         : StringFormat("%d strategies failing at once - suspect the "
                                        "market, not the strategies",
                                        simultaneous_failures));
         Set(MODE_MARKET_UNSAFE, why);
         return;
        }

      //--- nothing eligible: rest. Not a failure state. ---------------
      if(eligible_now <= 0)
        {
         Set(MODE_NO_VALID_EDGE,
             "no strategy has sufficient evidence for the current regime");
         return;
        }

      //--- degrading, or drawdown building: shrink, do not stop --------
      if(degraded >= m_degraded_for_preservation ||
         account_dd_pct >= m_preservation_dd_pct)
        {
         Set(MODE_CAPITAL_PRESERVATION,
             StringFormat("%d/%d strategies degraded, account dd %.2f%%",
                          degraded, total_strategies, account_dd_pct));
         return;
        }

      Set(MODE_NORMAL, "conditions normal");
     }

   string            Describe(void) const
     {
      return StringFormat("%s (%s)", ModeToString(m_mode), m_reason);
     }
  };

#endif // __ADAPTIVE_PORTFOLIOSTATE_MQH__

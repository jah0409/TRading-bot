//+------------------------------------------------------------------+
//| StrategyHealth.mqh - is this strategy still working?              |
//|                                                                    |
//| Every strategy carries a VALIDATED BASELINE from walk-forward: the |
//| expectancy, profit factor and win rate it earned out of sample.    |
//| Live results are compared against that baseline, not against zero. |
//| "Losing money" is not the signal - "performing materially worse    |
//| than the evidence said it would" is.                               |
//|                                                                    |
//| States and the only legal transitions:                             |
//|                                                                    |
//|   ACTIVE ──deterioration──▶ PROBATION ──persists──▶ REDUCED_RISK   |
//|      ▲                          │                        │        |
//|      └──────recovery────────────┴────────────────────────┘        |
//|      │                                                             |
//|   COOL_DOWN ◀── consecutive losses / drawdown breach               |
//|      │                                                             |
//|   DISABLED ◀── deterioration persists at reduced risk              |
//|   RETIRED  ◀── manual only                                         |
//|                                                                    |
//| One losing trade never moves a strategy. Recovery always requires  |
//| evidence - a minimum number of trades at acceptable expectancy -   |
//| because a single win after a bad run is noise, not a turnaround.   |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_STRATEGYHEALTH_MQH__
#define __ADAPTIVE_STRATEGYHEALTH_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"

enum ENUM_STRATEGY_STATE
  {
   STATE_ACTIVE = 0,     // full allowed risk
   STATE_PROBATION,      // still trading, watched, cannot be top-scored
   STATE_REDUCED_RISK,   // half risk, must clear evidence to return
   STATE_COOL_DOWN,      // temporarily barred - time-based, auto-expires
   STATE_DISABLED,       // no new trades until revalidated offline
   STATE_RETIRED         // removed from the mix; manual only
  };

string StateToString(const ENUM_STRATEGY_STATE s)
  {
   switch(s)
     {
      case STATE_ACTIVE:       return "ACTIVE";
      case STATE_PROBATION:    return "PROBATION";
      case STATE_REDUCED_RISK: return "REDUCED_RISK";
      case STATE_COOL_DOWN:    return "COOL_DOWN";
      case STATE_DISABLED:     return "DISABLED";
      case STATE_RETIRED:      return "RETIRED";
     }
   return "?";
  }

//--- what walk-forward said this strategy should do -----------------
struct SBaseline
  {
   double            expectancy_r;
   double            profit_factor;
   double            win_rate;
   double            max_dd_r;
   int               sample_trades;   // how many trades backed it
   string            evidence_tier;   // INSUFFICIENT / WEAK / MODERATE / STRONGER
   bool              borderline;      // passed on expectancy, not on consistency
   bool              valid;
  };

#define HEALTH_WINDOW 60   // rolling trades kept per strategy

class CStrategyHealth
  {
private:
   string               m_id;
   CLogger             *m_log;

   SBaseline            m_base;
   ENUM_STRATEGY_STATE  m_state;
   datetime             m_state_since;
   datetime             m_cooldown_until;
   string               m_last_reason;

   //--- rolling record
   double               m_r[HEALTH_WINDOW];
   int                  m_count;
   int                  m_head;

   int                  m_consec_losses;
   int                  m_consec_wins;
   double               m_peak_equity_r;
   double               m_equity_r;
   double               m_max_dd_r;
   int                  m_trades_in_state;

   //--- thresholds (from config)
   int                  m_min_sample;          // trades before judging at all
   double               m_deterioration;       // fraction of baseline expectancy
   int                  m_max_consec_losses;
   double               m_max_dd_mult;         // x baseline max_dd_r
   int                  m_cooldown_minutes;
   int                  m_recovery_trades;
   double               m_recovery_expectancy;

   int                  Size(void) const { return m_count; }

   double               Mean(void) const
     {
      if(m_count == 0)
         return 0.0;
      double s = 0.0;
      for(int i = 0; i < m_count; i++)
         s += m_r[i];
      return s / m_count;
     }

   double               ProfitFactor(void) const
     {
      double w = 0.0, l = 0.0;
      for(int i = 0; i < m_count; i++)
        {
         if(m_r[i] > 0) w += m_r[i];
         else           l += -m_r[i];
        }
      if(l <= 0.0)
         return (w > 0.0 ? 99.0 : 0.0);
      return w / l;
     }

   double               WinRate(void) const
     {
      if(m_count == 0)
         return 0.0;
      int w = 0;
      for(int i = 0; i < m_count; i++)
         if(m_r[i] > 0)
            w++;
      return (double)w / m_count;
     }

   //--- last N trades only, for detecting a recent turn
   double               RecentMean(const int n) const
     {
      int k = MathMin(n, m_count);
      if(k <= 0)
         return 0.0;
      double s = 0.0;
      for(int i = m_count - k; i < m_count; i++)
         s += m_r[i];
      return s / k;
     }

   void                 SetState(const ENUM_STRATEGY_STATE st, const string why)
     {
      if(st == m_state)
         return;
      ENUM_STRATEGY_STATE prev = m_state;
      m_state = st;
      m_state_since = TimeCurrent();
      m_trades_in_state = 0;
      m_last_reason = why;

      if(m_log != NULL)
         m_log.Strategy(m_id, "", "STATE_" + StateToString(st),
                        (st == STATE_ACTIVE || st == STATE_PROBATION || st == STATE_REDUCED_RISK),
                        0, 0, 0, "", 0, m_max_dd_r, m_count, WinRate(), Mean(),
                        StringFormat("%s -> %s: %s", StateToString(prev),
                                     StateToString(st), why));
     }

public:
                     CStrategyHealth(void) : m_log(NULL), m_state(STATE_ACTIVE),
                                             m_state_since(0), m_cooldown_until(0),
                                             m_count(0), m_head(0), m_consec_losses(0),
                                             m_consec_wins(0), m_peak_equity_r(0),
                                             m_equity_r(0), m_max_dd_r(0),
                                             m_trades_in_state(0),
                                             m_min_sample(20), m_deterioration(0.5),
                                             m_max_consec_losses(6), m_max_dd_mult(1.5),
                                             m_cooldown_minutes(240), m_recovery_trades(15),
                                             m_recovery_expectancy(0.0)
     {
      ArrayInitialize(m_r, 0.0);
      m_base.valid = false;
      m_base.borderline = false;
     }

   void              Init(const string id, CConfig *cfg, CLogger *log, const SBaseline &base)
     {
      m_id   = id;
      m_log  = log;
      m_base = base;
      m_state_since = TimeCurrent();

      if(cfg != NULL)
        {
         CJson *j = cfg.Json();
         m_min_sample          = j.GetInt("health.min_sample_trades", 20);
         m_deterioration       = j.GetDouble("health.deterioration_fraction", 0.5);
         m_max_consec_losses   = j.GetInt("health.max_consecutive_losses", 6);
         m_max_dd_mult         = j.GetDouble("health.max_dd_multiple", 1.5);
         m_cooldown_minutes    = j.GetInt("health.cooldown_minutes", 240);
         m_recovery_trades     = j.GetInt("health.recovery_trades", 15);
         m_recovery_expectancy = j.GetDouble("health.recovery_expectancy_r", 0.0);
        }

      //--- a strategy whose evidence never reached the bar starts on
      //--- probation rather than active, however good its numbers look.
      //--- `borderline` covers the case that matters most in practice: a
      //--- positive pooled expectancy that did NOT clear the consistency
      //--- test. Those trade at half risk until live results earn more.
      if(!m_base.valid || m_base.evidence_tier == "INSUFFICIENT")
         SetState(STATE_PROBATION, "no validated baseline");
      else if(m_base.borderline)
         SetState(STATE_PROBATION, "borderline validation - positive expectancy "
                  "but failed the fold-consistency test");
     }

   //--- accessors ------------------------------------------------------
   ENUM_STRATEGY_STATE State(void)      const { return m_state; }
   string            StateName(void)    const { return StateToString(m_state); }
   string            LastReason(void)   const { return m_last_reason; }
   int               Trades(void)       const { return m_count; }
   double            Expectancy(void)   const { return Mean(); }
   double            ProfitFactorNow(void) const { return ProfitFactor(); }
   double            WinRateNow(void)   const { return WinRate(); }
   double            DrawdownR(void)    const { return m_max_dd_r; }
   int               ConsecLosses(void) const { return m_consec_losses; }
   SBaseline         Baseline(void)     const { return m_base; }

   //--- may this strategy open a NEW position right now? ---------------
   bool              CanTrade(void)
     {
      if(m_state == STATE_COOL_DOWN && TimeCurrent() >= m_cooldown_until)
         SetState(STATE_PROBATION, "cooldown expired");
      return (m_state == STATE_ACTIVE || m_state == STATE_PROBATION ||
              m_state == STATE_REDUCED_RISK);
     }

   //--- risk multiplier the state allows -------------------------------
   double            RiskMultiplier(void) const
     {
      switch(m_state)
        {
         case STATE_ACTIVE:       return 1.0;
         case STATE_PROBATION:    return 0.5;
         case STATE_REDUCED_RISK: return 0.25;
         default:                 return 0.0;
        }
     }

   //+---------------------------------------------------------------+
   //| Record a closed trade and re-evaluate the state.               |
   //+---------------------------------------------------------------+
   void              OnTradeClosed(const double r_multiple)
     {
      if(m_count < HEALTH_WINDOW)
        {
         m_r[m_count] = r_multiple;
         m_count++;
        }
      else
        {
         for(int i = 1; i < HEALTH_WINDOW; i++)
            m_r[i - 1] = m_r[i];
         m_r[HEALTH_WINDOW - 1] = r_multiple;
        }
      m_trades_in_state++;

      if(r_multiple > 0)
        {
         m_consec_wins++;
         m_consec_losses = 0;
        }
      else
        {
         m_consec_losses++;
         m_consec_wins = 0;
        }

      m_equity_r += r_multiple;
      if(m_equity_r > m_peak_equity_r)
         m_peak_equity_r = m_equity_r;
      double dd = m_peak_equity_r - m_equity_r;
      if(dd > m_max_dd_r)
         m_max_dd_r = dd;

      Evaluate();
     }

   //+---------------------------------------------------------------+
   //| The deterioration test. Deliberately hard to trigger on noise. |
   //+---------------------------------------------------------------+
   void              Evaluate(void)
     {
      //--- hard triggers first: these do not need a baseline ------------
      if(m_consec_losses >= m_max_consec_losses)
        {
         m_cooldown_until = TimeCurrent() + m_cooldown_minutes * 60;
         SetState(STATE_COOL_DOWN,
                  StringFormat("%d consecutive losses", m_consec_losses));
         return;
        }

      if(m_base.valid && m_base.max_dd_r > 0 &&
         m_max_dd_r > m_base.max_dd_r * m_max_dd_mult)
        {
         m_cooldown_until = TimeCurrent() + m_cooldown_minutes * 60;
         SetState(STATE_COOL_DOWN,
                  StringFormat("drawdown %.1fR exceeds %.1fx validated %.1fR",
                               m_max_dd_r, m_max_dd_mult, m_base.max_dd_r));
         return;
        }

      //--- everything below needs enough trades to mean anything --------
      if(m_count < m_min_sample)
         return;

      //--- recovery: evidence, not a single win -------------------------
      if(m_state == STATE_PROBATION || m_state == STATE_REDUCED_RISK)
        {
         if(m_trades_in_state >= m_recovery_trades &&
            RecentMean(m_recovery_trades) > m_recovery_expectancy)
           {
            ENUM_STRATEGY_STATE up = (m_state == STATE_REDUCED_RISK
                                      ? STATE_PROBATION : STATE_ACTIVE);
            SetState(up, StringFormat("recovered: %d trades at %.3fR",
                                      m_recovery_trades, RecentMean(m_recovery_trades)));
            return;
           }
        }

      if(!m_base.valid || m_base.expectancy_r <= 0.0)
         return;

      //--- live expectancy against the validated baseline ---------------
      double live = Mean();
      double floor_exp = m_base.expectancy_r * m_deterioration;
      bool decayed = (live < floor_exp);

      if(decayed)
        {
         string why = StringFormat("expectancy %.3fR below %.0f%% of validated %.3fR",
                                   live, m_deterioration * 100, m_base.expectancy_r);
         if(m_state == STATE_ACTIVE)
            SetState(STATE_PROBATION, why);
         else if(m_state == STATE_PROBATION && m_trades_in_state >= m_min_sample)
            SetState(STATE_REDUCED_RISK, why);
         else if(m_state == STATE_REDUCED_RISK && m_trades_in_state >= m_min_sample)
            SetState(STATE_DISABLED, why + " - revalidate offline before re-enabling");
        }
     }

   //--- called by the orchestrator when the market itself looks unsafe
   void              ForceCooldown(const int minutes, const string why)
     {
      m_cooldown_until = TimeCurrent() + minutes * 60;
      SetState(STATE_COOL_DOWN, why);
     }

   void              ForceDisable(const string why) { SetState(STATE_DISABLED, why); }
   void              Retire(const string why)       { SetState(STATE_RETIRED, why); }

   //--- manual reinstatement, always logged
   void              Reinstate(const string who)
     {
      m_consec_losses = 0;
      m_max_dd_r = 0.0;
      m_peak_equity_r = m_equity_r;
      SetState(STATE_PROBATION, "reinstated by " + who);
     }

   string            Describe(void) const
     {
      return StringFormat("%s[%s n=%d exp=%.3fR pf=%.2f dd=%.1fR cl=%d]",
                          m_id, StateToString(m_state), m_count, Mean(),
                          ProfitFactor(), m_max_dd_r, m_consec_losses);
     }
  };

#endif // __ADAPTIVE_STRATEGYHEALTH_MQH__

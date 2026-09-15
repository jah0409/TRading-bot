//+------------------------------------------------------------------+
//| TradeGate.mqh - the mandatory checklist before any trade          |
//|                                                                    |
//| Fifteen checks. Every one is mandatory. If ANY fails there is no   |
//| trade, and the refusal is logged with its reason so the rejected   |
//| trades are as analysable as the taken ones.                        |
//|                                                                    |
//| Ordered cheapest-first so the common refusals cost nothing, and    |
//| deliberately redundant with checks inside CRiskManager: a gate     |
//| that only works when every caller remembers to call it is not a    |
//| gate. The risk manager remains the final authority - this runs     |
//| before it and can only ever refuse, never approve.                 |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_TRADEGATE_MQH__
#define __ADAPTIVE_TRADEGATE_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"
#include "../Risk/RiskManager.mqh"
#include "../Risk/PortfolioState.mqh"
#include "../Portfolio/StrategyHealth.mqh"
#include "../Regime/RegimeDetector.mqh"

struct SGateResult
  {
   bool              passed;
   string            failed_check;
   string            detail;
   double            risk_multiplier;   // combined portfolio x strategy-health
  };

class CTradeGate
  {
private:
   CConfig          *m_cfg;
   CLogger          *m_log;

   SGateResult       Fail(const string check, const string detail,
                          const string strategy, const string symbol)
     {
      SGateResult r;
      r.passed = false;
      r.failed_check = check;
      r.detail = detail;
      r.risk_multiplier = 0.0;
      if(m_log != NULL)
         m_log.Risk("GATE_REJECT", strategy, symbol, BLOCK_NONE, 0, 0, 0, 0,
                    AccountInfoDouble(ACCOUNT_EQUITY), 0, 0,
                    StringFormat("%s: %s", check, detail));
      return r;
     }

public:
                     CTradeGate(void) : m_cfg(NULL), m_log(NULL) {}

   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;
      return true;
     }

   //+---------------------------------------------------------------+
   //| Run the checklist. Called before the strategy is even asked    |
   //| for a signal, so a blocked strategy costs no indicator work.   |
   //+---------------------------------------------------------------+
   SGateResult       Check(const string strategy_id, const SMarketContext &ctx,
                           CRiskManager *risk, CPortfolioState *portfolio,
                           CStrategyHealth *health, const double strategy_score,
                           const double min_score)
     {
      SGateResult ok;
      ok.passed = true;
      ok.failed_check = "";
      ok.detail = "";
      ok.risk_multiplier = 1.0;

      //--- 1. account-level locks -------------------------------------
      if(risk.IsKilled())
         return Fail("KILL_SWITCH", StringFormat("equity dd %.2f%%", risk.DrawdownPct()),
                     strategy_id, ctx.symbol);
      if(risk.IsDailyLocked())
         return Fail("DAILY_LOCK", StringFormat("day pnl %.2f%%", risk.DayPnlPct()),
                     strategy_id, ctx.symbol);

      //--- 2. portfolio posture ---------------------------------------
      if(!portfolio.AllowsNewTrades())
         return Fail("PORTFOLIO_MODE", portfolio.Describe(), strategy_id, ctx.symbol);

      //--- 3. strategy health -----------------------------------------
      if(!health.CanTrade())
         return Fail("STRATEGY_STATE",
                     StringFormat("%s: %s", health.StateName(), health.LastReason()),
                     strategy_id, ctx.symbol);

      //--- 4. news ------------------------------------------------------
      if(ctx.news_blackout)
         return Fail("NEWS_BLACKOUT", ctx.news_label, strategy_id, ctx.symbol);

      //--- 5. regime is not tradable ------------------------------------
      if(ctx.regime.composite == REGIME_UNKNOWN)
         return Fail("REGIME_UNKNOWN",
                     StringFormat("composite confidence %.2f", ctx.regime.composite_conf),
                     strategy_id, ctx.symbol);

      //--- 6. strategy suitability for THIS regime ----------------------
      double needed = min_score + portfolio.ExtraConfidenceRequired();
      if(strategy_score < needed)
         return Fail("SUITABILITY",
                     StringFormat("score %.3f < required %.3f%s", strategy_score, needed,
                                  (portfolio.ExtraConfidenceRequired() > 0
                                   ? " (raised by capital preservation)" : "")),
                     strategy_id, ctx.symbol);

      //--- 7. spread ----------------------------------------------------
      double max_spread = (StringFind(ctx.symbol, "XAU") >= 0
                           ? m_cfg.Risk().max_spread_points_xau
                           : m_cfg.Risk().max_spread_points_idx);
      if(ctx.spread_points > max_spread)
         return Fail("SPREAD", StringFormat("%.0f > %.0f points",
                                            ctx.spread_points, max_spread),
                     strategy_id, ctx.symbol);

      //--- 8. market data sanity ---------------------------------------
      if(ctx.bid <= 0.0 || ctx.ask <= 0.0 || ctx.ask < ctx.bid)
         return Fail("INVALID_PRICE", StringFormat("bid %.5f ask %.5f", ctx.bid, ctx.ask),
                     strategy_id, ctx.symbol);
      if(ctx.atr_ref <= 0.0)
         return Fail("NO_VOLATILITY_REF", "ATR reference unavailable",
                     strategy_id, ctx.symbol);
      if(ctx.point <= 0.0 || ctx.tick_size <= 0.0 || ctx.tick_value <= 0.0)
         return Fail("SYMBOL_PROPERTIES",
                     StringFormat("point %.10f tick_size %.10f tick_value %.5f",
                                  ctx.point, ctx.tick_size, ctx.tick_value),
                     strategy_id, ctx.symbol);

      //--- 9. session ---------------------------------------------------
      if(m_cfg.Json().GetBool("sessions.enabled", false))
        {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         int from = m_cfg.Json().GetInt("sessions.trade_from_hour", 0);
         int to   = m_cfg.Json().GetInt("sessions.trade_to_hour", 24);
         if(dt.hour < from || dt.hour >= to)
            return Fail("SESSION_CLOSED",
                        StringFormat("hour %d outside %d-%d", dt.hour, from, to),
                        strategy_id, ctx.symbol);
        }

      //--- 10. combined risk multiplier --------------------------------
      ok.risk_multiplier = portfolio.RiskMultiplier() * health.RiskMultiplier()
                           * ctx.news_size_mult;
      if(ok.risk_multiplier <= 0.0)
         return Fail("RISK_MULTIPLIER_ZERO",
                     StringFormat("portfolio %.2f x health %.2f x news %.2f",
                                  portfolio.RiskMultiplier(), health.RiskMultiplier(),
                                  ctx.news_size_mult),
                     strategy_id, ctx.symbol);

      return ok;
     }

   //+---------------------------------------------------------------+
   //| Second half of the checklist: run once a signal exists, on the |
   //| concrete stop/target/size. The risk manager repeats most of    |
   //| this - deliberately.                                           |
   //+---------------------------------------------------------------+
   SGateResult       CheckSignal(const string strategy_id, const SMarketContext &ctx,
                                 const SEntrySignal &sig, const double entry_price)
     {
      SGateResult ok;
      ok.passed = true;
      ok.risk_multiplier = 1.0;

      //--- 11. stop must exist and sit on the correct side -------------
      if(sig.stop_loss <= 0.0)
         return Fail("NO_STOP", "signal carried no stop loss", strategy_id, ctx.symbol);
      bool is_buy = (sig.direction == ORDER_TYPE_BUY);
      double signed_dist = (is_buy ? entry_price - sig.stop_loss
                            : sig.stop_loss - entry_price);
      if(signed_dist <= 0.0)
         return Fail("STOP_WRONG_SIDE",
                     StringFormat("entry %.5f stop %.5f dir %s", entry_price,
                                  sig.stop_loss, (is_buy ? "BUY" : "SELL")),
                     strategy_id, ctx.symbol);

      //--- 12. stop not inside the noise floor -------------------------
      double min_dist = m_cfg.Risk().min_stop_atr_mult * ctx.atr_ref;
      if(signed_dist < min_dist)
         return Fail("STOP_TOO_TIGHT",
                     StringFormat("%.5f is %.2f ATR, minimum %.2f", signed_dist,
                                  signed_dist / ctx.atr_ref,
                                  m_cfg.Risk().min_stop_atr_mult),
                     strategy_id, ctx.symbol);

      //--- 13. broker stop and freeze levels ---------------------------
      long stops_level  = SymbolInfoInteger(ctx.symbol, SYMBOL_TRADE_STOPS_LEVEL);
      long freeze_level = SymbolInfoInteger(ctx.symbol, SYMBOL_TRADE_FREEZE_LEVEL);
      double need = MathMax((double)stops_level, (double)freeze_level) * ctx.point;
      if(need > 0.0 && signed_dist < need)
         return Fail("BROKER_STOP_LEVEL",
                     StringFormat("stop %.5f < broker minimum %.5f (stops %I64d, freeze %I64d)",
                                  signed_dist, need, stops_level, freeze_level),
                     strategy_id, ctx.symbol);

      //--- 14. target, if any, must be the right side and worth taking --
      if(sig.take_profit > 0.0)
        {
         double tp_dist = (is_buy ? sig.take_profit - entry_price
                           : entry_price - sig.take_profit);
         if(tp_dist <= 0.0)
            return Fail("TP_WRONG_SIDE",
                        StringFormat("entry %.5f tp %.5f", entry_price, sig.take_profit),
                        strategy_id, ctx.symbol);
         double min_rr = m_cfg.Json().GetDouble("risk.min_reward_risk", 0.8);
         if(tp_dist / signed_dist < min_rr)
            return Fail("REWARD_RISK",
                        StringFormat("%.2f below minimum %.2f", tp_dist / signed_dist, min_rr),
                        strategy_id, ctx.symbol);
        }

      //--- 15. the trade must be able to make the minimum target -------
      //--- Where a target exists, it must clear the minimum. Where the
      //--- strategy trails instead, 1R is the unit of a winner, so the
      //--- STOP must clear it: a trade whose entire 1R is below the
      //--- minimum cannot produce a qualifying winner however far it runs.
      double pip   = m_cfg.Json().GetDouble("risk.pip_size", 1.00);
      double min_t = m_cfg.Json().GetDouble("risk.min_target_pips", 0.0) * pip;
      if(min_t > 0.0)
        {
         double reach = (sig.take_profit > 0.0
                         ? MathAbs(sig.take_profit - entry_price)
                         : signed_dist);
         if(reach < min_t)
            return Fail("MIN_TARGET",
                        StringFormat("reach %.2f (%.1f pips) below minimum %.2f (%.1f pips)",
                                     reach, reach / pip, min_t, min_t / pip),
                        strategy_id, ctx.symbol);
        }

      //--- 16. the stop must survive the spread ------------------------
      double spread_price = ctx.spread_points * ctx.point;
      if(signed_dist < spread_price * 2.0)
         return Fail("STOP_INSIDE_SPREAD",
                     StringFormat("stop %.5f is less than 2x spread %.5f",
                                  signed_dist, spread_price),
                     strategy_id, ctx.symbol);

      return ok;
     }
  };

#endif // __ADAPTIVE_TRADEGATE_MQH__

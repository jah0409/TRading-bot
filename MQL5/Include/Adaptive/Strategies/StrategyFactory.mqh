//+------------------------------------------------------------------+
//| StrategyFactory.mqh - config "type" string -> concrete class      |
//|                                                                    |
//| The ONLY place that names concrete strategy classes. Adding a new  |
//| strategy is: write the class, add one line here, add a block to    |
//| config.json. Nothing else in the EA changes.                       |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_STRATEGYFACTORY_MQH__
#define __ADAPTIVE_STRATEGYFACTORY_MQH__

#include "StrategyBase.mqh"
#include "TrendFollowEma.mqh"
#include "MeanReversionBB.mqh"
#include "BreakoutDonchian.mqh"
#include "MomentumPullback.mqh"
#include "RangeFadeRsi.mqh"
#include "BosChochContinuation.mqh"
#include "PortfolioStrategies.mqh"

class CStrategyFactory
  {
public:
   //--- caller owns the returned pointer and must delete it
   static CStrategyBase *Create(const string type)
     {
      if(type == "trend_follow_ema")   return new CTrendFollowEma();
      if(type == "mean_reversion_bb")  return new CMeanReversionBB();
      if(type == "breakout_donchian")  return new CBreakoutDonchian();
      if(type == "momentum_pullback")  return new CMomentumPullback();
      if(type == "range_fade_rsi")     return new CRangeFadeRsi();
      if(type == "bos_choch")          return new CBosChochContinuation();
      if(type == "trend_continuation") return new CTrendContinuation();
      if(type == "pdh_pdl_reaction")   return new CPdhPdlReaction();
      if(type == "session_breakout")   return new CSessionBreakout();
      if(type == "liquidity_sweep")    return new CLiquiditySweepRev();
      return NULL;
     }

   static string     KnownTypes(void)
     {
      return "trend_follow_ema, mean_reversion_bb, breakout_donchian, "
             "momentum_pullback, range_fade_rsi, bos_choch, "
             "trend_continuation, pdh_pdl_reaction, session_breakout, "
             "liquidity_sweep";
     }
  };

#endif // __ADAPTIVE_STRATEGYFACTORY_MQH__

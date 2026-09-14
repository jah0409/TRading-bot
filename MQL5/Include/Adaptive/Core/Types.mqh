//+------------------------------------------------------------------+
//| Types.mqh - shared vocabulary for the Adaptive EA                 |
//|                                                                    |
//| Every module speaks in these types. Nothing here has behaviour;    |
//| it is the contract between regime detection, strategies, risk and  |
//| execution.                                                         |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_TYPES_MQH__
#define __ADAPTIVE_TYPES_MQH__

#define ADAPTIVE_VERSION "0.1.0-skeleton"

//--- Market regimes -------------------------------------------------
enum ENUM_REGIME
  {
   REGIME_UNKNOWN    = 0,   // not enough data / conflicting evidence
   REGIME_TREND_UP   = 1,   // directional, ADX high, +DI dominant
   REGIME_TREND_DOWN = 2,   // directional, ADX high, -DI dominant
   REGIME_RANGE      = 3,   // ADX low, ATR compressed, price mean-reverting
   REGIME_BREAKOUT   = 4,   // volatility expansion out of compression
   REGIME_CHOP_HIVOL = 5    // high ATR with no direction - the account killer
  };

//--- Timeframe slots used for multi-timeframe regime evaluation -----
enum ENUM_TF_SLOT
  {
   TF_SLOT_M15 = 0,
   TF_SLOT_H1  = 1,
   TF_SLOT_H4  = 2
  };
#define TF_SLOT_COUNT 3

//--- Risk ramp phases (see EXECUTION AND MONEY MANAGEMENT) ----------
enum ENUM_RISK_PHASE
  {
   PHASE_MONTH_1 = 1,   // 0.25% per trade
   PHASE_MONTH_2 = 2,   // 0.50% per trade, max 3 concurrent strategies
   PHASE_MONTH_3 = 3    // 1.00% per trade, max 5 concurrent strategies (hard ceiling)
  };

//--- Why the risk manager or news filter said no --------------------
enum ENUM_BLOCK_REASON
  {
   BLOCK_NONE = 0,
   BLOCK_DAILY_LOCK,          // >= 2% day loss, locked until server rollover
   BLOCK_KILL_SWITCH,         // >= 5% equity drawdown, flat + locked
   BLOCK_MAX_TOTAL_LOSS,      // approaching the $1,000 hard breach
   BLOCK_NEWS_BLACKOUT,       // inside a high-impact event window
   BLOCK_TRADE_RISK_CAP,      // single trade risk > allowed %
   BLOCK_STRATEGY_RISK_CAP,   // this strategy already at its 1% budget
   BLOCK_AGGREGATE_STOP_CAP,  // sum of open stops would exceed 10% of balance
   BLOCK_MAX_POSITIONS,       // per-symbol / global position count
   BLOCK_MARGIN,              // not enough free margin
   BLOCK_SPREAD,              // spread outside tolerance
   BLOCK_INVALID_STOP,        // SL missing, zero distance, or inside stops level
   BLOCK_LOT_TOO_SMALL,       // min lot would risk more than the cap
   BLOCK_SESSION_CLOSED,      // outside configured trading session
   BLOCK_CORRELATION          // correlated exposure cap (XAUUSD vs US100)
  };

//--- Candle / price-action flags folded into regime scoring ---------
#define CANDLE_NONE            0
#define CANDLE_INSIDE_BAR      (1<<0)
#define CANDLE_OUTSIDE_BAR     (1<<1)
#define CANDLE_NR7             (1<<2)   // narrowest range of last 7 -> coil
#define CANDLE_WIDE_RANGE      (1<<3)   // expansion bar
#define CANDLE_PIN_BULL        (1<<4)
#define CANDLE_PIN_BEAR        (1<<5)
#define CANDLE_ENGULF_BULL     (1<<6)
#define CANDLE_ENGULF_BEAR     (1<<7)
#define CANDLE_DOJI            (1<<8)

//--- Per-timeframe regime reading -----------------------------------
struct SRegimeTF
  {
   ENUM_REGIME       regime;
   double            atr;             // absolute ATR in price
   double            atr_pct;         // ATR / price, comparable across symbols
   double            atr_percentile;  // 0..1, ATR rank vs lookback window
   double            adx;
   double            di_plus;
   double            di_minus;
   int               candle_flags;    // bitmask of CANDLE_*
   double            confidence;      // 0..1, margin between the top two scores
   //--- calibration features. All three are scale-free on purpose: an
   //--- absolute ATR or DI value means nothing shared between gold and
   //--- a cash index, but a ratio or a percentile does.
   double            di_spread_norm;  // |DI+ - DI-| / (DI+ + DI-), 0..1
   double            atr_expansion;   // ATR now / mean ATR over the lookback
   double            compression;     // 0..1, how coiled the PRIOR bars were
  };

//--- continuous per-regime scores. The classifier is an argmax over
//--- these rather than a chain of ifs, so every threshold becomes a
//--- soft ramp that calibration can move, and the confidences of two
//--- different regimes are directly comparable.
struct SRegimeScores
  {
   double            trend_up;
   double            trend_down;
   double            range;
   double            breakout;
   double            chop;
  };

//--- Full multi-timeframe snapshot for one symbol -------------------
struct SRegimeSnapshot
  {
   string            symbol;
   datetime          evaluated_at;
   SRegimeTF         tf[TF_SLOT_COUNT];
   ENUM_REGIME       composite;        // blended M15/H1/H4 verdict
   double            composite_conf;   // 0..1
   bool              aligned;          // all three timeframes agree on direction
  };

//--- What a strategy is handed on every evaluation ------------------
struct SMarketContext
  {
   string            symbol;
   datetime          now;
   SRegimeSnapshot   regime;
   //--- risk envelope currently in force
   ENUM_RISK_PHASE   phase;
   double            risk_pct_per_trade;   // phase-adjusted, already capped
   //--- news posture
   bool              news_blackout;        // hard stop: flat + no entries
   bool              news_caution;         // elevated volatility expected
   double            news_size_mult;       // <=1.0 size scaler
   double            news_stop_mult;       // >=1.0 stop widener
   string            news_label;           // e.g. "CPI in 00:42"
   //--- reference ATR (H1) for stop-distance sanity checks
   double            atr_ref;
   //--- live pricing / symbol metrics
   double            bid;
   double            ask;
   double            spread_points;
   double            point;
   int               digits;
   double            tick_size;
   double            tick_value;
   double            min_lot;
   double            max_lot;
   double            lot_step;
   long              stops_level_points;
  };

//--- A strategy's proposed entry ------------------------------------
struct SEntrySignal
  {
   bool              valid;
   ENUM_ORDER_TYPE   direction;     // ORDER_TYPE_BUY or ORDER_TYPE_SELL
   double            entry_price;   // 0 => market order
   double            stop_loss;     // MANDATORY - risk manager rejects a naked entry
   double            take_profit;   // 0 => managed by Exit()/TrailStop() only
   double            confidence;    // 0..1, feeds allocation weighting
   string            reason;        // human-readable, goes to the CSV log
  };

//--- A strategy's exit decision for a position it owns --------------
struct SExitDecision
  {
   bool              should_exit;
   double            fraction;      // 1.0 = full close, 0.5 = half off
   string            reason;
  };

//--- What the risk manager is asked to approve ----------------------
struct STradeIntent
  {
   string            symbol;
   string            strategy_id;
   long              magic;
   ENUM_ORDER_TYPE   direction;
   double            entry_price;
   double            stop_loss;     // MANDATORY
   double            take_profit;   // 0 => managed by Exit()/TrailStop()
   double            lots;          // filled in by RiskManager::CalcLots
   double            risk_money;    // filled in by RiskManager::CalcLots
   double            risk_pct;      // of the risk basis balance
  };

//--- The risk manager's answer --------------------------------------
struct SRiskVerdict
  {
   bool              approved;
   double            approved_lots; // may be smaller than requested
   ENUM_BLOCK_REASON reason;
   string            detail;
  };

//--- Rolling performance for one strategy (optionally per regime) ---
struct SPerfStats
  {
   int               trades;
   int               wins;
   double            gross_profit;
   double            gross_loss;    // positive number
   double            net_profit;
   double            max_drawdown;
   double            expectancy_r;  // average R multiple
   double            win_rate;
   double            profit_factor;
   datetime          last_update;
  };

//--- Helpers --------------------------------------------------------
string RegimeToString(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND_UP:   return "TREND_UP";
      case REGIME_TREND_DOWN: return "TREND_DOWN";
      case REGIME_RANGE:      return "RANGE";
      case REGIME_BREAKOUT:   return "BREAKOUT";
      case REGIME_CHOP_HIVOL: return "CHOP_HIVOL";
      default:                return "UNKNOWN";
     }
  }

string BlockReasonToString(const ENUM_BLOCK_REASON b)
  {
   switch(b)
     {
      case BLOCK_NONE:              return "OK";
      case BLOCK_DAILY_LOCK:        return "DAILY_LOCK";
      case BLOCK_KILL_SWITCH:       return "KILL_SWITCH";
      case BLOCK_MAX_TOTAL_LOSS:    return "MAX_TOTAL_LOSS";
      case BLOCK_NEWS_BLACKOUT:     return "NEWS_BLACKOUT";
      case BLOCK_TRADE_RISK_CAP:    return "TRADE_RISK_CAP";
      case BLOCK_STRATEGY_RISK_CAP: return "STRATEGY_RISK_CAP";
      case BLOCK_AGGREGATE_STOP_CAP:return "AGGREGATE_STOP_CAP";
      case BLOCK_MAX_POSITIONS:     return "MAX_POSITIONS";
      case BLOCK_MARGIN:            return "MARGIN";
      case BLOCK_SPREAD:            return "SPREAD";
      case BLOCK_INVALID_STOP:      return "INVALID_STOP";
      case BLOCK_LOT_TOO_SMALL:     return "LOT_TOO_SMALL";
      case BLOCK_SESSION_CLOSED:    return "SESSION_CLOSED";
      case BLOCK_CORRELATION:       return "CORRELATION";
      default:                      return "UNKNOWN";
     }
  }

string TfSlotToString(const ENUM_TF_SLOT s)
  {
   switch(s)
     {
      case TF_SLOT_M15: return "M15";
      case TF_SLOT_H1:  return "H1";
      case TF_SLOT_H4:  return "H4";
      default:          return "??";
     }
  }

ENUM_TIMEFRAMES TfSlotToTimeframe(const ENUM_TF_SLOT s)
  {
   switch(s)
     {
      case TF_SLOT_M15: return PERIOD_M15;
      case TF_SLOT_H1:  return PERIOD_H1;
      case TF_SLOT_H4:  return PERIOD_H4;
      default:          return PERIOD_CURRENT;
     }
  }

#endif // __ADAPTIVE_TYPES_MQH__

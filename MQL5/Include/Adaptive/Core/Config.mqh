//+------------------------------------------------------------------+
//| Config.mqh - typed view over config.json                          |
//|                                                                    |
//| Loads MQL5/Files/Adaptive/config.json once at OnInit, validates it |
//| against the live account, and exposes typed structs. The raw CJson |
//| stays alive so strategies can read their own free-form params by   |
//| path (strategies.<id>.params.*) without this file knowing about    |
//| any particular strategy.                                           |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_CONFIG_MQH__
#define __ADAPTIVE_CONFIG_MQH__

#include "Types.mqh"
#include "Json.mqh"

//--- Prop-firm account envelope -------------------------------------
struct SAccountConfig
  {
   string            firm;
   long              login;                  // 70188572 - validated at init
   double            initial_balance;        // 10000.00 - the rules' measuring stick
   double            max_total_loss_pct;     // 10.0  ($1,000)
   double            max_daily_loss_pct;     //  4.0  ($400)
   double            firm_max_risk_trade_pct;//  5.0  (firm ceiling, NOT our target)
   string            drawdown_basis;         // "static_initial" | "trailing_peak" | "worst_of"
   bool              enforce_login_match;
  };

//--- Our own, tighter risk envelope ---------------------------------
struct SRiskConfig
  {
   double            strategy_max_risk_pct;   // 1.0 - per-strategy budget
   double            aggregate_stop_cap_pct;  // 10.0 - sum of open stops
   double            kill_switch_dd_pct;      // 5.0  - flatten everything
   double            daily_lock_loss_pct;     // 2.0  - lock until rollover
   double            max_spread_points_xau;
   double            max_spread_points_idx;
   int               max_positions_total;
   int               max_positions_per_symbol;
   int               max_positions_per_strategy;
   double            correlation_cap_pct;     // combined risk across correlated symbols
   bool              require_stop_loss;       // always true; kept explicit
   double            min_stop_atr_mult;       // reject stops closer than this x ATR
   //--- risk ramp
   datetime          deployment_start;
   double            phase1_risk_pct;         // 0.25
   double            phase2_risk_pct;         // 0.50
   double            phase3_risk_pct;         // 1.00
   int               phase1_max_strategies;
   int               phase2_max_strategies;   // 3
   int               phase3_max_strategies;   // 5 - never exceeded
   bool              phase_auto_advance;      // advance only if profitable
   double            phase_advance_min_profit_pct;
  };

//--- Regime detection tuning ----------------------------------------
struct SRegimeConfig
  {
   int               atr_period;
   int               adx_period;
   int               atr_percentile_lookback;
   //--- legacy hard thresholds. Still read, and still used to derive
   //--- the soft ramps below when those are not given explicitly.
   double            adx_trend_threshold;     // >= => trending
   double            adx_range_threshold;     // <= => ranging
   double            atr_high_percentile;     // >= => high volatility
   double            atr_low_percentile;      // <= => compression
   //--- soft ramp bounds: score goes 0 at _lo, 1 at _hi. These are what
   //--- tools/calibrate_regime.py fits, per symbol.
   double            adx_trend_lo;
   double            adx_trend_hi;
   double            adx_range_lo;            // range score ramps DOWN over this
   double            adx_range_hi;
   double            di_spread_lo;
   double            di_spread_hi;
   double            atr_vol_lo;              // percentile ramp for "high vol"
   double            atr_vol_hi;
   double            atr_expansion_lo;
   double            atr_expansion_hi;
   int               compression_lookback;    // bars of coil to look back over
   double            compression_min;         // breakout needs at least this
   double            tf_weight[TF_SLOT_COUNT];// M15/H1/H4 blend weights
   double            min_composite_confidence;
   int               min_bars_in_regime;      // hysteresis: bars before switching
   double            min_score_to_classify;   // below this the bar is UNKNOWN
  };

//--- News filter -----------------------------------------------------
struct SNewsConfig
  {
   bool              enabled;
   int               tier_a_minutes_before;   // 60 - FOMC/NFP/CPI/GDP/central banks
   int               tier_a_minutes_after;    // 60
   int               tier_b_minutes_before;   // 30 - retail sales/PMI/sentiment
   int               tier_b_minutes_after;    // 30
   int               caution_minutes_before;  // wider band: shrink size, widen stops
   int               caution_minutes_after;
   double            caution_size_mult;
   double            caution_stop_mult;
   bool              close_positions_on_blackout;
   bool              use_mql5_calendar;       // native; unavailable in Strategy Tester
   bool              use_csv_fallback;
   string            csv_path;
   bool              use_web_api;             // needs URL whitelisting in terminal
   string            web_api_url;
   int               refresh_minutes;
   int               stale_after_minutes;     // if the feed is older, fail CLOSED
   bool              fail_closed_if_stale;    // no calendar == no trading
   string            currencies_xau;          // CSV, e.g. "USD,EUR,GBP,JPY" - gold reacts to all
   string            currencies_idx;          // CSV, e.g. "USD"
  };

//--- Execution -------------------------------------------------------
struct SExecConfig
  {
   long              magic_base;              // per-strategy magic = base + index
   int               slippage_points;
   int               max_retries;
   int               retry_delay_ms;
   int               main_loop_seconds;       // 5
   bool              trade_on_tick_trailing;  // trail at tick granularity
   string            order_comment_prefix;
  };

//--- One strategy's registration entry -------------------------------
struct SStrategyConfig
  {
   string            id;                      // unique key, also the magic offset
   string            type;                    // maps to a class in StrategyFactory
   bool              enabled;                 // master on/off, before regime gating
   string            symbols_csv;             // which of the traded symbols it may use
   string            json_path;               // "strategies.<n>" for params lookup
   long              magic;
   double            suitability[6];          // indexed by ENUM_REGIME
   double            min_suitability_to_run;
   double            capital_weight;          // virtual account allocation share
  };

class CConfig
  {
private:
   CJson             m_json;
   bool              m_loaded;
   string            m_error;

   SAccountConfig    m_account;
   SRiskConfig       m_risk;
   SRegimeConfig     m_regime;
   SNewsConfig       m_news;
   SExecConfig       m_exec;
   string            m_symbols[];
   SStrategyConfig   m_strategies[];

   datetime          ParseDate(const string s, const datetime def)
     {
      if(s == "")
         return def;
      datetime d = StringToTime(s);
      return (d > 0 ? d : def);
     }

public:
                     CConfig(void) : m_loaded(false), m_error("") {}

   bool              IsLoaded(void)  const { return m_loaded; }
   string            LastError(void) const { return m_error; }
   CJson            *Json(void)            { return GetPointer(m_json); }

   SAccountConfig Account(void) const { return m_account; }
   SRiskConfig    Risk(void)    const { return m_risk; }
   SRegimeConfig  Regime(void)  const { return m_regime; }

   //+---------------------------------------------------------------+
   //| Regime settings for ONE symbol: defaults with any
   //| regime.per_symbol.<SYMBOL>.* overrides applied on top.
   //|
   //| Gold and a cash index do not share an ADX threshold. Anything
   //| calibration fits is per symbol, so this is the accessor the
   //| detector actually uses.
   //+---------------------------------------------------------------+
   SRegimeConfig  RegimeFor(const string symbol)
     {
      SRegimeConfig rc = m_regime;
      string base = "regime.per_symbol." + symbol;
      if(!m_json.Exists(base))
         return rc;

      rc.atr_period               = m_json.GetInt(base + ".atr_period", rc.atr_period);
      rc.adx_period               = m_json.GetInt(base + ".adx_period", rc.adx_period);
      rc.atr_percentile_lookback  = m_json.GetInt(base + ".atr_percentile_lookback",
                                                  rc.atr_percentile_lookback);
      rc.adx_trend_lo             = m_json.GetDouble(base + ".adx_trend_lo", rc.adx_trend_lo);
      rc.adx_trend_hi             = m_json.GetDouble(base + ".adx_trend_hi", rc.adx_trend_hi);
      rc.adx_range_lo             = m_json.GetDouble(base + ".adx_range_lo", rc.adx_range_lo);
      rc.adx_range_hi             = m_json.GetDouble(base + ".adx_range_hi", rc.adx_range_hi);
      rc.di_spread_lo             = m_json.GetDouble(base + ".di_spread_lo", rc.di_spread_lo);
      rc.di_spread_hi             = m_json.GetDouble(base + ".di_spread_hi", rc.di_spread_hi);
      rc.atr_vol_lo               = m_json.GetDouble(base + ".atr_vol_lo", rc.atr_vol_lo);
      rc.atr_vol_hi               = m_json.GetDouble(base + ".atr_vol_hi", rc.atr_vol_hi);
      rc.atr_expansion_lo         = m_json.GetDouble(base + ".atr_expansion_lo", rc.atr_expansion_lo);
      rc.atr_expansion_hi         = m_json.GetDouble(base + ".atr_expansion_hi", rc.atr_expansion_hi);
      rc.compression_lookback     = m_json.GetInt(base + ".compression_lookback",
                                                  rc.compression_lookback);
      rc.compression_min          = m_json.GetDouble(base + ".compression_min", rc.compression_min);
      rc.min_score_to_classify    = m_json.GetDouble(base + ".min_score_to_classify",
                                                     rc.min_score_to_classify);
      rc.min_composite_confidence = m_json.GetDouble(base + ".min_composite_confidence",
                                                     rc.min_composite_confidence);
      rc.min_bars_in_regime       = m_json.GetInt(base + ".min_bars_in_regime",
                                                  rc.min_bars_in_regime);
      rc.tf_weight[TF_SLOT_M15]   = m_json.GetDouble(base + ".tf_weight.M15", rc.tf_weight[TF_SLOT_M15]);
      rc.tf_weight[TF_SLOT_H1]    = m_json.GetDouble(base + ".tf_weight.H1", rc.tf_weight[TF_SLOT_H1]);
      rc.tf_weight[TF_SLOT_H4]    = m_json.GetDouble(base + ".tf_weight.H4", rc.tf_weight[TF_SLOT_H4]);
      return rc;
     }
   SNewsConfig    News(void)    const { return m_news; }
   SExecConfig    Exec(void)    const { return m_exec; }

   //--- evidence gates for risk-phase promotion (see risk ramp, sect 24)
   int               Json_MinTrades(void)
     { return m_json.GetInt("risk.ramp.advance_min_live_trades", 40); }
   double            Json_MaxDd(void)
     { return m_json.GetDouble("risk.ramp.advance_max_drawdown_pct", 3.0); }

   int               SymbolCount(void) const { return ArraySize(m_symbols); }
   string            SymbolAt(const int i) const
     {
      return (i >= 0 && i < ArraySize(m_symbols) ? m_symbols[i] : "");
     }

   int               StrategyCount(void) const { return ArraySize(m_strategies); }
   bool              StrategyAt(const int i, SStrategyConfig &out) const
     {
      if(i < 0 || i >= ArraySize(m_strategies))
         return false;
      out = m_strategies[i];
      return true;
     }

   //+---------------------------------------------------------------+
   //| Load and validate                                              |
   //+---------------------------------------------------------------+
   bool              Load(const string path)
     {
      m_loaded = false;
      m_error  = "";

      if(!m_json.LoadFile(path))
        {
         m_error = "config parse failed: " + m_json.LastError();
         return false;
        }

      //--- account -----------------------------------------------------
      m_account.firm                    = m_json.GetString("account.firm", "LegionFunding");
      m_account.login                   = (long)m_json.GetDouble("account.login", 0);
      m_account.initial_balance         = m_json.GetDouble("account.initial_balance", 10000.0);
      m_account.max_total_loss_pct      = m_json.GetDouble("account.max_total_loss_pct", 10.0);
      m_account.max_daily_loss_pct      = m_json.GetDouble("account.max_daily_loss_pct", 4.0);
      m_account.firm_max_risk_trade_pct = m_json.GetDouble("account.firm_max_risk_per_trade_pct", 5.0);
      m_account.drawdown_basis          = m_json.GetString("account.drawdown_basis", "worst_of");
      m_account.enforce_login_match     = m_json.GetBool("account.enforce_login_match", true);

      //--- risk --------------------------------------------------------
      m_risk.strategy_max_risk_pct      = m_json.GetDouble("risk.strategy_max_risk_pct", 1.0);
      m_risk.aggregate_stop_cap_pct     = m_json.GetDouble("risk.aggregate_stop_cap_pct", 10.0);
      m_risk.kill_switch_dd_pct         = m_json.GetDouble("risk.kill_switch_dd_pct", 5.0);
      m_risk.daily_lock_loss_pct        = m_json.GetDouble("risk.daily_lock_loss_pct", 2.0);
      m_risk.max_spread_points_xau      = m_json.GetDouble("risk.max_spread_points_xauusd", 60);
      m_risk.max_spread_points_idx      = m_json.GetDouble("risk.max_spread_points_index", 300);
      m_risk.max_positions_total        = m_json.GetInt("risk.max_positions_total", 6);
      m_risk.max_positions_per_symbol   = m_json.GetInt("risk.max_positions_per_symbol", 3);
      m_risk.max_positions_per_strategy = m_json.GetInt("risk.max_positions_per_strategy", 1);
      m_risk.correlation_cap_pct        = m_json.GetDouble("risk.correlation_cap_pct", 2.0);
      m_risk.require_stop_loss          = m_json.GetBool("risk.require_stop_loss", true);
      m_risk.min_stop_atr_mult          = m_json.GetDouble("risk.min_stop_atr_mult", 0.5);

      m_risk.deployment_start           = ParseDate(m_json.GetString("risk.ramp.deployment_start", ""),
                                                    TimeCurrent());
      m_risk.phase1_risk_pct            = m_json.GetDouble("risk.ramp.phase1_risk_pct", 0.25);
      m_risk.phase2_risk_pct            = m_json.GetDouble("risk.ramp.phase2_risk_pct", 0.50);
      m_risk.phase3_risk_pct            = m_json.GetDouble("risk.ramp.phase3_risk_pct", 1.00);
      m_risk.phase1_max_strategies      = m_json.GetInt("risk.ramp.phase1_max_strategies", 2);
      m_risk.phase2_max_strategies      = m_json.GetInt("risk.ramp.phase2_max_strategies", 3);
      m_risk.phase3_max_strategies      = m_json.GetInt("risk.ramp.phase3_max_strategies", 5);
      m_risk.phase_auto_advance         = m_json.GetBool("risk.ramp.auto_advance", true);
      m_risk.phase_advance_min_profit_pct = m_json.GetDouble("risk.ramp.advance_min_profit_pct", 0.0);

      //--- regime ------------------------------------------------------
      m_regime.atr_period               = m_json.GetInt("regime.atr_period", 14);
      m_regime.adx_period               = m_json.GetInt("regime.adx_period", 14);
      m_regime.atr_percentile_lookback  = m_json.GetInt("regime.atr_percentile_lookback", 100);
      m_regime.adx_trend_threshold      = m_json.GetDouble("regime.adx_trend_threshold", 25.0);
      m_regime.adx_range_threshold      = m_json.GetDouble("regime.adx_range_threshold", 20.0);
      m_regime.atr_high_percentile      = m_json.GetDouble("regime.atr_high_percentile", 0.75);
      m_regime.atr_low_percentile       = m_json.GetDouble("regime.atr_low_percentile", 0.25);
      //--- soft ramps default to a band around the legacy thresholds, so
      //--- an un-calibrated config keeps working and calibration simply
      //--- writes explicit _lo/_hi values over the top
      m_regime.adx_trend_lo             = m_json.GetDouble("regime.adx_trend_lo",
                                                           m_regime.adx_trend_threshold - 5.0);
      m_regime.adx_trend_hi             = m_json.GetDouble("regime.adx_trend_hi",
                                                           m_regime.adx_trend_threshold + 10.0);
      m_regime.adx_range_lo             = m_json.GetDouble("regime.adx_range_lo",
                                                           m_regime.adx_range_threshold - 5.0);
      m_regime.adx_range_hi             = m_json.GetDouble("regime.adx_range_hi",
                                                           m_regime.adx_range_threshold + 8.0);
      m_regime.di_spread_lo             = m_json.GetDouble("regime.di_spread_lo", 0.10);
      m_regime.di_spread_hi             = m_json.GetDouble("regime.di_spread_hi", 0.40);
      m_regime.atr_vol_lo               = m_json.GetDouble("regime.atr_vol_lo",
                                                           m_regime.atr_high_percentile - 0.20);
      m_regime.atr_vol_hi               = m_json.GetDouble("regime.atr_vol_hi",
                                                           m_regime.atr_high_percentile + 0.10);
      m_regime.atr_expansion_lo         = m_json.GetDouble("regime.atr_expansion_lo", 1.15);
      m_regime.atr_expansion_hi         = m_json.GetDouble("regime.atr_expansion_hi", 1.80);
      m_regime.compression_lookback     = m_json.GetInt("regime.compression_lookback", 10);
      m_regime.compression_min          = m_json.GetDouble("regime.compression_min", 0.20);
      m_regime.min_score_to_classify    = m_json.GetDouble("regime.min_score_to_classify", 0.20);

      m_regime.tf_weight[TF_SLOT_M15]   = m_json.GetDouble("regime.tf_weight.M15", 0.25);
      m_regime.tf_weight[TF_SLOT_H1]    = m_json.GetDouble("regime.tf_weight.H1", 0.40);
      m_regime.tf_weight[TF_SLOT_H4]    = m_json.GetDouble("regime.tf_weight.H4", 0.35);
      m_regime.min_composite_confidence = m_json.GetDouble("regime.min_composite_confidence", 0.45);
      m_regime.min_bars_in_regime       = m_json.GetInt("regime.min_bars_in_regime", 2);

      //--- news --------------------------------------------------------
      m_news.enabled                    = m_json.GetBool("news.enabled", true);
      m_news.tier_a_minutes_before      = m_json.GetInt("news.tier_a.minutes_before", 60);
      m_news.tier_a_minutes_after       = m_json.GetInt("news.tier_a.minutes_after", 60);
      m_news.tier_b_minutes_before      = m_json.GetInt("news.tier_b.minutes_before", 30);
      m_news.tier_b_minutes_after       = m_json.GetInt("news.tier_b.minutes_after", 30);
      m_news.caution_minutes_before     = m_json.GetInt("news.caution.minutes_before", 120);
      m_news.caution_minutes_after      = m_json.GetInt("news.caution.minutes_after", 120);
      m_news.caution_size_mult          = m_json.GetDouble("news.caution.size_mult", 0.5);
      m_news.caution_stop_mult          = m_json.GetDouble("news.caution.stop_mult", 1.5);
      m_news.close_positions_on_blackout= m_json.GetBool("news.close_positions_on_blackout", true);
      m_news.use_mql5_calendar          = m_json.GetBool("news.sources.mql5_calendar", true);
      m_news.use_csv_fallback           = m_json.GetBool("news.sources.csv_fallback", true);
      m_news.csv_path                   = m_json.GetString("news.sources.csv_path",
                                                           "Adaptive\\calendar.csv");
      m_news.use_web_api                = m_json.GetBool("news.sources.web_api", false);
      m_news.web_api_url                = m_json.GetString("news.sources.web_api_url", "");
      m_news.refresh_minutes            = m_json.GetInt("news.refresh_minutes", 60);
      m_news.stale_after_minutes        = m_json.GetInt("news.stale_after_minutes", 1440);
      m_news.fail_closed_if_stale       = m_json.GetBool("news.fail_closed_if_stale", true);
      m_news.currencies_xau             = m_json.GetString("news.currencies.XAU", "USD,EUR,GBP,JPY");
      m_news.currencies_idx             = m_json.GetString("news.currencies.INDEX", "USD");

      //--- execution ---------------------------------------------------
      m_exec.magic_base                 = (long)m_json.GetDouble("execution.magic_base", 701885);
      m_exec.slippage_points            = m_json.GetInt("execution.slippage_points", 20);
      m_exec.max_retries                = m_json.GetInt("execution.max_retries", 3);
      m_exec.retry_delay_ms             = m_json.GetInt("execution.retry_delay_ms", 250);
      m_exec.main_loop_seconds          = m_json.GetInt("execution.main_loop_seconds", 5);
      m_exec.trade_on_tick_trailing     = m_json.GetBool("execution.trail_on_tick", true);
      m_exec.order_comment_prefix       = m_json.GetString("execution.order_comment_prefix", "ADPT");

      //--- symbols -----------------------------------------------------
      m_json.GetStringArray("symbols", m_symbols);
      if(ArraySize(m_symbols) == 0)
        {
         ArrayResize(m_symbols, 2);
         m_symbols[0] = "XAUUSD";
         m_symbols[1] = "US100";
        }

      //--- strategies --------------------------------------------------
      int n = m_json.Count("strategies");
      ArrayResize(m_strategies, n);
      for(int i = 0; i < n; i++)
        {
         string base = StringFormat("strategies.%d", i);
         m_strategies[i].id      = m_json.GetString(base + ".id", StringFormat("strategy_%d", i));
         m_strategies[i].type    = m_json.GetString(base + ".type", "");
         m_strategies[i].enabled = m_json.GetBool(base + ".enabled", true);
         m_strategies[i].json_path = base;
         m_strategies[i].magic   = m_exec.magic_base * 100 + i;
         string syms[];
         m_json.GetStringArray(base + ".symbols", syms);
         m_strategies[i].symbols_csv = "";
         for(int k = 0; k < ArraySize(syms); k++)
            m_strategies[i].symbols_csv += (k > 0 ? "," : "") + syms[k];
         if(m_strategies[i].symbols_csv == "")
            for(int k = 0; k < ArraySize(m_symbols); k++)
               m_strategies[i].symbols_csv += (k > 0 ? "," : "") + m_symbols[k];

         //--- suitability per regime, indexed by ENUM_REGIME
         m_strategies[i].suitability[REGIME_UNKNOWN]    = m_json.GetDouble(base + ".suitability.UNKNOWN", 0.0);
         m_strategies[i].suitability[REGIME_TREND_UP]   = m_json.GetDouble(base + ".suitability.TREND_UP", 0.0);
         m_strategies[i].suitability[REGIME_TREND_DOWN] = m_json.GetDouble(base + ".suitability.TREND_DOWN", 0.0);
         m_strategies[i].suitability[REGIME_RANGE]      = m_json.GetDouble(base + ".suitability.RANGE", 0.0);
         m_strategies[i].suitability[REGIME_BREAKOUT]   = m_json.GetDouble(base + ".suitability.BREAKOUT", 0.0);
         m_strategies[i].suitability[REGIME_CHOP_HIVOL] = m_json.GetDouble(base + ".suitability.CHOP_HIVOL", 0.0);

         m_strategies[i].min_suitability_to_run = m_json.GetDouble(base + ".min_suitability_to_run", 0.50);
         m_strategies[i].capital_weight         = m_json.GetDouble(base + ".capital_weight", 1.0);
        }

      m_loaded = true;
      return true;
     }

   //+---------------------------------------------------------------+
   //| Validate against the live terminal. Returns false on a hard    |
   //| mismatch - the EA must refuse to trade rather than guess.      |
   //+---------------------------------------------------------------+
   bool              Validate(string &problems)
     {
      problems = "";
      bool ok = true;

      //--- account identity
      long live_login = AccountInfoInteger(ACCOUNT_LOGIN);
      if(m_account.enforce_login_match && m_account.login > 0 && live_login != m_account.login)
        {
         problems += StringFormat("account login mismatch: config=%I64d live=%I64d; ",
                                  m_account.login, live_login);
         ok = false;
        }

      //--- our caps must sit inside the firm's caps
      if(m_risk.strategy_max_risk_pct > m_account.firm_max_risk_trade_pct)
        {
         problems += "strategy_max_risk_pct exceeds firm per-trade ceiling; ";
         ok = false;
        }
      if(m_risk.kill_switch_dd_pct >= m_account.max_total_loss_pct)
        {
         problems += "kill_switch_dd_pct must be below max_total_loss_pct; ";
         ok = false;
        }
      if(m_risk.daily_lock_loss_pct >= m_account.max_daily_loss_pct)
        {
         problems += "daily_lock_loss_pct must be below max_daily_loss_pct; ";
         ok = false;
        }
      if(m_risk.phase3_risk_pct > m_risk.strategy_max_risk_pct)
        {
         problems += "phase3_risk_pct exceeds strategy_max_risk_pct; ";
         ok = false;
        }
      if(m_risk.phase3_max_strategies > 5)
        {
         problems += "phase3_max_strategies capped at 5 by spec; ";
         ok = false;
        }

      //--- NOTE: aggregate_stop_cap_pct == max_total_loss_pct means a
      //--- simultaneous stop-out on every open position is an instant
      //--- account breach. Warn loudly; see ARCHITECTURE.md "Risk maths".
      if(m_risk.aggregate_stop_cap_pct >= m_account.max_total_loss_pct)
         problems += StringFormat("WARNING aggregate stop cap %.1f%% == max total loss %.1f%%: "
                                  "a simultaneous stop-out breaches the account; ",
                                  m_risk.aggregate_stop_cap_pct, m_account.max_total_loss_pct);

      //--- tradable symbols must exist and be selectable
      for(int i = 0; i < ArraySize(m_symbols); i++)
        {
         if(!SymbolSelect(m_symbols[i], true))
           {
            problems += StringFormat("symbol '%s' not available at broker; ", m_symbols[i]);
            ok = false;
           }
        }

      //--- strategies
      if(ArraySize(m_strategies) == 0)
        {
         problems += "no strategies configured; ";
         ok = false;
        }

      //--- regime weights should sum to ~1
      double wsum = m_regime.tf_weight[0] + m_regime.tf_weight[1] + m_regime.tf_weight[2];
      if(MathAbs(wsum - 1.0) > 0.01)
         problems += StringFormat("regime tf weights sum to %.3f (expected 1.0); ", wsum);

      return ok;
     }
  };

#endif // __ADAPTIVE_CONFIG_MQH__

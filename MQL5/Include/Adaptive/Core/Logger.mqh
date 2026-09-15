//+------------------------------------------------------------------+
//| Logger.mqh - CSV telemetry for post-hoc analysis                  |
//|                                                                    |
//| Five independent streams, all under MQL5/Files/Adaptive/logs/:     |
//|   trades_YYYYMMDD.csv    every fill, exit and its attribution      |
//|   equity_YYYYMMDD.csv    equity/DD/exposure heartbeat              |
//|   regime_YYYYMMDD.csv    regime transitions per symbol             |
//|   strategy_YYYYMMDD.csv  enable/disable + suitability scores       |
//|   risk_YYYYMMDD.csv      every block, lock, kill-switch event      |
//|                                                                    |
//| Files are reopened per write and closed immediately so a terminal  |
//| crash never costs more than the last row.                          |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_LOGGER_MQH__
#define __ADAPTIVE_LOGGER_MQH__

#include "Types.mqh"

enum ENUM_LOG_STREAM
  {
   LOG_TRADES = 0,
   LOG_EQUITY,
   LOG_REGIME,
   LOG_STRATEGY,
   LOG_RISK,
   LOG_SWITCH
  };
#define LOG_STREAM_COUNT 6

class CLogger
  {
private:
   string            m_dir;
   bool              m_enabled;
   bool              m_echo_to_terminal;
   string            m_session_tag;
   string            m_headers[LOG_STREAM_COUNT];
   string            m_names[LOG_STREAM_COUNT];
   string            m_current_file[LOG_STREAM_COUNT];

   string            StreamName(const ENUM_LOG_STREAM s) const { return m_names[(int)s]; }

   string            FilePath(const ENUM_LOG_STREAM s)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return StringFormat("%s\\%s_%04d%02d%02d.csv",
                          m_dir, StreamName(s), dt.year, dt.mon, dt.day);
     }

   //--- opens (creating + writing the header on first touch) and appends
   bool              WriteRow(const ENUM_LOG_STREAM s, const string row)
     {
      if(!m_enabled)
         return false;

      string path    = FilePath(s);
      bool   is_new  = !FileIsExist(path);

      int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE)
        {
         PrintFormat("[Logger] cannot open %s (err %d)", path, GetLastError());
         return false;
        }
      FileSeek(h, 0, SEEK_END);
      if(is_new || FileTell(h) == 0)
         FileWriteString(h, m_headers[(int)s] + "\r\n");
      FileWriteString(h, row + "\r\n");
      FileClose(h);

      if(m_echo_to_terminal && (s == LOG_RISK || s == LOG_STRATEGY))
         PrintFormat("[%s] %s", StreamName(s), row);

      return true;
     }

   string            Stamp(void) const
     {
      return TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
     }

   //--- CSV-safe: strip separators and quotes out of free text
   static string     Clean(const string s)
     {
      string out = s;
      StringReplace(out, ",", ";");
      StringReplace(out, "\"", "'");
      StringReplace(out, "\n", " ");
      StringReplace(out, "\r", " ");
      return out;
     }

public:
                     CLogger(void) : m_dir("Adaptive\\logs"), m_enabled(true),
                                     m_echo_to_terminal(true), m_session_tag("")
     {
      m_names[LOG_TRADES]   = "trades";
      m_names[LOG_EQUITY]   = "equity";
      m_names[LOG_REGIME]   = "regime";
      m_names[LOG_STRATEGY] = "strategy";
      m_names[LOG_RISK]     = "risk";
      m_names[LOG_SWITCH]   = "switch";

      m_headers[LOG_TRADES] =
         "time,session,event,strategy,strategy_version,symbol,magic,ticket,side,lots,"
         "price,sl,tp,risk_money,risk_pct,r_multiple,mfe_r,mae_r,pnl,"
         "regime,h4_ctx,h1_ctx,m15_ctx,atr,adx,struct_state,market_session,"
         "news_state,spread_pts,slippage_pts,phase,strategy_score,strategy_state,"
         "exit_reason,why";
      m_headers[LOG_EQUITY] =
         "time,session,balance,equity,floating_pnl,day_pnl,day_pnl_pct,"
         "dd_from_initial_pct,dd_from_peak_pct,open_positions,open_risk_money,"
         "open_risk_pct,daily_locked,killed";
      m_headers[LOG_REGIME] =
         "time,session,symbol,tf,regime,prev_regime,atr,atr_pct,atr_percentile,"
         "adx,di_plus,di_minus,candle_flags,confidence,composite,composite_conf,aligned";
      m_headers[LOG_STRATEGY] =
         "time,session,strategy,symbol,event,enabled,suitability,base_score,"
         "perf_adj,regime,virtual_equity,virtual_dd_pct,trades,win_rate,expectancy_r,detail";
      m_headers[LOG_RISK] =
         "time,session,event,strategy,symbol,reason,requested_lots,approved_lots,"
         "risk_money,risk_pct,equity,day_pnl_pct,dd_pct,detail";
      m_headers[LOG_SWITCH] =
         "time,session,previous_strategy,new_strategy,failure_reason,regime,"
         "prev_score,new_score,portfolio_mode,risk_state,account_dd_pct,"
         "daily_dd_pct,news_state,spread_pts,volatility_state,rationale";
     }

   void              Configure(const string dir, const bool enabled, const bool echo)
     {
      m_dir              = dir;
      m_enabled          = enabled;
      m_echo_to_terminal = echo;
     }

   bool              Init(const string session_tag)
     {
      m_session_tag = session_tag;
      //--- MQL5 creates intermediate folders on first FileOpen under Files\
      if(!FolderCreate(m_dir, 0))
        {
         int err = GetLastError();
         if(err != 0 && err != 5019 /* already exists */)
            PrintFormat("[Logger] FolderCreate('%s') err %d", m_dir, err);
         ResetLastError();
        }
      Event(LOG_RISK, "SESSION_START", "", "", BLOCK_NONE, 0, 0, 0, 0, 0, 0, 0,
            StringFormat("version=%s", ADAPTIVE_VERSION));
      return true;
     }

   //+---------------------------------------------------------------+
   //| Full trade record (sect 26). Every column exists so a losing    |
   //| run can be diagnosed afterwards without guessing what the EA    |
   //| was looking at - including the rejected trades, which are       |
   //| logged to the risk stream with their reason.                    |
   //+---------------------------------------------------------------+
   void              TradeFull(const string event, const string strategy, const string version,
                               const string symbol, const long magic, const ulong ticket,
                               const string side, const double lots, const double price,
                               const double sl, const double tp, const double risk_money,
                               const double risk_pct, const double r_multiple,
                               const double mfe_r, const double mae_r, const double pnl,
                               const string regime, const string h4, const string h1,
                               const string m15, const double atr_v, const double adx_v,
                               const string structure, const string mkt_session,
                               const string news_state, const double spread_pts,
                               const double slippage_pts, const int phase,
                               const double score, const string state,
                               const string exit_reason, const string why)
     {
      WriteRow(LOG_TRADES, StringFormat(
         "%s,%s,%s,%s,%s,%s,%I64d,%I64u,%s,%.2f,%.5f,%.5f,%.5f,%.2f,%.4f,%.3f,%.3f,%.3f,"
         "%.2f,%s,%s,%s,%s,%.5f,%.2f,%s,%s,%s,%.1f,%.1f,%d,%.4f,%s,%s,%s",
         Stamp(), m_session_tag, Clean(event), Clean(strategy), Clean(version), symbol,
         magic, ticket, side, lots, price, sl, tp, risk_money, risk_pct, r_multiple,
         mfe_r, mae_r, pnl, Clean(regime), Clean(h4), Clean(h1), Clean(m15),
         atr_v, adx_v, Clean(structure), Clean(mkt_session), Clean(news_state),
         spread_pts, slippage_pts, phase, score, Clean(state),
         Clean(exit_reason), Clean(why)));
     }

   //+---------------------------------------------------------------+
   //| Strategy switch record (sect 27). Written whenever the active   |
   //| set changes, so the research side can reconstruct why.          |
   //+---------------------------------------------------------------+
   void              Switch(const string prev, const string next, const string failure,
                            const string regime, const double prev_score,
                            const double next_score, const string portfolio_mode,
                            const string risk_state, const double account_dd,
                            const double daily_dd, const string news_state,
                            const double spread_pts, const string vol_state,
                            const string rationale)
     {
      WriteRow(LOG_SWITCH, StringFormat(
         "%s,%s,%s,%s,%s,%s,%.4f,%.4f,%s,%s,%.4f,%.4f,%s,%.1f,%s,%s",
         Stamp(), m_session_tag, Clean(prev), Clean(next), Clean(failure), Clean(regime),
         prev_score, next_score, Clean(portfolio_mode), Clean(risk_state),
         account_dd, daily_dd, Clean(news_state), spread_pts, Clean(vol_state),
         Clean(rationale)));
     }

   //--- trade stream (compact form, kept for existing call sites) -------
   void              Trade(const string event, const string strategy, const string symbol,
                           const long magic, const ulong ticket, const string side,
                           const double lots, const double price, const double sl, const double tp,
                           const double risk_money, const double risk_pct, const double r_multiple,
                           const double pnl, const string regime, const int phase,
                           const string news_state, const string reason)
     {
      TradeFull(event, strategy, "", symbol, magic, ticket, side, lots, price, sl, tp,
                risk_money, risk_pct, r_multiple, 0, 0, pnl, regime, "", "", "",
                0, 0, "", "", news_state, 0, 0, phase, 0, "", "", reason);
     }

   //--- equity heartbeat ------------------------------------------------
   void              Equity(const double balance, const double equity, const double floating,
                            const double day_pnl, const double day_pnl_pct,
                            const double dd_initial_pct, const double dd_peak_pct,
                            const int open_positions, const double open_risk_money,
                            const double open_risk_pct, const bool daily_locked, const bool killed)
     {
      WriteRow(LOG_EQUITY, StringFormat(
                  "%s,%s,%.2f,%.2f,%.2f,%.2f,%.4f,%.4f,%.4f,%d,%.2f,%.4f,%d,%d",
                  Stamp(), m_session_tag, balance, equity, floating, day_pnl, day_pnl_pct,
                  dd_initial_pct, dd_peak_pct, open_positions, open_risk_money, open_risk_pct,
                  (daily_locked ? 1 : 0), (killed ? 1 : 0)));
     }

   //--- regime transitions ----------------------------------------------
   void              Regime(const string symbol, const ENUM_TF_SLOT slot, const SRegimeTF &tf,
                            const ENUM_REGIME prev, const SRegimeSnapshot &snap)
     {
      WriteRow(LOG_REGIME, StringFormat(
                  "%s,%s,%s,%s,%s,%s,%.5f,%.5f,%.4f,%.2f,%.2f,%.2f,%d,%.3f,%s,%.3f,%d",
                  Stamp(), m_session_tag, symbol, TfSlotToString(slot),
                  RegimeToString(tf.regime), RegimeToString(prev),
                  tf.atr, tf.atr_pct, tf.atr_percentile, tf.adx, tf.di_plus, tf.di_minus,
                  tf.candle_flags, tf.confidence,
                  RegimeToString(snap.composite), snap.composite_conf, (snap.aligned ? 1 : 0)));
     }

   //--- strategy lifecycle ----------------------------------------------
   void              Strategy(const string strategy, const string symbol, const string event,
                              const bool enabled, const double suitability, const double base_score,
                              const double perf_adj, const string regime,
                              const double virt_equity, const double virt_dd_pct,
                              const int trades, const double win_rate, const double expectancy_r,
                              const string detail)
     {
      WriteRow(LOG_STRATEGY, StringFormat(
                  "%s,%s,%s,%s,%s,%d,%.4f,%.4f,%.4f,%s,%.2f,%.4f,%d,%.4f,%.4f,%s",
                  Stamp(), m_session_tag, Clean(strategy), symbol, Clean(event),
                  (enabled ? 1 : 0), suitability, base_score, perf_adj, Clean(regime),
                  virt_equity, virt_dd_pct, trades, win_rate, expectancy_r, Clean(detail)));
     }

   //--- risk events ------------------------------------------------------
   void              Event(const ENUM_LOG_STREAM stream, const string event, const string strategy,
                           const string symbol, const ENUM_BLOCK_REASON reason,
                           const double requested_lots, const double approved_lots,
                           const double risk_money, const double risk_pct,
                           const double equity, const double day_pnl_pct, const double dd_pct,
                           const string detail)
     {
      WriteRow(stream, StringFormat(
                  "%s,%s,%s,%s,%s,%s,%.2f,%.2f,%.2f,%.4f,%.2f,%.4f,%.4f,%s",
                  Stamp(), m_session_tag, Clean(event), Clean(strategy), symbol,
                  BlockReasonToString(reason), requested_lots, approved_lots,
                  risk_money, risk_pct, equity, day_pnl_pct, dd_pct, Clean(detail)));
     }

   void              Risk(const string event, const string strategy, const string symbol,
                          const ENUM_BLOCK_REASON reason, const double requested_lots,
                          const double approved_lots, const double risk_money, const double risk_pct,
                          const double equity, const double day_pnl_pct, const double dd_pct,
                          const string detail)
     {
      Event(LOG_RISK, event, strategy, symbol, reason, requested_lots, approved_lots,
            risk_money, risk_pct, equity, day_pnl_pct, dd_pct, detail);
     }

   void              Info(const string msg)
     {
      if(m_echo_to_terminal)
         PrintFormat("[Adaptive] %s", msg);
     }

   void              Warn(const string msg)
     {
      PrintFormat("[Adaptive][WARN] %s", msg);
      Risk("WARN", "", "", BLOCK_NONE, 0, 0, 0, 0, 0, 0, 0, msg);
     }
  };

#endif // __ADAPTIVE_LOGGER_MQH__

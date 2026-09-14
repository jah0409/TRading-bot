//+------------------------------------------------------------------+
//| OrderExecutor.mqh - the only place that touches the trade server  |
//|                                                                    |
//| Wraps CTrade with: retry on transient errors, price/stop           |
//| normalisation, filling-mode detection, and a comment convention    |
//| that carries the owning strategy id ("ADPT|trend_ema") so the risk |
//| manager can attribute every open position back to its strategy.    |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_ORDEREXECUTOR_MQH__
#define __ADAPTIVE_ORDEREXECUTOR_MQH__

#include <Trade/Trade.mqh>
#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"

class COrderExecutor
  {
private:
   CTrade            m_trade;
   CConfig          *m_cfg;
   CLogger          *m_log;

   //--- transient errors worth retrying; everything else is fatal
   bool              IsRetryable(const uint retcode) const
     {
      switch(retcode)
        {
         case TRADE_RETCODE_REQUOTE:
         case TRADE_RETCODE_PRICE_CHANGED:
         case TRADE_RETCODE_PRICE_OFF:
         case TRADE_RETCODE_TIMEOUT:
         case TRADE_RETCODE_CONNECTION:
         case TRADE_RETCODE_TOO_MANY_REQUESTS:
            return true;
        }
      return false;
     }

   double            NormalizePrice(const string symbol, const double price) const
     {
      int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double tick   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick > 0.0)
         return NormalizeDouble(MathRound(price / tick) * tick, digits);
      return NormalizeDouble(price, digits);
     }

   //--- push a stop out to the broker's minimum distance if needed
   double            SafeStop(const string symbol, const ENUM_ORDER_TYPE dir,
                              const double ref_price, const double stop) const
     {
      if(stop <= 0.0)
         return 0.0;
      long   level  = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double min_d  = level * point;
      double out    = stop;

      if(dir == ORDER_TYPE_BUY)
        {
         if(ref_price - out < min_d)
            out = ref_price - min_d;
        }
      else
        {
         if(out - ref_price < min_d)
            out = ref_price + min_d;
        }
      return NormalizePrice(symbol, out);
     }

   string            BuildComment(const string strategy_id) const
     {
      //--- RiskManager::RecomputeExposure() splits on '|' to recover the id
      return StringFormat("%s|%s", m_cfg.Exec().order_comment_prefix, strategy_id);
     }

public:
                     COrderExecutor(void) : m_cfg(NULL), m_log(NULL) {}

   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;
      m_trade.SetDeviationInPoints(m_cfg.Exec().slippage_points);
      m_trade.SetAsyncMode(false);
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      return true;
     }

   void              PrepareFor(const string symbol, const long magic)
     {
      m_trade.SetExpertMagicNumber(magic);

      //--- pick a filling mode the symbol actually supports
      long modes = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      if((modes & SYMBOL_FILLING_FOK) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_FOK);
      else if((modes & SYMBOL_FILLING_IOC) != 0)
         m_trade.SetTypeFilling(ORDER_FILLING_IOC);
      else
         m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
     }

   //+---------------------------------------------------------------+
   //| Market entry. Returns the ticket, or 0 on failure.             |
   //+---------------------------------------------------------------+
   ulong             OpenMarket(const STradeIntent &intent, const string reason)
     {
      string sym = intent.symbol;
      PrepareFor(sym, intent.magic);

      for(int attempt = 0; attempt <= m_cfg.Exec().max_retries; attempt++)
        {
         MqlTick tick;
         if(!SymbolInfoTick(sym, tick))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("no tick for %s", sym));
            return 0;
           }

         double price = (intent.direction == ORDER_TYPE_BUY ? tick.ask : tick.bid);
         double sl    = SafeStop(sym, intent.direction, price, intent.stop_loss);
         double tp    = (intent.take_profit > 0.0
                         ? NormalizePrice(sym, intent.take_profit) : 0.0);

         bool ok = (intent.direction == ORDER_TYPE_BUY)
                   ? m_trade.Buy(intent.lots, sym, price, sl, tp, BuildComment(intent.strategy_id))
                   : m_trade.Sell(intent.lots, sym, price, sl, tp, BuildComment(intent.strategy_id));

         uint  retcode = m_trade.ResultRetcode();
         ulong ticket  = m_trade.ResultOrder();

         if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
           {
            if(m_log != NULL)
               m_log.Trade("OPEN", intent.strategy_id, sym, intent.magic, ticket,
                           (intent.direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                           intent.lots, m_trade.ResultPrice(), sl, tp,
                           intent.risk_money, intent.risk_pct, 0.0, 0.0,
                           "", 0, "", reason);
            return ticket;
           }

         if(!IsRetryable(retcode))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("open %s %s failed retcode=%u (%s)",
                                       sym, intent.strategy_id, retcode,
                                       m_trade.ResultRetcodeDescription()));
            return 0;
           }

         Sleep(m_cfg.Exec().retry_delay_ms * (attempt + 1));
        }

      if(m_log != NULL)
         m_log.Warn(StringFormat("open %s %s exhausted retries", intent.symbol, intent.strategy_id));
      return 0;
     }

   //+---------------------------------------------------------------+
   //| Close, whole or partial.                                       |
   //+---------------------------------------------------------------+
   bool              ClosePosition(const ulong ticket, const double fraction, const string reason)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      string sym    = PositionGetString(POSITION_SYMBOL);
      long   magic  = PositionGetInteger(POSITION_MAGIC);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double pnl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      PrepareFor(sym, magic);

      double close_vol = volume;
      if(fraction > 0.0 && fraction < 1.0)
        {
         double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
         if(step <= 0.0)
            step = 0.01;
         close_vol = MathFloor(volume * fraction / step) * step;
         double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
         if(close_vol < min_lot)
            close_vol = volume;             // too small to split: close it all
         if(volume - close_vol < min_lot)
            close_vol = volume;             // remainder would be untradeable
        }

      for(int attempt = 0; attempt <= m_cfg.Exec().max_retries; attempt++)
        {
         bool ok = (close_vol >= volume)
                   ? m_trade.PositionClose(ticket)
                   : m_trade.PositionClosePartial(ticket, close_vol);

         uint retcode = m_trade.ResultRetcode();
         if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
           {
            if(m_log != NULL)
               m_log.Trade("CLOSE", "", sym, magic, ticket, "", close_vol,
                           m_trade.ResultPrice(), 0, 0, 0, 0, 0, pnl, "", 0, "", reason);
            return true;
           }
         if(!IsRetryable(retcode))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("close #%I64u failed retcode=%u (%s)",
                                       ticket, retcode, m_trade.ResultRetcodeDescription()));
            return false;
           }
         Sleep(m_cfg.Exec().retry_delay_ms * (attempt + 1));
        }
      return false;
     }

   //+---------------------------------------------------------------+
   //| Move the stop (trailing / break-even). No-ops when the new     |
   //| stop is not an improvement, so this is safe to call per tick.  |
   //+---------------------------------------------------------------+
   bool              ModifyStop(const ulong ticket, const double new_sl, const string reason)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      string sym = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double cur_sl = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);

      MqlTick tick;
      if(!SymbolInfoTick(sym, tick))
         return false;
      double ref = (ptype == POSITION_TYPE_BUY ? tick.bid : tick.ask);

      double target = SafeStop(sym,
                               (ptype == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL),
                               ref, new_sl);
      if(target <= 0.0)
         return false;

      //--- only ever tighten, never loosen
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      if(ptype == POSITION_TYPE_BUY && cur_sl > 0.0 && target <= cur_sl + point)
         return false;
      if(ptype == POSITION_TYPE_SELL && cur_sl > 0.0 && target >= cur_sl - point)
         return false;

      PrepareFor(sym, PositionGetInteger(POSITION_MAGIC));
      bool ok = m_trade.PositionModify(ticket, target, tp);

      if(ok && m_log != NULL)
         m_log.Trade("TRAIL", "", sym, PositionGetInteger(POSITION_MAGIC), ticket, "",
                     0, ref, target, tp, 0, 0, 0, 0, "", 0, "", reason);
      return ok;
     }

   //+---------------------------------------------------------------+
   //| Flatten everything we own. Used by the kill switch and by the  |
   //| news blackout.                                                 |
   //+---------------------------------------------------------------+
   int               CloseAll(const string reason)
     {
      long base = m_cfg.Exec().magic_base * 100;
      int closed = 0;

      //--- iterate backwards: the list shrinks as we close
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic < base || magic >= base + 1000)
            continue;
         if(ClosePosition(ticket, 1.0, reason))
            closed++;
        }

      if(closed > 0 && m_log != NULL)
         m_log.Risk("CLOSE_ALL", "", "", BLOCK_NONE, 0, 0, 0, 0,
                    AccountInfoDouble(ACCOUNT_EQUITY), 0, 0,
                    StringFormat("closed %d positions: %s", closed, reason));
      return closed;
     }
  };

#endif // __ADAPTIVE_ORDEREXECUTOR_MQH__

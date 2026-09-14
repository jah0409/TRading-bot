//+------------------------------------------------------------------+
//|                                                    AdaptiveEA.mq5 |
//|         Regime-adaptive multi-strategy EA for XAUUSD and US100    |
//|                                                                    |
//|  Attach to ONE chart only. The EA drives every configured symbol   |
//|  from that single instance; a second instance would double the     |
//|  risk budget without either one knowing about the other.           |
//|                                                                    |
//|  Setup:                                                            |
//|    1. Copy MQL5/Include/Adaptive -> <terminal>/MQL5/Include/       |
//|    2. Copy MQL5/Files/Adaptive   -> <terminal>/MQL5/Files/         |
//|    3. Compile this file in MetaEditor                              |
//|    4. Edit MQL5/Files/Adaptive/config.json for your broker's       |
//|       symbol names (XAUUSD / US100 vary: XAUUSD.r, NAS100, ...)    |
//|    5. Enable AutoTrading; allow WebRequest only if using the API   |
//+------------------------------------------------------------------+
#property copyright "Adaptive EA"
#property version   "0.10"
#property description "Regime-adaptive multi-strategy EA with prop-firm risk control"
#property strict

#include <Adaptive/Engine/Orchestrator.mqh>

//--- inputs are deliberately few: config.json is the source of truth
input string InpConfigPath      = "Adaptive\\config.json"; // Config file (under MQL5/Files)
input bool   InpVerboseLog      = true;                    // Echo events to the Experts tab
input bool   InpShowPanel       = true;                    // Draw the status comment
input bool   InpAllowLiveTrading= false;                   // Master arm switch - OFF by default

COrchestrator g_ea;
bool          g_armed = false;

//+------------------------------------------------------------------+
int OnInit(void)
  {
   Print("=== AdaptiveEA ", ADAPTIVE_VERSION, " starting ===");

   if(!g_ea.Startup(InpConfigPath, InpVerboseLog))
     {
      Print("AdaptiveEA: startup FAILED - see the Experts tab and "
            "MQL5/Files/Adaptive/logs/risk_*.csv");
      Comment("AdaptiveEA: STARTUP FAILED - not trading");
      return INIT_FAILED;
     }

   //--- the arm switch is separate from a successful startup on purpose:
   //--- you should be able to load the EA, watch it classify regimes and
   //--- log decisions for a few sessions, and only then let it trade.
   g_armed = InpAllowLiveTrading;
   if(!g_armed)
      Print("AdaptiveEA: OBSERVE MODE - regimes and signals are logged, "
            "no orders will be sent. Set InpAllowLiveTrading=true to arm.");

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("AdaptiveEA: WARNING - AutoTrading is disabled in the terminal");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("AdaptiveEA: WARNING - trading is not allowed for this EA");

   int period = g_ea.Config().Exec().main_loop_seconds;
   if(period < 1)
      period = 5;
   EventSetTimer(period);

   Print("AdaptiveEA: main loop every ", period, "s");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

   if(g_ea.IsReady())
     {
      g_ea.ReportPruneCandidates();
      g_ea.Log().Info(StringFormat("shutting down, reason=%d | %s", reason, g_ea.StatusLine()));
     }

   g_ea.Shutdown();
   Comment("");
   Print("=== AdaptiveEA stopped (reason ", reason, ") ===");
  }

//+------------------------------------------------------------------+
//| The 5s heartbeat: regime -> allocation -> risk -> strategies.     |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   if(!g_ea.IsReady())
      return;

   if(g_armed)
      g_ea.OnTimerCycle();
   else
     {
      //--- observe mode: keep the analysis and the logs alive, but never
      //--- let a strategy reach the executor
      g_ea.Risk().Update();
     }

   if(InpShowPanel)
      Comment(StringFormat("AdaptiveEA %s  [%s]\n%s",
                           ADAPTIVE_VERSION,
                           (g_armed ? "ARMED" : "OBSERVE"),
                           g_ea.StatusLine()));
  }

//+------------------------------------------------------------------+
//| Ticks only trail stops. All decisions live in OnTimer.            |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_ea.IsReady() || !g_armed)
      return;
   g_ea.OnTickCycle();
  }

//+------------------------------------------------------------------+
//| Fills and closes - this is where trades get attributed back to    |
//| the strategy and regime that produced them.                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(!g_ea.IsReady())
      return;
   g_ea.OnTradeTransactionEvent(trans, request, result);
  }

//+------------------------------------------------------------------+
//| Chart shortcuts for the operator:                                 |
//|   'S' - print the status line                                     |
//|   'P' - print prune candidates                                    |
//|   'K' - clear the kill switch (deliberate, manual, logged)        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_KEYDOWN || !g_ea.IsReady())
      return;

   switch((int)lparam)
     {
      case 'S':
      case 's':
         Print(g_ea.StatusLine());
         break;
      case 'P':
      case 'p':
         g_ea.ReportPruneCandidates();
         Print("prune candidates written to strategy log");
         break;
      case 'K':
      case 'k':
         if(g_ea.Risk().IsKilled())
           {
            g_ea.Risk().ResetKillSwitch("operator_keypress");
            Print("KILL SWITCH CLEARED - trading may resume");
           }
         else
            Print("kill switch is not set");
         break;
     }
  }
//+------------------------------------------------------------------+

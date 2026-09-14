//+------------------------------------------------------------------+
//| NewsFilter.mqh - economic calendar blackout + volatility posture  |
//|                                                                    |
//| Tier A (60 min each side): FOMC, NFP, CPI, GDP, ECB/BoE/BoJ        |
//| Tier B (30 min each side): retail sales, PMI, consumer sentiment   |
//| Caution band (wider):      shrink size, widen stops                |
//|                                                                    |
//| Sources, in priority order:                                        |
//|   1. MQL5 native calendar  - live terminal only, NOT in the tester  |
//|   2. CSV file              - works in the tester, manual or synced  |
//|   3. WebRequest to an API  - needs the URL whitelisted in           |
//|                              Tools > Options > Expert Advisors      |
//|                                                                    |
//| If every source is stale the filter FAILS CLOSED: no calendar means |
//| no trading. On a prop account that is the only safe default.        |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_NEWSFILTER_MQH__
#define __ADAPTIVE_NEWSFILTER_MQH__

#include "../Core/Types.mqh"
#include "../Core/Config.mqh"
#include "../Core/Logger.mqh"

enum ENUM_NEWS_TIER
  {
   NEWS_TIER_NONE = 0,
   NEWS_TIER_B    = 1,   // 30 min window
   NEWS_TIER_A    = 2    // 60 min window
  };

struct SNewsEvent
  {
   datetime          when;
   string            name;
   string            currency;
   int               importance;   // raw source importance
   ENUM_NEWS_TIER    tier;
  };

//--- what the filter tells a strategy about right now ---------------
struct SNewsState
  {
   bool              blackout;      // flat + no entries
   bool              caution;       // trade smaller, wider stops
   double            size_mult;
   double            stop_mult;
   string            label;         // "CPI (USD) in 00:42"
   datetime          next_event;
  };

class CNewsFilter
  {
private:
   CConfig          *m_cfg;
   CLogger          *m_log;

   SNewsEvent        m_events[];
   datetime          m_last_refresh;
   datetime          m_feed_timestamp;   // when the data itself was produced
   bool              m_feed_ok;
   string            m_feed_source;

   //--- keyword tables -------------------------------------------------
   string            m_tier_a_keys[];
   string            m_tier_b_keys[];

   void              BuildKeywordTables(void)
     {
      string a[] = {"FOMC", "FEDERAL FUNDS", "INTEREST RATE DECISION", "RATE DECISION",
                    "NON-FARM", "NONFARM", "NFP", "EMPLOYMENT CHANGE",
                    "CPI", "CONSUMER PRICE", "INFLATION RATE",
                    "GDP", "GROSS DOMESTIC",
                    "ECB", "BOE", "BOJ", "BANK OF ENGLAND", "BANK OF JAPAN",
                    "MONETARY POLICY", "PRESS CONFERENCE", "RATE STATEMENT"};
      string b[] = {"RETAIL SALES", "PMI", "PURCHASING MANAGERS",
                    "CONSUMER SENTIMENT", "MICHIGAN", "CONSUMER CONFIDENCE",
                    "ISM", "DURABLE GOODS", "PPI", "PRODUCER PRICE"};
      ArrayResize(m_tier_a_keys, ArraySize(a));
      ArrayCopy(m_tier_a_keys, a);
      ArrayResize(m_tier_b_keys, ArraySize(b));
      ArrayCopy(m_tier_b_keys, b);
     }

   ENUM_NEWS_TIER    ClassifyByName(const string raw_name) const
     {
      string n = raw_name;
      StringToUpper(n);
      for(int i = 0; i < ArraySize(m_tier_a_keys); i++)
         if(StringFind(n, m_tier_a_keys[i]) >= 0)
            return NEWS_TIER_A;
      for(int i = 0; i < ArraySize(m_tier_b_keys); i++)
         if(StringFind(n, m_tier_b_keys[i]) >= 0)
            return NEWS_TIER_B;
      return NEWS_TIER_NONE;
     }

   //--- which currencies matter for this symbol -----------------------
   string            CurrenciesFor(const string symbol) const
     {
      if(StringFind(symbol, "XAU") >= 0)
         return m_cfg.News().currencies_xau;
      return m_cfg.News().currencies_idx;
     }

   bool              CurrencyRelevant(const string symbol, const string ccy) const
     {
      if(ccy == "")
         return true;   // unknown currency: assume relevant, fail safe
      string list = CurrenciesFor(symbol);
      return (StringFind("," + list + ",", "," + ccy + ",") >= 0);
     }

   void              AddEvent(const datetime when, const string name,
                              const string ccy, const int importance)
     {
      ENUM_NEWS_TIER tier = ClassifyByName(name);
      if(tier == NEWS_TIER_NONE)
         return;   // we only care about the named categories
      int n = ArraySize(m_events);
      ArrayResize(m_events, n + 1);
      m_events[n].when       = when;
      m_events[n].name       = name;
      m_events[n].currency   = ccy;
      m_events[n].importance = importance;
      m_events[n].tier       = tier;
     }

   //+---------------------------------------------------------------+
   //| Source 1: MQL5 native calendar.                                |
   //| Returns false in the Strategy Tester, where the API is absent. |
   //+---------------------------------------------------------------+
   bool              LoadFromMql5Calendar(const datetime from, const datetime to)
     {
      if(MQLInfoInteger(MQL_TESTER))
         return false;

      MqlCalendarValue values[];
      int n = CalendarValueHistory(values, from, to, NULL, NULL);
      if(n <= 0)
        {
         ResetLastError();
         return false;
        }

      int added = 0;
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance == CALENDAR_IMPORTANCE_NONE)
            continue;

         MqlCalendarCountry country;
         string ccy = "";
         if(CalendarCountryById(ev.country_id, country))
            ccy = country.currency;

         AddEvent(values[i].time, ev.name, ccy, (int)ev.importance);
         added++;
        }

      m_feed_source    = "MQL5_CALENDAR";
      m_feed_timestamp = TimeCurrent();
      return (added > 0);
     }

   //+---------------------------------------------------------------+
   //| Source 2: CSV fallback. Works in the tester.                   |
   //| Format (header row required):                                  |
   //|   datetime,currency,importance,name                            |
   //|   2026.09.17 18:00,USD,3,FOMC Interest Rate Decision           |
   //+---------------------------------------------------------------+
   bool              LoadFromCsv(const string path)
     {
      int h = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
        {
         ResetLastError();
         return false;
        }

      int added = 0;
      bool first = true;
      while(!FileIsEnding(h))
        {
         string line = FileReadString(h);
         if(line == "")
            continue;
         if(first)
           {
            first = false;
            string lower = line;
            StringToLower(lower);
            if(StringFind(lower, "datetime") >= 0)   // skip the header
               continue;
           }
         string parts[];
         int c = StringSplit(line, ',', parts);
         if(c < 4)
            continue;
         datetime when = StringToTime(parts[0]);
         if(when <= 0)
            continue;
         AddEvent(when, parts[3], parts[1], (int)StringToInteger(parts[2]));
         added++;
        }
      FileClose(h);

      if(added > 0)
        {
         m_feed_source    = "CSV";
         //--- the file's own mtime is the honest feed age
         m_feed_timestamp = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, false);
         if(m_feed_timestamp <= 0)
            m_feed_timestamp = TimeCurrent();
        }
      return (added > 0);
     }

   //+---------------------------------------------------------------+
   //| Source 3: HTTP API.                                            |
   //| === STUB === WebRequest needs the host whitelisted in the       |
   //| terminal (Tools > Options > Expert Advisors > Allow WebRequest).|
   //| Parse the provider's payload here and call AddEvent() per row.  |
   //| ForexFactory publishes a weekly JSON at a stable URL; DailyFX   |
   //| and others need an API key. Recommended flow: fetch, write the  |
   //| normalised rows to the CSV above, then reload from CSV, so the  |
   //| tester and live both read one format.                           |
   //+---------------------------------------------------------------+
   bool              LoadFromWebApi(const string url)
     {
      if(url == "" || MQLInfoInteger(MQL_TESTER))
         return false;

      char   post[];
      char   result[];
      string headers = "";
      string result_headers = "";
      int    timeout = 5000;

      ResetLastError();
      int status = WebRequest("GET", url, headers, timeout, post, result, result_headers);
      if(status != 200)
        {
         if(m_log != NULL)
            m_log.Warn(StringFormat("news WebRequest '%s' status=%d err=%d "
                                    "(whitelist the host in Tools>Options>Expert Advisors)",
                                    url, status, GetLastError()));
         return false;
        }

      string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      // === STUB === provider-specific parsing goes here.
      // Expected: iterate rows -> AddEvent(when, name, currency, importance).
      // Until implemented we deliberately report failure so the filter
      // falls through to CSV rather than silently trading blind.
      if(m_log != NULL)
         m_log.Info(StringFormat("news API returned %d bytes; parser not implemented",
                                 StringLen(body)));
      return false;
     }

   //--- newest-first ordering makes the "next event" scan cheap ------
   void              SortEvents(void)
     {
      int n = ArraySize(m_events);
      for(int i = 1; i < n; i++)
        {
         SNewsEvent key = m_events[i];
         int j = i - 1;
         while(j >= 0 && m_events[j].when > key.when)
           {
            m_events[j + 1] = m_events[j];
            j--;
           }
         m_events[j + 1] = key;
        }
     }

public:
                     CNewsFilter(void) : m_cfg(NULL), m_log(NULL), m_last_refresh(0),
                                         m_feed_timestamp(0), m_feed_ok(false),
                                         m_feed_source("none") {}

   bool              Init(CConfig *cfg, CLogger *log)
     {
      m_cfg = cfg;
      m_log = log;
      BuildKeywordTables();
      Refresh(true);
      return true;
     }

   bool              FeedOk(void)        const { return m_feed_ok; }
   string            FeedSource(void)    const { return m_feed_source; }
   int               EventCount(void)    const { return ArraySize(m_events); }

   //+---------------------------------------------------------------+
   //| Reload the calendar if it is due (or forced).                  |
   //+---------------------------------------------------------------+
   void              Refresh(const bool force = false)
     {
      if(!m_cfg.News().enabled)
        {
         m_feed_ok = true;      // filter disabled: do not block on staleness
         return;
        }

      datetime now = TimeCurrent();
      if(!force && m_last_refresh > 0 &&
         (now - m_last_refresh) < m_cfg.News().refresh_minutes * 60)
         return;

      m_last_refresh = now;
      ArrayResize(m_events, 0);

      datetime from = now - 7 * 86400;
      datetime to   = now + 14 * 86400;

      bool loaded = false;
      if(m_cfg.News().use_web_api)
         loaded = LoadFromWebApi(m_cfg.News().web_api_url);
      if(!loaded && m_cfg.News().use_mql5_calendar)
         loaded = LoadFromMql5Calendar(from, to);
      if(!loaded && m_cfg.News().use_csv_fallback)
         loaded = LoadFromCsv(m_cfg.News().csv_path);

      if(loaded)
        {
         SortEvents();
         m_feed_ok = true;
        }
      else
        {
         m_feed_ok        = false;
         m_feed_source    = "none";
         m_feed_timestamp = 0;
        }

      //--- stale data is as dangerous as no data
      if(m_feed_ok && m_feed_timestamp > 0)
        {
         double age_min = (double)(now - m_feed_timestamp) / 60.0;
         if(age_min > m_cfg.News().stale_after_minutes)
           {
            m_feed_ok = false;
            if(m_log != NULL)
               m_log.Warn(StringFormat("calendar feed stale: %.0f min old (limit %d)",
                                       age_min, m_cfg.News().stale_after_minutes));
           }
        }

      if(m_log != NULL)
         m_log.Info(StringFormat("news refresh: source=%s events=%d ok=%s",
                                 m_feed_source, ArraySize(m_events),
                                 (m_feed_ok ? "yes" : "NO")));
     }

   //+---------------------------------------------------------------+
   //| The question every strategy asks: can I trade this symbol now? |
   //+---------------------------------------------------------------+
   SNewsState        Evaluate(const string symbol)
     {
      SNewsState st;
      st.blackout   = false;
      st.caution    = false;
      st.size_mult  = 1.0;
      st.stop_mult  = 1.0;
      st.label      = "";
      st.next_event = 0;

      if(!m_cfg.News().enabled)
         return st;

      //--- fail closed: no usable calendar means no trading -----------
      if(!m_feed_ok)
        {
         if(m_cfg.News().fail_closed_if_stale)
           {
            st.blackout = true;
            st.label    = "NO_CALENDAR_FEED";
           }
         return st;
        }

      datetime    now = TimeCurrent();
      SNewsConfig nc  = m_cfg.News();   // hoisted: this loop runs every 5s

      for(int i = 0; i < ArraySize(m_events); i++)
        {
         if(!CurrencyRelevant(symbol, m_events[i].currency))
            continue;

         //--- minutes until (negative == already happened)
         double mins = (double)(m_events[i].when - now) / 60.0;

         int before, after;
         if(m_events[i].tier == NEWS_TIER_A)
           {
            before = nc.tier_a_minutes_before;
            after  = nc.tier_a_minutes_after;
           }
         else
           {
            before = nc.tier_b_minutes_before;
            after  = nc.tier_b_minutes_after;
           }

         //--- hard blackout window
         if(mins <= before && mins >= -after)
           {
            st.blackout   = true;
            st.next_event = m_events[i].when;
            st.label      = StringFormat("%s %s (%s) T%s %+.0fm",
                                         (mins >= 0 ? "PRE" : "POST"),
                                         m_events[i].name, m_events[i].currency,
                                         (m_events[i].tier == NEWS_TIER_A ? "A" : "B"), mins);
            return st;   // a blackout beats anything else
           }

         //--- wider caution band: still trade, but smaller and looser
         if(mins <= nc.caution_minutes_before &&
            mins >= -nc.caution_minutes_after)
           {
            if(!st.caution)
              {
               st.caution    = true;
               st.size_mult  = nc.caution_size_mult;
               st.stop_mult  = nc.caution_stop_mult;
               st.next_event = m_events[i].when;
               st.label      = StringFormat("CAUTION %s (%s) %+.0fm",
                                            m_events[i].name, m_events[i].currency, mins);
              }
           }
        }

      return st;
     }

   //--- true when any configured symbol is inside a hard window ------
   bool              AnyBlackout(void)
     {
      for(int i = 0; i < m_cfg.SymbolCount(); i++)
         if(Evaluate(m_cfg.SymbolAt(i)).blackout)
            return true;
      return false;
     }
  };

#endif // __ADAPTIVE_NEWSFILTER_MQH__

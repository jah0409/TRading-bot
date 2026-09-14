//+------------------------------------------------------------------+
//| Json.mqh - minimal recursive-descent JSON parser for MQL5         |
//|                                                                    |
//| MQL5 has no JSON support. This is a flat node-pool parser (no      |
//| pointers, no cleanup to get wrong) with dotted-path lookup:        |
//|                                                                    |
//|   CJson cfg;                                                       |
//|   cfg.LoadFile("Adaptive\\config.json");                           |
//|   double r = cfg.GetDouble("risk.per_trade_pct", 0.25);            |
//|   string s = cfg.GetString("strategies.0.id", "");                 |
//|                                                                    |
//| Paths: object keys separated by '.', array elements by index.      |
//+------------------------------------------------------------------+
#ifndef __ADAPTIVE_JSON_MQH__
#define __ADAPTIVE_JSON_MQH__

enum ENUM_JSON_TYPE
  {
   JSON_UNDEF = 0,
   JSON_NULL,
   JSON_BOOL,
   JSON_NUMBER,
   JSON_STRING,
   JSON_ARRAY,
   JSON_OBJECT
  };

struct SJsonNode
  {
   ENUM_JSON_TYPE    type;
   string            key;          // set when the node is an object member
   string            sval;
   double            nval;
   bool              bval;
   int               first_child;  // -1 when none
   int               next_sibling; // -1 when none
   int               child_count;
  };

class CJson
  {
private:
   SJsonNode         m_nodes[];
   int               m_count;
   string            m_src;
   int               m_pos;
   int               m_len;
   string            m_error;

   //--- node pool -----------------------------------------------------
   int               NewNode(const ENUM_JSON_TYPE t)
     {
      if(m_count >= ArraySize(m_nodes))
         ArrayResize(m_nodes, m_count + 64);
      m_nodes[m_count].type         = t;
      m_nodes[m_count].key          = "";
      m_nodes[m_count].sval         = "";
      m_nodes[m_count].nval         = 0.0;
      m_nodes[m_count].bval         = false;
      m_nodes[m_count].first_child  = -1;
      m_nodes[m_count].next_sibling = -1;
      m_nodes[m_count].child_count  = 0;
      m_count++;
      return m_count - 1;
     }

   void              AppendChild(const int parent, const int child)
     {
      if(m_nodes[parent].first_child < 0)
        {
         m_nodes[parent].first_child = child;
        }
      else
        {
         int cur = m_nodes[parent].first_child;
         while(m_nodes[cur].next_sibling >= 0)
            cur = m_nodes[cur].next_sibling;
         m_nodes[cur].next_sibling = child;
        }
      m_nodes[parent].child_count++;
     }

   //--- lexer ---------------------------------------------------------
   void              SkipWhitespace()
     {
      while(m_pos < m_len)
        {
         ushort c = StringGetCharacter(m_src, m_pos);
         //--- tolerate // line comments so the config can be annotated
         if(c == '/' && m_pos + 1 < m_len && StringGetCharacter(m_src, m_pos + 1) == '/')
           {
            while(m_pos < m_len && StringGetCharacter(m_src, m_pos) != '\n')
               m_pos++;
            continue;
           }
         if(c == ' ' || c == '\t' || c == '\r' || c == '\n')
           {
            m_pos++;
            continue;
           }
         break;
        }
     }

   bool              Fail(const string msg)
     {
      if(m_error == "")
         m_error = StringFormat("%s at offset %d", msg, m_pos);
      return false;
     }

   bool              ParseString(string &out)
     {
      if(StringGetCharacter(m_src, m_pos) != '"')
         return Fail("expected '\"'");
      m_pos++;
      string buf = "";
      while(m_pos < m_len)
        {
         ushort c = StringGetCharacter(m_src, m_pos);
         if(c == '"')
           {
            m_pos++;
            out = buf;
            return true;
           }
         if(c == '\\')
           {
            m_pos++;
            if(m_pos >= m_len)
               return Fail("truncated escape");
            ushort e = StringGetCharacter(m_src, m_pos);
            switch(e)
              {
               case 'n':  buf += "\n"; break;
               case 't':  buf += "\t"; break;
               case 'r':  buf += "\r"; break;
               case 'b':  buf += "\b"; break;
               case 'f':  buf += "\f"; break;
               case '/':  buf += "/";  break;
               case '\\': buf += "\\"; break;
               case '"':  buf += "\""; break;
               case 'u':
                 {
                  if(m_pos + 4 >= m_len)
                     return Fail("truncated \\u escape");
                  string hex = StringSubstr(m_src, m_pos + 1, 4);
                  int code = (int)StringToInteger("0x" + hex);
                  buf += ShortToString((ushort)code);
                  m_pos += 4;
                  break;
                 }
               default: return Fail("bad escape");
              }
            m_pos++;
            continue;
           }
         buf += ShortToString(c);
         m_pos++;
        }
      return Fail("unterminated string");
     }

   bool              ParseValue(int &out_index);

   bool              ParseObject(int &out_index)
     {
      int node = NewNode(JSON_OBJECT);
      m_pos++;  // consume '{'
      SkipWhitespace();
      if(m_pos < m_len && StringGetCharacter(m_src, m_pos) == '}')
        {
         m_pos++;
         out_index = node;
         return true;
        }
      while(m_pos < m_len)
        {
         SkipWhitespace();
         string key = "";
         if(!ParseString(key))
            return false;
         SkipWhitespace();
         if(m_pos >= m_len || StringGetCharacter(m_src, m_pos) != ':')
            return Fail("expected ':'");
         m_pos++;
         SkipWhitespace();
         int child = -1;
         if(!ParseValue(child))
            return false;
         m_nodes[child].key = key;
         AppendChild(node, child);
         SkipWhitespace();
         if(m_pos >= m_len)
            return Fail("unterminated object");
         ushort c = StringGetCharacter(m_src, m_pos);
         if(c == ',') { m_pos++; continue; }
         if(c == '}') { m_pos++; out_index = node; return true; }
         return Fail("expected ',' or '}'");
        }
      return Fail("unterminated object");
     }

   bool              ParseArray(int &out_index)
     {
      int node = NewNode(JSON_ARRAY);
      m_pos++;  // consume '['
      SkipWhitespace();
      if(m_pos < m_len && StringGetCharacter(m_src, m_pos) == ']')
        {
         m_pos++;
         out_index = node;
         return true;
        }
      while(m_pos < m_len)
        {
         SkipWhitespace();
         int child = -1;
         if(!ParseValue(child))
            return false;
         AppendChild(node, child);
         SkipWhitespace();
         if(m_pos >= m_len)
            return Fail("unterminated array");
         ushort c = StringGetCharacter(m_src, m_pos);
         if(c == ',') { m_pos++; continue; }
         if(c == ']') { m_pos++; out_index = node; return true; }
         return Fail("expected ',' or ']'");
        }
      return Fail("unterminated array");
     }

   //--- path resolution -----------------------------------------------
   int               Resolve(const string path) const
     {
      if(m_count == 0)
         return -1;
      if(path == "")
         return 0;
      string parts[];
      int n = StringSplit(path, '.', parts);
      int cur = 0;
      for(int i = 0; i < n; i++)
        {
         if(cur < 0 || cur >= m_count)
            return -1;
         string seg = parts[i];
         if(seg == "")
            continue;
         if(m_nodes[cur].type == JSON_ARRAY)
           {
            int idx = (int)StringToInteger(seg);
            int child = m_nodes[cur].first_child;
            int k = 0;
            while(child >= 0 && k < idx)
              {
               child = m_nodes[child].next_sibling;
               k++;
              }
            if(child < 0)
               return -1;
            cur = child;
            continue;
           }
         if(m_nodes[cur].type == JSON_OBJECT)
           {
            int child = m_nodes[cur].first_child;
            bool found = false;
            while(child >= 0)
              {
               if(m_nodes[child].key == seg)
                 {
                  cur = child;
                  found = true;
                  break;
                 }
               child = m_nodes[child].next_sibling;
              }
            if(!found)
               return -1;
            continue;
           }
         return -1;  // tried to descend into a scalar
        }
      return cur;
     }

public:
                     CJson(void) : m_count(0), m_pos(0), m_len(0), m_error("") {}

   string            LastError(void) const { return m_error; }

   bool              Parse(const string text)
     {
      m_src   = text;
      m_len   = StringLen(text);
      m_pos   = 0;
      m_count = 0;
      m_error = "";
      ArrayResize(m_nodes, 64);
      SkipWhitespace();
      int root = -1;
      if(!ParseValue(root))
         return false;
      if(root != 0)
        {
         m_error = "root node must be first in the pool";
         return false;
        }
      return true;
     }

   //--- reads from MQL5/Files/, e.g. "Adaptive\\config.json"
   bool              LoadFile(const string relative_path)
     {
      int h = FileOpen(relative_path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
        {
         m_error = StringFormat("cannot open '%s' (err %d)", relative_path, GetLastError());
         return false;
        }
      string text = "";
      while(!FileIsEnding(h))
         text += FileReadString(h) + "\n";
      FileClose(h);
      return Parse(text);
     }

   //--- queries --------------------------------------------------------
   bool              Exists(const string path) const { return Resolve(path) >= 0; }

   int               Count(const string path) const
     {
      int i = Resolve(path);
      return (i < 0 ? 0 : m_nodes[i].child_count);
     }

   ENUM_JSON_TYPE    TypeOf(const string path) const
     {
      int i = Resolve(path);
      return (i < 0 ? JSON_UNDEF : m_nodes[i].type);
     }

   //--- key of the Nth child of an object (for iterating maps)
   string            KeyAt(const string path, const int index) const
     {
      int i = Resolve(path);
      if(i < 0)
         return "";
      int child = m_nodes[i].first_child;
      int k = 0;
      while(child >= 0 && k < index)
        {
         child = m_nodes[child].next_sibling;
         k++;
        }
      return (child < 0 ? "" : m_nodes[child].key);
     }

   double            GetDouble(const string path, const double def = 0.0) const
     {
      int i = Resolve(path);
      if(i < 0)
         return def;
      if(m_nodes[i].type == JSON_NUMBER) return m_nodes[i].nval;
      if(m_nodes[i].type == JSON_BOOL)   return (m_nodes[i].bval ? 1.0 : 0.0);
      if(m_nodes[i].type == JSON_STRING) return StringToDouble(m_nodes[i].sval);
      return def;
     }

   int               GetInt(const string path, const int def = 0) const
     {
      int i = Resolve(path);
      if(i < 0)
         return def;
      return (int)MathRound(GetDouble(path, (double)def));
     }

   bool              GetBool(const string path, const bool def = false) const
     {
      int i = Resolve(path);
      if(i < 0)
         return def;
      if(m_nodes[i].type == JSON_BOOL)   return m_nodes[i].bval;
      if(m_nodes[i].type == JSON_NUMBER) return (m_nodes[i].nval != 0.0);
      if(m_nodes[i].type == JSON_STRING) return (m_nodes[i].sval == "true" || m_nodes[i].sval == "1");
      return def;
     }

   string            GetString(const string path, const string def = "") const
     {
      int i = Resolve(path);
      if(i < 0)
         return def;
      if(m_nodes[i].type == JSON_STRING) return m_nodes[i].sval;
      if(m_nodes[i].type == JSON_NUMBER) return DoubleToString(m_nodes[i].nval, 8);
      if(m_nodes[i].type == JSON_BOOL)   return (m_nodes[i].bval ? "true" : "false");
      return def;
     }

   //--- fills out[] from a JSON array of strings
   int               GetStringArray(const string path, string &out[]) const
     {
      int i = Resolve(path);
      if(i < 0 || m_nodes[i].type != JSON_ARRAY)
        {
         ArrayResize(out, 0);
         return 0;
        }
      int n = m_nodes[i].child_count;
      ArrayResize(out, n);
      int child = m_nodes[i].first_child;
      int k = 0;
      while(child >= 0 && k < n)
        {
         out[k] = (m_nodes[child].type == JSON_STRING
                   ? m_nodes[child].sval
                   : DoubleToString(m_nodes[child].nval, 8));
         child = m_nodes[child].next_sibling;
         k++;
        }
      return k;
     }
  };

//--- out-of-class because it recurses into ParseObject/ParseArray ----
bool CJson::ParseValue(int &out_index)
  {
   SkipWhitespace();
   if(m_pos >= m_len)
      return Fail("unexpected end of input");

   ushort c = StringGetCharacter(m_src, m_pos);

   if(c == '{')
      return ParseObject(out_index);
   if(c == '[')
      return ParseArray(out_index);

   if(c == '"')
     {
      string s = "";
      if(!ParseString(s))
         return false;
      int node = NewNode(JSON_STRING);
      m_nodes[node].sval = s;
      out_index = node;
      return true;
     }

   if(c == 't' && StringSubstr(m_src, m_pos, 4) == "true")
     {
      int node = NewNode(JSON_BOOL);
      m_nodes[node].bval = true;
      m_pos += 4;
      out_index = node;
      return true;
     }
   if(c == 'f' && StringSubstr(m_src, m_pos, 5) == "false")
     {
      int node = NewNode(JSON_BOOL);
      m_nodes[node].bval = false;
      m_pos += 5;
      out_index = node;
      return true;
     }
   if(c == 'n' && StringSubstr(m_src, m_pos, 4) == "null")
     {
      int node = NewNode(JSON_NULL);
      m_pos += 4;
      out_index = node;
      return true;
     }

   //--- number
   int start = m_pos;
   if(c == '-' || c == '+')
      m_pos++;
   bool any = false;
   while(m_pos < m_len)
     {
      ushort d = StringGetCharacter(m_src, m_pos);
      if((d >= '0' && d <= '9') || d == '.' || d == 'e' || d == 'E' || d == '-' || d == '+')
        {
         any = true;
         m_pos++;
         continue;
        }
      break;
     }
   if(!any)
      return Fail("unexpected token");
   int node2 = NewNode(JSON_NUMBER);
   m_nodes[node2].nval = StringToDouble(StringSubstr(m_src, start, m_pos - start));
   out_index = node2;
   return true;
  }

#endif // __ADAPTIVE_JSON_MQH__

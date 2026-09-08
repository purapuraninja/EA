//+------------------------------------------------------------------+
//|                                    EA Grid Buy XAUUSD.mq5        |
//|              3-Level Grid Buy System for XAUUSD - MT5            |
//|   L1=DefaultLot | L2=-1R → 2x | L3=-2R → 4x (capped MaxLot)   |
//|   TP=123R  |  BE Trigger → Lock → Trailing (via preset file)    |
//+------------------------------------------------------------------+
#property copyright   "EA Grid Buy XAUUSD"
#property version     "1.20"
#property description "3-Level Grid Buy EA for XAUUSD + News Filter"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters (saveable as .set preset file)                  |
//+------------------------------------------------------------------+

input group "=== Grid Settings ==="
input double InpDefaultLot  = 0.02;   // Default Lot (Level 1)
input double InpMaxLot      = 3.0;    // Max Lot per Grid Level
input double InpRValue      = 10.0;   // 1R Value in USD
input double InpR_L1toL2    = 1.0;    // Trigger L1→L2 (×R) | 0.02→0.04 | USD: lihat log
input double InpR_L2toL3    = 3.0;    // Trigger L2→L3 (×R) | 0.04→0.08 | USD: lihat log

input group "=== Take Profit ==="
input double InpTPR         = 123.0;  // Take Profit (x R)

input group "=== Stop Loss (opsional) ==="
input bool   InpUseSL       = true;  // Aktifkan Stop Loss awal
input double InpSLPoints    = 1000.0;  // SL: jarak dari entry (points)

input group "=== BE & Trail Preset ==="
input double InpBETrigger   = 150.0;  // BE Trigger: points above avg entry
input double InpBELock      = 30.0;   // BE Lock: SL = avg entry + this (points)
input double InpTrailDist   = 80.0;   // Trail: SL = Bid - this (points)

input group "=== Stop News ==="
input bool   InpUseNews        = true; // Aktifkan filter news
input int    InpNewsMinsBefore = 60;   // Menit sebelum news (stop buka posisi)
input int    InpNewsMinsAfter  = 60;   // Menit setelah news (stop buka posisi)
input bool   InpNewsHighOnly   = true; // Hanya filter news HIGH impact (false = HIGH+MED)

input group "=== Sesi Trading ==="
input bool   InpSkipAsian  = false; // Nonaktifkan sesi Asian → trading hanya UK+NY
input int    InpAsianStart = 0;     // Asian: jam mulai (server time, 0=00:00)
input int    InpAsianEnd   = 8;     // Asian: jam selesai (server time, 8=08:00)

input group "=== EA Identity ==="
input int    InpMagic       = 202401; // Magic Number
input string InpComment     = "GBX";  // Trade Comment Prefix

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade g_trade;

int      g_level      = 0;     // 0=none, 1=L1, 2=L2, 3=L3
bool     g_beOn       = false; // BE+trail active
datetime g_lastOpen   = 0;     // timestamp of last OpenBuy; blocks same-second opens
bool     g_newsCache  = false; // cached result IsNewsTime
datetime g_newsCheck  = 0;     // last time news cache was refreshed

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(100);
   g_trade.SetTypeFilling(GetFillMode());

   RestoreState();

   PrintFormat("Init OK | Lot=%.2f R=$%.2f TP=%.0fR | "
               "BE_Trigger=%.0f BE_Lock=%.0f Trail=%.0f (pts)",
               InpDefaultLot, InpRValue, InpTPR,
               InpBETrigger, InpBELock, InpTrailDist);
   PrintFormat("Grid Trigger | L1(%.2f)→L2(%.2f): floating ≤ -%.0fR = -$%.2f | "
               "L2(%.2f)→L3(%.2f): floating ≤ -%.0fR = -$%.2f",
               InpDefaultLot, InpDefaultLot * 2,
               InpR_L1toL2, InpR_L1toL2 * InpRValue,
               InpDefaultLot * 2, MathMin(InpDefaultLot * 4, InpMaxLot),
               InpR_L2toL3, InpR_L2toL3 * InpRValue);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("Deinit reason=%d", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if (!MQLInfoInteger(MQL_TRADE_ALLOWED))           return;

   int count = CountPos();

   //--- Posisi ditutup eksternal (SL/TP broker): reset state agar bisa mulai lagi
   if (count == 0 && g_level > 0)
      ResetState();

   //--- Satu aksi buka per detik (cegah cascade dari spread)
   if (TimeCurrent() == g_lastOpen) return;

   //--- Cek news & sesi: blok pembukaan posisi baru, BE/Trail tetap aktif
   bool newsBlock = IsNewsTime() || !IsSessionAllowed();

   //--- No positions: start fresh with Level 1
   if (count == 0)
   {
      if (newsBlock) return;
      if (OpenBuy(NormLot(InpDefaultLot), "L1"))
      {
         g_level    = 1;
         g_lastOpen = TimeCurrent();
      }
      return;
   }

   double totalPL  = TotalFloating();
   double avgEntry = AvgEntry();
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Level 1 → 2: floating <= -(InpR_L1toL2 × R), buka lot 0.04
   if (g_level == 1 && totalPL <= -(InpR_L1toL2 * InpRValue))
   {
      if (!newsBlock)
      {
         double lot = NormLot(MathMin(InpDefaultLot * 2.0, InpMaxLot));
         if (OpenBuy(lot, "L2"))
         {
            g_level    = 2;
            g_lastOpen = TimeCurrent();
         }
      }
      return;
   }

   //--- Level 2 → 3: floating <= -(InpR_L2toL3 × R), buka lot 0.08
   if (g_level == 2 && totalPL <= -(InpR_L2toL3 * InpRValue))
   {
      if (!newsBlock)
      {
         double lot = NormLot(MathMin(InpDefaultLot * 4.0, InpMaxLot));
         if (OpenBuy(lot, "L3"))
         {
            g_level    = 3;
            g_lastOpen = TimeCurrent();
         }
      }
      return;
   }

   //--- TP: close all positions when total floating >= 123R
   if (totalPL >= InpTPR * InpRValue)
   {
      CloseAll("TP_123R");
      return;
   }

   //--- BE & Trailing Stop management
   if (avgEntry > 0.0 && bid > 0.0)
      ManageBETrail(avgEntry, bid);
}

//+------------------------------------------------------------------+
//| BE & Trailing Logic                                              |
//+------------------------------------------------------------------+
void ManageBETrail(double avgEntry, double bid)
{
   //--- Activate BE when Bid >= avgEntry + BE_Trigger points
   if (!g_beOn)
   {
      if (bid >= avgEntry + InpBETrigger * _Point)
      {
         double beSL = NormalizeDouble(avgEntry + InpBELock * _Point, _Digits);
         beSL = SafeSL(beSL, bid);
         SetAllSL(beSL);
         g_beOn = true;
         PrintFormat("BE activated | AvgEntry=%.2f | SL set to %.2f", avgEntry, beSL);
      }
      return;
   }

   //--- Trail: SL = Bid - TrailDist (only moves SL upward)
   double trailSL = NormalizeDouble(bid - InpTrailDist * _Point, _Digits);
   trailSL = SafeSL(trailSL, bid);
   if (trailSL > BestSL())
      SetAllSL(trailSL);
}

//+------------------------------------------------------------------+
//| Cek apakah sedang dalam window news (60 min before/after)        |
//| Menggunakan MT5 Economic Calendar (built-in, tidak perlu API)    |
//| Hanya memblok PEMBUKAAN posisi baru — BE/Trail tetap berjalan    |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Cek apakah sesi saat ini diizinkan untuk trading                 |
//| InpSkipAsian = false → semua sesi boleh (default)               |
//| InpSkipAsian = true  → skip sesi Asian, hanya UK+NY             |
//| BE/Trail tetap aktif meskipun di luar sesi yang diizinkan        |
//+------------------------------------------------------------------+
bool IsSessionAllowed()
{
   if (!InpSkipAsian) return true; // filter off → semua sesi boleh

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;

   bool inAsian;
   if (InpAsianStart < InpAsianEnd)
      inAsian = (h >= InpAsianStart && h < InpAsianEnd);
   else
      inAsian = (h >= InpAsianStart || h < InpAsianEnd);

   return !inAsian; // boleh trading saat BUKAN sesi Asian
}

bool IsNewsTime()
{
   if (!InpUseNews) return false;

   // Refresh cache setiap 60 detik untuk hemat resource
   if (TimeCurrent() - g_newsCheck < 60)
      return g_newsCache;

   g_newsCheck = TimeCurrent();
   g_newsCache = false;

   datetime now  = TimeCurrent();
   datetime from = now - (datetime)(InpNewsMinsAfter  * 60);
   datetime to   = now + (datetime)(InpNewsMinsBefore * 60);

   MqlCalendarValue values[];

   // USD news = paling berpengaruh ke XAUUSD
   int cnt = CalendarValueHistory(values, from, to, "US");
   for (int i = 0; i < cnt; i++)
   {
      MqlCalendarEvent ev;
      if (!CalendarEventById(values[i].event_id, ev)) continue;

      bool highImpact = (ev.importance == CALENDAR_IMPORTANCE_HIGH);
      bool medImpact  = (ev.importance == CALENDAR_IMPORTANCE_MODERATE);

      if (highImpact || (!InpNewsHighOnly && medImpact))
      {
         g_newsCache = true;
         PrintFormat("NEWS BLOCK: [%s] %s @ %s",
                     (highImpact ? "HIGH" : "MED"),
                     ev.name,
                     TimeToString(values[i].time, TIME_DATE|TIME_MINUTES));
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count EA positions on this symbol                                |
//+------------------------------------------------------------------+
int CountPos()
{
   int n = 0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   return n;
}

//+------------------------------------------------------------------+
//| Total floating P&L (profit + swap) for all EA positions          |
//+------------------------------------------------------------------+
double TotalFloating()
{
   double v = 0.0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic)
         v += PositionGetDouble(POSITION_PROFIT)
            + PositionGetDouble(POSITION_SWAP);
   return v;
}

//+------------------------------------------------------------------+
//| Volume-weighted average entry price of all Buy positions          |
//+------------------------------------------------------------------+
double AvgEntry()
{
   double vol = 0.0, ws = 0.0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic &&
          PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         double v = PositionGetDouble(POSITION_VOLUME);
         vol += v;
         ws  += v * PositionGetDouble(POSITION_PRICE_OPEN);
      }
   return (vol > 0.0) ? ws / vol : 0.0;
}

//+------------------------------------------------------------------+
//| Highest SL among all EA positions (most protective for Buy)      |
//+------------------------------------------------------------------+
double BestSL()
{
   double best = 0.0;
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         double sl = PositionGetDouble(POSITION_SL);
         if (sl > best) best = sl;
      }
   return best;
}

//+------------------------------------------------------------------+
//| Set SL on all EA positions (only moves SL upward)                |
//+------------------------------------------------------------------+
void SetAllSL(double newSL)
{
   newSL = NormalizeDouble(newSL, _Digits);
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         ulong  tkt   = PositionGetInteger(POSITION_TICKET);
         double curSL = PositionGetDouble(POSITION_SL);
         double tp    = PositionGetDouble(POSITION_TP);
         if (newSL > curSL)
            if (!g_trade.PositionModify(tkt, newSL, tp))
               PrintFormat("ModifySL err=%d ticket=%I64u",
                           g_trade.ResultRetcode(), tkt);
      }
}

//+------------------------------------------------------------------+
//| Clamp SL to broker minimum stop level below Bid                  |
//+------------------------------------------------------------------+
double SafeSL(double sl, double bid)
{
   int    stops   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = MathMax(stops, 1) * _Point;
   return MathMin(sl, NormalizeDouble(bid - minDist, _Digits));
}

//+------------------------------------------------------------------+
//| Open a Buy position at market price, no SL, no TP               |
//+------------------------------------------------------------------+
bool OpenBuy(double lot, string tag)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl  = 0.0;
   if (InpUseSL)
      sl = NormalizeDouble(ask - InpSLPoints * _Point, _Digits);

   bool ok = g_trade.Buy(lot, _Symbol, ask, sl, 0.0,
                         InpComment + "_" + tag);
   if (!ok)
      PrintFormat("OpenBuy[%s] FAIL err=%d %s",
                  tag, g_trade.ResultRetcode(),
                  g_trade.ResultRetcodeDescription());
   else
      PrintFormat("OpenBuy[%s] OK lot=%.2f ask=%.2f", tag, lot, ask);
   return ok;
}

//+------------------------------------------------------------------+
//| Close all EA positions                                           |
//+------------------------------------------------------------------+
void CloseAll(string reason)
{
   PrintFormat("CloseAll [%s] totalFL=$%.2f", reason, TotalFloating());
   for (int i = PositionsTotal() - 1; i >= 0; i--)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic)
      {
         ulong tkt = PositionGetInteger(POSITION_TICKET);
         if (!g_trade.PositionClose(tkt))
            PrintFormat("ClosePos err=%d ticket=%I64u",
                        g_trade.ResultRetcode(), tkt);
      }
   ResetState();
}

//+------------------------------------------------------------------+
//| Normalize lot to broker volume specs                             |
//+------------------------------------------------------------------+
double NormLot(double lot)
{
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minL, MathMin(maxL, lot));
   return NormalizeDouble(MathRound(lot / step) * step, 2);
}

//+------------------------------------------------------------------+
//| Auto-detect broker order filling mode                            |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillMode()
{
   MqlTradeRequest     req = {};
   MqlTradeCheckResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   req.price  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.type   = ORDER_TYPE_BUY;

   req.type_filling = ORDER_FILLING_FOK;
   if (OrderCheck(req, res))
      return ORDER_FILLING_FOK;
   if (res.retcode != TRADE_RETCODE_INVALID_FILL)
      return ORDER_FILLING_FOK;

   req.type_filling = ORDER_FILLING_IOC;
   if (OrderCheck(req, res))
      return ORDER_FILLING_IOC;
   if (res.retcode != TRADE_RETCODE_INVALID_FILL)
      return ORDER_FILLING_IOC;

   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Reset EA state variables                                         |
//+------------------------------------------------------------------+
void ResetState()
{
   g_level    = 0;
   g_beOn     = false;
   g_lastOpen = 0;
}

//+------------------------------------------------------------------+
//| Restore state after EA restart or reattach                       |
//+------------------------------------------------------------------+
void RestoreState()
{
   int n = CountPos();
   g_level = MathMin(n, 3);
   g_beOn  = false;
   for (int i = 0; i < PositionsTotal(); i++)
      if (PositionGetSymbol(i) == _Symbol &&
          PositionGetInteger(POSITION_MAGIC) == InpMagic &&
          PositionGetDouble(POSITION_SL) > 0.0)
      {
         g_beOn = true;
         break;
      }
   if (n > 0)
      PrintFormat("State restored: level=%d beOn=%s positions=%d",
                  g_level, g_beOn ? "true" : "false", n);
}
//+------------------------------------------------------------------+

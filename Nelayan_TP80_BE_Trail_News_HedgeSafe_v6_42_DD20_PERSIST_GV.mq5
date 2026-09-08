//+------------------------------------------------------------------+
//|                               buy only Nelayan_TP80_BE_Trail_News |
//|                               Based on EA_Grid_V6_SmartFix (v6.00) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Gemini Partner"
#property link      "https://www.mql5.com"
#property version   "6.40" // DD20 + TrendLock + CutWorst + PendingCaps

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS (GRID)
input double InpLotSize    = 0.01;   // Lot Size
input int    InpDistance   = 4000;   // Jarak Grid (points)
input int    InpBatchSize  = 6;     // Jumlah Layer (40 Atas & 40 Bawah)
input int    InpMagicNum   = 12345;  // Magic Number

//--- INPUT PARAMETERS (RISK/EXIT)
input int    InpTP_Pips          = 80;    // Take Profit per posisi (pips)
input int    InpBE_Trigger_Pips  = 80;    // Profit (pips) untuk set SL ke BE
input int    InpBE_Lock_Pips     = 1;     // Tambahan pips di atas BE (lock profit kecil)
input int    InpTrail_Start_Pips = 85;    // Mulai trailing setelah profit (pips)
input int    InpTrail_Dist_Pips  = 30;    // Jarak trailing (pips)
input int    InpTrail_Step_Pips  = 5;     // Step minimal naiknya SL saat trailing (pips)

//--- INPUT PARAMETERS (FILTERS - OPTIONAL)
input bool   InpUseSpreadFilter  = true;  // Stop pas spread melebar
input int    InpMaxSpreadPips    = 50;     // Maks spread (pips) untuk tetap trading

input bool   InpUseNewsFilter           = true;                 // Stop pas news (Economic Calendar MT5)
input int    InpNewsMinutesBefore       = 30;                    // Berhenti X menit sebelum news
input int    InpNewsMinutesAfter        = 30;                    // Berhenti X menit setelah news
input ENUM_CALENDAR_EVENT_IMPORTANCE InpMinNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Min importance
input bool   InpIncludeHolidays         = false;                 // Ikut pause saat holiday event
input string InpNewsCurrencies          = "AUTO";                // "AUTO" (base+quote) atau "USD,EUR,..."
input bool   InpDeletePendingsDuringPause = true;               // Hapus pending order EA saat pause (opsional)

//--- INPUT PARAMETERS (ROLLOVER / RISK GUARDS - OPTIONAL)
input bool   InpUseRolloverGuard       = true;   // Close & pause menjelang rollover (00:00 server)
input int    InpRolloverMinutesBefore  = 10;     // Tutup posisi X menit sebelum 00:00 server
input int    InpRolloverMinutesAfter   = 5;      // Pause X menit setelah 00:00 server

input bool   InpUseEquityDDGuard       = true;   // Equity/DD guard (close & stop)
input double InpMaxDDPercentFromPeak   = 20.0;   // Max DD % dari peak equity (0=off)
input double InpMaxDDMoney             = 0.0;    // Max DD money dari peak equity (0=off)
input bool   InpDisableAfterDD         = true;   // Setelah DD trigger, stop pasang order (cooldown opsional)
input int    InpDDCooldownMinutes      = 30;     // Jika >0: mulai lagi setelah N menit (0=butuh restart)

//--- INPUT PARAMETERS (EXPOSURE / TREND LOCK / RECOVERY) [PATCH v6.40]
input bool   InpUseTrendLock            = true;   // Pause grid saat bearish kuat (MA filter)
input bool   InpTrendLockDeletePendings = true;   // Hapus pending BUY EA saat TrendLock / Recovery aktif

input int    InpMaxPendingTotal         = 40;     // Hard cap total pending order EA (0=off)
input int    InpMaxOpenBuyPositions     = 12;     // Hard cap posisi BUY EA (0=off)
input double InpMaxTotalBuyLots         = 0.12;   // Hard cap total lot BUY EA (0=off)

input bool   InpUseCutWorst             = true;   // Cut worst BUY bertahap saat floating loss dalam
input double InpCutWorstStartLossMoney  = 12.0;   // Mulai cut worst jika floating BUY <= -nilai ini (mata uang akun)
input double InpCutWorstStopLossMoney   = 6.0;    // Stop cut jika floating BUY >= -nilai ini (mata uang akun)
input int    InpCutWorstCooldownSec     = 120;    // Jeda minimal antar cut worst (detik)
input int    InpRecoveryPauseMinutes    = 10;     // Setelah cut worst, pause grid N menit

input bool   InpUseBasketStop           = true;   // Close semua sebelum DD guard (safety)
input double InpBasketStopDDPercent     = 18.0;   // Trigger basket stop saat DD% >= ini (0=off)
input double InpBasketStopMoney         = 0.0;    // Trigger basket stop saat DD money >= ini (0=off)



input bool   InpXAU_NoHoldPolicy       = false;
input bool   InpUseBearishHedge         = true;   // buka SELL hedge kecil saat bearish (akun hedging)
input ENUM_TIMEFRAMES InpHedgeTF        = PERIOD_M15;
input int    InpHedgeMAPeriod           = 200;
input bool   InpHedgeUseEMA             = true;    // true=EMA, false=SMA
input double InpHedgeRatio              = 0.50;    // porsi hedge vs total BUY lots (0.30 = 30%)
input double InpHedgeMaxLot             = 0.08;    // maksimum lot hedge total
input double InpHedgeMinLot             = 0.01;    // minimum lot hedge sekali entry
input bool   InpHedgeCloseWhenNotBearish= true;    // tutup hedge saat tidak bearish   // Khusus XAU*: kalau lagi pause (news/spread/rollover), close posisi + hapus pending (no-hold)

//--- HEDGE TRIGGER BY FLOATING BUY LOSS (money)
input bool   InpHedgeTriggerByFloating = true;   // true=hedge berdasarkan floating BUY minus, false=pakai sinyal bearish MA
input double InpHedgeStartLossMoney    = 10.0;   // mulai hedge jika floating BUY <= -nilai ini (mata uang akun)
input double InpHedgeStopLossMoney     = 5.0;    // tutup hedge jika floating BUY >= -nilai ini (pulih) (butuh InpHedgeCloseWhenNotBearish=true)
//--- HEDGE PARTIAL CLOSE
input bool   InpHedgePartialClose          = true;   // close hedge bertahap saat kondisi close terpenuhi
input double InpHedgePartialCloseFraction  = 0.50;   // porsi hedge yg ditutup tiap aksi (0.1..1.0)
input int    InpHedgePartialCloseCooldownSec = 60;   // jeda minimal antar partial close (detik)
input bool   InpHedgeUseStep           = true;   // tambah hedge bertahap per floating loss step (hanya aktif jika TriggerByFloating=true)
input double InpHedgeStepLossMoney      = 6.0;   // setiap tambahan rugi sebesar ini, target hedge ditambah
input double InpHedgeStepLot            = 0.01;   // tambahan lot hedge per step

//--- HEDGE SAFETY (prevent SELL hedge floating deep minus)
input int    InpHedgeTP_Pips          = 90;   // TP untuk posisi hedge SELL (pips)
input int    InpHedgeSL_Pips          = 170;   // SL maksimum untuk hedge SELL (pips)
input int    InpHedgeBE_Trigger_Pips  = 42;    // Profit pips untuk set SL hedge ke BE
input int    InpHedgeBE_Lock_Pips     = 6;     // Lock profit kecil di BE hedge
input int    InpHedgeTrail_Start_Pips = 55;    // Mulai trailing hedge setelah profit (pips)
input int    InpHedgeTrail_Dist_Pips  = 18;    // Jarak trailing hedge (pips)
input int    InpHedgeTrail_Step_Pips  = 6;     // Step trailing hedge (pips)
input int    InpHedgeMaxAdverse_Pips  = 65;    // Cut hedge jika harga berbalik melawan SELL (pips)
input double InpHedgeCloseRecoveryMoney = 4.0;// Jika BUY floating sudah pulih >= -nilai ini, boleh tutup hedge walau rugi kecil

//--- INPUT PARAMETERS (BULLISH ADD-ON - OPTIONAL)
input bool           InpUseBullishAddOn        = false;        // setelah ada BUY baru, jika bullish terkonfirmasi buka BUY tambahan
input ENUM_TIMEFRAMES InpBullishTF             = PERIOD_M15;
input int            InpBullishMAPeriod        = 200;
input bool           InpBullishUseEMA          = true;         // true=EMA, false=SMA
input double         InpBullishAddLot          = 0.0;          // 0=pakai InpLotSize
input int            InpBullishCooldownSeconds = 60;           // jeda minimal antar add-on (detik)
input int            InpBullishMaxOpenAddOns   = 1;            // maksimum posisi add-on BUY yang boleh terbuka bersamaan

//--- GLOBAL VARIABLES
CTrade m_trade;

string gv_anchor_name;
string gv_max_up_name;
string gv_max_down_name;
string gv_disabled_name;
string gv_peak_equity_name;
string gv_start_equity_name;

//--- runtime state
static double   g_peak_equity = 0.0;
static double   g_start_equity = 0.0;
static datetime g_recovery_until = 0;      // pause grid placement until this time (server)
static datetime g_last_cut_time  = 0;      // last cut-worst action time
static datetime g_last_grid_pause_log = 0; // anti-spam log for TrendLock/Recovery


// Bearish hedge indicator handle (MA)
int g_hedge_ma_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_hedge_ma_tf_last = PERIOD_CURRENT;
int g_hedge_ma_period_last = -1;
bool g_hedge_ma_is_ema_last = true;



 // Bullish add-on indicator handle (MA)
int g_bull_ma_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_bull_ma_tf_last = PERIOD_CURRENT;
int g_bull_ma_period_last = -1;
bool g_bull_ma_is_ema_last = true;

static datetime g_last_addon_time = 0;

static datetime g_last_rollover_close_for = 0;

//--- internal state (anti-spam log)
datetime g_last_pause_log = 0;

//+------------------------------------------------------------------+
//| Utils                                                            |
//+------------------------------------------------------------------+
double PipValue()
{
   // 5 digits (EURUSD 1.23456) / 3 digits (USDJPY 123.456) => 1 pip = 10 points
   if(_Digits == 5 || _Digits == 3) return(_Point * 10.0);
   return(_Point);
}

string Trim(const string s)
{
   string out = s;
   StringTrimLeft(out);
   StringTrimRight(out);
   return out;
}

int SplitCSV(const string csv, string &arr[])
{
   string cleaned = csv;
   // normalize separators
   StringReplace(cleaned, ";", ",");
   int n = StringSplit(cleaned, ',', arr);
   for(int i=0;i<n;i++) arr[i] = Trim(arr[i]);
   return n;
}

// Extract first 6 alphabetic chars from symbol (ignoring suffix/prefix like "m", ".pro", "_ecn", etc)
// Example: "XAUUSDm" / "XAUUSDc" -> "XAUUSD", "EURUSD" -> "EURUSD"
string SymbolCore6(const string sym)
{
   string up = sym;
   StringToUpper(up);
   string out = "";
   int len = StringLen(up);
   for(int i=0; i<len; i++)
   {
      ushort ch = StringGetCharacter(up, i);
      // A-Z
      if(ch >= 'A' && ch <= 'Z')
      {
         out += StringSubstr(up, i, 1);
         if(StringLen(out) >= 6) break;
      }
   }
   if(StringLen(out) < 6) return "";
   return StringSubstr(out, 0, 6);
}

bool IsKnownCurrency(const string ccy)
{
   string u = Trim(ccy);
   StringToUpper(u);
   if(StringLen(u) != 3) return false;

   // Major + common ISO 4217 codes (typical MT5 Calendar "currency" values)
   // Metals (XAU/XAG/...) are intentionally excluded.
   const string known[] = {
      "USD","EUR","JPY","GBP","CHF","AUD","NZD","CAD",
      "CNH","CNY","HKD","SGD","KRW","TWD","INR","IDR","THB","MYR","PHP","VND",
      "SEK","NOK","DKK","PLN","CZK","HUF","RON","BGN","TRY","ILS",
      "ZAR","MXN","BRL","CLP","COP","PEN","ARS",
      "SAR","AED","QAR","KWD","BHD","OMR","EGP",
      "RUB","UAH","KZT"
   };

   for(int i=0; i<(int)ArraySize(known); i++)
      if(u == known[i]) return true;

   return false;
}

bool AddUnique(string &arr[], const string val)
{
   string v = Trim(val);
   StringToUpper(v);
   if(StringLen(v) == 0) return false;
   for(int i=0; i<(int)ArraySize(arr); i++)
      if(arr[i] == v) return false;
   int n = ArraySize(arr);
   ArrayResize(arr, n+1);
   arr[n] = v;
   return true;
}

int GetCurrenciesForFilter(string &outArr[])
{
   ArrayResize(outArr, 0);

   string mode = Trim(InpNewsCurrencies);
   if(StringLen(mode) == 0) return 0;

   string mode_up = mode;
   StringToUpper(mode_up);

   if(mode_up == "AUTO")
   {
      // Robust parsing for:
      //  - Forex: EURUSD, GBPJPY, GBPUSD ...
      //  - Metals with suffix: XAUUSDm / XAUUSDc ... (we'll pick USD only)
      //  - Any symbol with suffix/prefix: "EURUSD.pro" -> "EURUSD" core
      string core = SymbolCore6(_Symbol);
      if(StringLen(core) == 6)
      {
         string base  = StringSubstr(core, 0, 3);
         string quote = StringSubstr(core, 3, 3);

         // Use only valid calendar currencies
         if(IsKnownCurrency(base))  AddUnique(outArr, base);
         if(IsKnownCurrency(quote)) AddUnique(outArr, quote);

         // If base not a currency (e.g., XAU), quote is usually the one we want (USD).
         return (int)ArraySize(outArr);
      }

      // fallback: no filter if symbol not standard
      return 0;
   }

   string tmp[];
   int n = SplitCSV(mode, tmp);
   if(n <= 0) return 0;

   // remove empties
   int k=0;
   ArrayResize(outArr, n);
   for(int i=0;i<n;i++)
   {
      if(StringLen(tmp[i]) == 0) continue;
      string tmpu = tmp[i];
      StringToUpper(tmpu);
      outArr[k++] = tmpu;
   }
   ArrayResize(outArr, k);
   return k;
}

bool SpreadTooWide(double ask, double bid)
{
   if(!InpUseSpreadFilter) return false;

   double pip = PipValue();
   if(pip <= 0) return false;

   double spread_points = (ask - bid) / _Point;
   double max_points = (InpMaxSpreadPips * pip) / _Point; // convert pips -> points
   if(max_points <= 0) return false;

   return (spread_points > max_points);
}

bool IsNewsPauseWindow(string &why)
{
   why = "";
   if(!InpUseNewsFilter) return false;

   // Calendar times are in trade server timezone, use TimeTradeServer() as recommended.
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   datetime from = now - (InpNewsMinutesAfter * 60);
   datetime to   = now + (InpNewsMinutesBefore * 60);

   string ccy[];
   int ccy_n = GetCurrenciesForFilter(ccy);

   // If no currencies, we still can query without currency filter (might be heavy).
   // We'll do it anyway but with a tiny window (already small).
   if(ccy_n <= 0)
   {
      ArrayResize(ccy, 1);
      ccy[0] = ""; // no currency filter
      ccy_n = 1;
   }

   for(int c=0; c<ccy_n; c++)
   {
      string currency = ccy[c];
      MqlCalendarValue values[];
      ResetLastError();
      int total = CalendarValueHistory(values, from, to, "", currency);
      if(total <= 0) continue;

      for(int i=0; i<total; i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;

         if(!InpIncludeHolidays && ev.type == CALENDAR_TYPE_HOLIDAY)
            continue;

         if(ev.importance < InpMinNewsImportance)
            continue;

         // values[i].time should already be within [from,to] due to query window.
         // This means: "30 minutes before OR 30 minutes after" style window around now.
         why = StringFormat("News window: %s (importance=%d) at %s, currency=%s",
                            ev.name,
                            (int)ev.importance,
                            TimeToString(values[i].time, TIME_DATE|TIME_MINUTES),
                            ((currency=="" ) ? "ALL" : currency));
         return true;
      }
   }
   return false;
}


//+------------------------------------------------------------------+
//| Extra guards / helpers                                            |
//+------------------------------------------------------------------+
string SymbolLettersUpper()
{
   string up = _Symbol;
   StringToUpper(up);

   string letters = "";
   int n = StringLen(up);
   for(int i=0; i<n; i++)
   {
      string ch = StringSubstr(up, i, 1);
      if(ch >= "A" && ch <= "Z")
         letters += ch;
   }
   return letters;
}

bool IsXAUInstrument()
{
   string letters = SymbolLettersUpper();
   if(StringLen(letters) < 3) return false;
   return (StringSubstr(letters, 0, 3) == "XAU");
}

bool IsTradingDisabled()
{
   if(!InpDisableAfterDD) return false;
   if(!GlobalVariableCheck(gv_disabled_name)) return false;

   double v = GlobalVariableGet(gv_disabled_name);
   if(v <= 0.5) return false;

   // Legacy mode: disabled until restart
   if(InpDDCooldownMinutes <= 0)
      return true;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   // v stores disabled_until (server time) when cooldown is used.
   datetime disabled_until = (datetime)v;

   // If older value is just 1.0, treat as disabled until restart.
   if(disabled_until < 100000)
      return true;

   if(now < disabled_until)
      return true;

   // Cooldown finished -> re-enable
   GlobalVariableSet(gv_disabled_name, 0.0);

   // Reset peak equity to avoid re-trigger loop
   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = AccountInfoDouble(ACCOUNT_BALANCE);
   GlobalVariableSet(gv_peak_equity_name, g_peak_equity);

return false;
}


bool CheckEquityDDGuard(string &why)
{
   why = "";
   if(!InpUseEquityDDGuard) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(equity <= 0.0) equity = balance;

   // Ensure baselines exist (persist across restarts)
   if(g_start_equity <= 0.0)
   {
      if(GlobalVariableCheck(gv_start_equity_name))
         g_start_equity = GlobalVariableGet(gv_start_equity_name);
      else
      {
         g_start_equity = equity;
         GlobalVariableSet(gv_start_equity_name, g_start_equity);
      }
   }

   if(g_peak_equity <= 0.0)
   {
      if(GlobalVariableCheck(gv_peak_equity_name))
         g_peak_equity = GlobalVariableGet(gv_peak_equity_name);
      else
         g_peak_equity = equity;
   }

   // Update peak equity + persist
   if(equity > g_peak_equity)
   {
      g_peak_equity = equity;
      GlobalVariableSet(gv_peak_equity_name, g_peak_equity);
   }

   double dd_peak  = g_peak_equity - equity;
   double dd_start = g_start_equity - equity;

   if(dd_peak  < 0.0) dd_peak  = 0.0;
   if(dd_start < 0.0) dd_start = 0.0;

   double dd_peak_pct  = 0.0;
   double dd_start_pct = 0.0;

   if(g_peak_equity  > 0.0) dd_peak_pct  = dd_peak  / g_peak_equity  * 100.0;
   if(g_start_equity > 0.0) dd_start_pct = dd_start / g_start_equity * 100.0;

   bool trig = false;
   if(InpMaxDDPercentFromPeak > 0.0)
   {
      if(dd_peak_pct  >= InpMaxDDPercentFromPeak) trig = true;
      if(dd_start_pct >= InpMaxDDPercentFromPeak) trig = true;
   }
   if(InpMaxDDMoney > 0.0)
   {
      if(dd_peak  >= InpMaxDDMoney) trig = true;
      if(dd_start >= InpMaxDDMoney) trig = true;
   }

   if(!trig) return false;

   why = StringFormat("Equity DD guard triggered: DD_peak=%.2f (%.1f%%) peak=%.2f | DD_start=%.2f (%.1f%%) start=%.2f | equity=%.2f",
                      dd_peak, dd_peak_pct, g_peak_equity,
                      dd_start, dd_start_pct, g_start_equity,
                      equity);

   // Close & stop
   CloseAllPositionsOfEA();
   DeletePendingOrdersOfEA();
   if(InpDisableAfterDD)
   {
      datetime now = TimeTradeServer();
      if(now <= 0) now = TimeCurrent();
      if(InpDDCooldownMinutes > 0)
      {
         datetime until = now + (datetime)(InpDDCooldownMinutes * 60);
         GlobalVariableSet(gv_disabled_name, (double)until);
      }
      else
      {
         GlobalVariableSet(gv_disabled_name, 1.0);
      }
   }

   // Reset peak equity to avoid repeated triggers on next ticks + persist
   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = AccountInfoDouble(ACCOUNT_BALANCE);
   GlobalVariableSet(gv_peak_equity_name, g_peak_equity);

   PrintFormat("[EA_V6_DDGuard] %s", why);
   return true;
}

bool IsRolloverPauseWindow(bool &doCloseNow, string &why)
{
   doCloseNow = false;
   why = "";
   if(!InpUseRolloverGuard) return false;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Next 00:00 (server time)
   MqlDateTime dt0 = dt;
   dt0.hour = 0;
   dt0.min  = 0;
   dt0.sec  = 0;
   datetime midnight = StructToTime(dt0);
   if(now >= midnight)
      midnight += 86400;

   datetime start = midnight - (InpRolloverMinutesBefore * 60);
   datetime end   = midnight + (InpRolloverMinutesAfter  * 60);

   if(now < start || now > end)
      return false;

   why = StringFormat("Rollover window (00:00 server) around %s",
                      TimeToString(midnight, TIME_DATE|TIME_MINUTES));

   // Close once per rollover day in the 'before' window
   if(now >= start && now < midnight)
   {
      if(g_last_rollover_close_for != midnight)
      {
         doCloseNow = true;
         g_last_rollover_close_for = midnight;
      }
   }
   return true;
}

// Close all positions opened by this EA (symbol + magic)
bool CloseAllPositionsOfEA()
{
   bool any=false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action   = TRADE_ACTION_DEAL;
      req.position = ticket;
      req.symbol   = _Symbol;
      req.magic    = InpMagicNum;
      req.volume   = vol;
      req.deviation= 100;
      req.type_filling = ORDER_FILLING_IOC;

      if(ptype == POSITION_TYPE_BUY)
      {
         req.type  = ORDER_TYPE_SELL;
         req.price = bid;
      }
      else
      {
         req.type  = ORDER_TYPE_BUY;
         req.price = ask;
      }

      ResetLastError();
      bool ok = OrderSend(req, res);
      if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
         any=true;
      else
      {
         PrintFormat("[EA_V6_Close] Failed close pos %I64u ret=%d err=%d",
                     ticket, (int)res.retcode, GetLastError());
      }
   }
   return any;
}


bool DeletePendingOrdersOfEA()
{
   bool any=false;
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket==0) continue;
      if(!OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNum)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_BUY_STOP)
         continue;

      if(m_trade.OrderDelete(ticket))
         any=true;
      else
         PrintFormat("[EA_V6_News] Gagal delete pending ticket=%I64u retcode=%d",
                     (long)ticket, (int)m_trade.ResultRetcode());
   }
   return any;
}

bool ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol   = _Symbol;
   request.sl       = sl;
   request.tp       = tp;

   ResetLastError();
   bool ok = OrderSend(request, result);
   if(!ok)
   {
      PrintFormat("[EA_V6_TPBEtrail] OrderSend(SLTP) FAILED. ticket=%I64u err=%d retcode=%d",
                  (long)ticket, GetLastError(), (int)result.retcode);
      return false;
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("[EA_V6_TPBEtrail] OrderSend(SLTP) not DONE. ticket=%I64u retcode=%d",
                  (long)ticket, (int)result.retcode);
      return false;
   }

   return true;
}

void ManagePositions()
{
   double pip = PipValue();
   if(pip <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      // Ensure TP always set
      double wantTP = NormalizeDouble(open + (InpTP_Pips * pip), _Digits);

      bool needModify=false;
      double newSL = curSL;
      double newTP = curTP;

      if(wantTP > 0)
      {
         if(curTP <= 0 || MathAbs(curTP - wantTP) > (pip * 0.1))
         {
            newTP = wantTP;
            needModify=true;
         }
      }

      // Profit in pips
      double profitPips = (bid - open) / pip;

      // BE move
      if(profitPips >= InpBE_Trigger_Pips)
      {
         double beSL = NormalizeDouble(open + (InpBE_Lock_Pips * pip), _Digits);
         if(curSL <= 0 || beSL > curSL)
         {
            newSL = beSL;
            needModify=true;
         }
      }

      // Trailing (only moves SL up)
      if(profitPips >= InpTrail_Start_Pips)
      {
         double trailSL = NormalizeDouble(bid - (InpTrail_Dist_Pips * pip), _Digits);

         // Do not trail below BE SL if already set
         if(newSL > 0 && trailSL < newSL)
            trailSL = newSL;

         // Step filter
         double step = InpTrail_Step_Pips * pip;
         if(step < pip) step = pip;

         if(curSL <= 0)
         {
            // if SL not set, set directly to trailSL
            newSL = trailSL;
            needModify=true;
         }
         else
         {
            if(trailSL > curSL && (trailSL - curSL) >= step)
            {
               newSL = trailSL;
               needModify=true;
            }
         }
      }

      if(needModify)
      {
         // Keep zeros as "do not set"
         if(!ModifyPositionSLTP(ticket, newSL, newTP))
         {
            // nothing else
         }
      }
   }
}


// Sync TP for EA pending orders to current InpTP_Pips
void SyncPendingOrdersTP()
{
   double pip = PipValue();
   if(pip <= 0) return;

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNum)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_BUY_STOP)
         continue;

      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double curTP = OrderGetDouble(ORDER_TP);
      double curSL = OrderGetDouble(ORDER_SL);

      double wantTP = NormalizeDouble(price + (InpTP_Pips * pip), _Digits);
      if(wantTP <= 0) continue;

      if(curTP > 0 && MathAbs(curTP - wantTP) <= (pip * 0.1))
         continue;

      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);

      req.action   = TRADE_ACTION_MODIFY;
      req.order    = ticket;
      req.symbol   = _Symbol;
      req.price    = price;
      req.sl       = curSL;
      req.tp       = wantTP;

      req.type_time = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      req.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

      bool ok = OrderSend(req, res);
      if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL))
      {
         PrintFormat("[EA_TP_SYNC] Failed to modify pending TP. ticket=%I64u ret=%u (%s)",
                     ticket, res.retcode, res.comment);
      }
      else
      {
         PrintFormat("[EA_TP_SYNC] Pending TP updated. ticket=%I64u tp=%.5f", ticket, wantTP);
      }
   }
}



//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
bool GetMA2(double &ma0, double &ma1)
{
   // Returns MA current (bar0) and previous (bar1) on selected TF
   ENUM_MA_METHOD method = InpHedgeUseEMA ? MODE_EMA : MODE_SMA;

   // (Re)create handle if settings changed or handle invalid
   if(g_hedge_ma_handle == INVALID_HANDLE ||
      g_hedge_ma_tf_last != InpHedgeTF ||
      g_hedge_ma_period_last != InpHedgeMAPeriod ||
      g_hedge_ma_is_ema_last != InpHedgeUseEMA)
   {
      if(g_hedge_ma_handle != INVALID_HANDLE)
         IndicatorRelease(g_hedge_ma_handle);

      g_hedge_ma_handle = iMA(_Symbol, InpHedgeTF, InpHedgeMAPeriod, 0, method, PRICE_CLOSE);

      g_hedge_ma_tf_last = InpHedgeTF;
      g_hedge_ma_period_last = InpHedgeMAPeriod;
      g_hedge_ma_is_ema_last = InpHedgeUseEMA;
   }

   if(g_hedge_ma_handle == INVALID_HANDLE)
      return false;

   double buf[];
   ArrayResize(buf, 2);
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(g_hedge_ma_handle, 0, 0, 2, buf);
   if(copied < 2)
      return false;

   ma0 = buf[0];
   ma1 = buf[1];
   return true;
}

double NormalizeVolume(double vol)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = minv;

   if(vol < minv) vol = minv;
   if(vol > maxv) vol = maxv;

   // floor to step
   double k = MathFloor((vol - minv) / step + 1e-9);
   double out = minv + k * step;
   // if out becomes 0 due to precision, fix
   if(out < minv) out = minv;
   return out;
}

bool IsBearishNow()
{
   double ma0=0, ma1=0;
   if(!GetMA2(ma0, ma1))
      return false;

   // Use close price of current symbol/timeframe (bid as proxy)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Bearish if price below MA and MA is sloping down
   if(bid < ma0 && ma0 < ma1)
      return true;

   return false;
}


double GetBuyFloatingMoney()
{
   // Total floating P/L (profit+swap+commission) for BUY positions of this EA+symbol
   double sum = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_BUY)
         continue;

      double p = PositionGetDouble(POSITION_PROFIT);
      double s = PositionGetDouble(POSITION_SWAP);
      // NOTE: POSITION_COMMISSION can be deprecated in some MT5 builds; commission is ignored for floating trigger
      sum += (p + s);
   }
   return sum; // contoh: -25.30 artinya floating minus $25.30
}


//+------------------------------------------------------------------+
//| PATCH v6.40 : Risk helpers (BasketStop / CutWorst / Caps)        |
//+------------------------------------------------------------------+
datetime NowTime()
{
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   return now;
}

int CountEAPendingTotal()
{
   int count=0;
   for(int i=0; i<OrdersTotal(); i++)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket==0) continue;
      if(!OrderSelect(oticket)) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNum) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_BUY_STOP ||
         type==ORDER_TYPE_SELL_LIMIT || type==ORDER_TYPE_SELL_STOP)
         count++;
   }
   return count;
}

int CountEABuyPositions()
{
   int count=0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      count++;
   }
   return count;
}

double SumEABuyLots()
{
   double sum=0.0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      sum += PositionGetDouble(POSITION_VOLUME);
   }
   return sum;
}

bool FindWorstBuyPosition(ulong &ticketOut, double &profitOut)
{
   bool found=false;
   double worst=1e100;
   ulong worstTicket=0;

   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      double p = PositionGetDouble(POSITION_PROFIT);
      double s = PositionGetDouble(POSITION_SWAP);
      double v = p + s;

      if(v < worst)
      {
         worst = v;
         worstTicket = ticket;
         found = true;
      }
   }

   ticketOut = worstTicket;
   profitOut = (found ? worst : 0.0);
   return found;
}

bool ClosePositionByTicket(ulong ticket, double volumeToClose, const string comment)
{
   if(ticket == 0) return false;
   if(!PositionSelectByTicket(ticket)) return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double pos_vol = PositionGetDouble(POSITION_VOLUME);

   double vol = volumeToClose;
   if(vol <= 0.0 || vol > pos_vol) vol = pos_vol;
   vol = NormalizeVolume(vol);
   if(vol > pos_vol) vol = pos_vol;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.magic    = InpMagicNum;
   req.volume   = vol;
   req.deviation= 50;
   req.type_filling = ORDER_FILLING_IOC;
   req.comment  = comment;

   if(ptype == POSITION_TYPE_BUY)
   {
      req.type  = ORDER_TYPE_SELL;
      req.price = bid;
   }
   else
   {
      req.type  = ORDER_TYPE_BUY;
      req.price = ask;
   }

   ResetLastError();
   bool ok = OrderSend(req, res);
   if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL && res.retcode != TRADE_RETCODE_PLACED))
   {
      PrintFormat("[EA_V6_CloseOne] Failed close ticket=%I64u ret=%d err=%d", ticket, (int)res.retcode, GetLastError());
      return false;
   }
   return true;
}

void ResetGridAnchorNow()
{
   double cur = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(cur <= 0) cur = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(cur <= 0) return;

   if(GlobalVariableCheck(gv_anchor_name))
      GlobalVariableSet(gv_anchor_name, cur);
   if(GlobalVariableCheck(gv_max_up_name))
      GlobalVariableSet(gv_max_up_name, InpBatchSize);
   if(GlobalVariableCheck(gv_max_down_name))
      GlobalVariableSet(gv_max_down_name, InpBatchSize);
}

void DisableTradingForMinutes(int minutes)
{
   if(!InpDisableAfterDD) return;

   datetime now = NowTime();
   if(minutes > 0)
      GlobalVariableSet(gv_disabled_name, (double)(now + (datetime)(minutes * 60)));
   else
      GlobalVariableSet(gv_disabled_name, 1.0);
}

bool IsRecoveryActive(int &minsLeft)
{
   minsLeft = 0;
   datetime now = NowTime();
   if(g_recovery_until <= 0 || now >= g_recovery_until)
      return false;

   minsLeft = (int)MathCeil((double)(g_recovery_until - now) / 60.0);
   if(minsLeft < 0) minsLeft = 0;
   return true;
}

void EnterRecovery(const string reason)
{
   if(InpRecoveryPauseMinutes <= 0) return;
   datetime now = NowTime();
   g_recovery_until = now + (datetime)(InpRecoveryPauseMinutes * 60);
   PrintFormat("[EA_V6_Recovery] %s (pause grid %d min)", reason, InpRecoveryPauseMinutes);
}

bool CheckBasketStop(string &why)
{
   why = "";
   if(!InpUseBasketStop) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0) g_peak_equity = equity;
   if(equity > g_peak_equity) g_peak_equity = equity;

   double dd = g_peak_equity - equity;
   if(dd <= 0.0) return false;

   double dd_pct = 0.0;
   if(g_peak_equity > 0.0)
      dd_pct = dd / g_peak_equity * 100.0;

   bool trig=false;
   if(InpBasketStopDDPercent > 0.0 && dd_pct >= InpBasketStopDDPercent)
      trig=true;
   if(InpBasketStopMoney > 0.0 && dd >= InpBasketStopMoney)
      trig=true;

   if(!trig) return false;

   why = StringFormat("Basket stop: DD=%.2f (%.1f%%) peak=%.2f equity=%.2f",
                      dd, dd_pct, g_peak_equity, equity);

   CloseAllPositionsOfEA();
   DeletePendingOrdersOfEA();
   ResetGridAnchorNow();
   DisableTradingForMinutes(InpDDCooldownMinutes);

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = AccountInfoDouble(ACCOUNT_BALANCE);

   PrintFormat("[EA_V6_BasketStop] %s", why);
   return true;
}

void ManageCutWorst()
{
   if(!InpUseCutWorst) return;

   double bf = GetBuyFloatingMoney(); // negative = floating loss

   // If already recovered enough, end recovery early
   if(InpCutWorstStopLossMoney > 0.0 && bf >= -InpCutWorstStopLossMoney)
   {
      g_recovery_until = 0;
      return;
   }

   if(InpCutWorstStartLossMoney <= 0.0) return;
   if(bf > -InpCutWorstStartLossMoney) return;

   datetime now = NowTime();
   if(g_last_cut_time > 0 && (now - g_last_cut_time) < InpCutWorstCooldownSec)
      return;

   ulong worstTicket=0;
   double worstProfit=0.0;
   if(!FindWorstBuyPosition(worstTicket, worstProfit))
      return;

   // Safety: only close if truly the worst is negative
   if(worstProfit >= 0.0) return;

   if(ClosePositionByTicket(worstTicket, 0.0, "EA_V6_CUT_WORST"))
   {
      g_last_cut_time = now;
      EnterRecovery(StringFormat("CutWorst closed ticket=%I64u profit=%.2f floatingBuy=%.2f",
                                 (long)worstTicket, worstProfit, bf));
   }
}

double GetSellHedgeFloatingMoney()
{
   // Total floating P/L (profit+swap) for SELL hedge positions of this EA+symbol
   double sum = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_SELL)
         continue;

      double p = PositionGetDouble(POSITION_PROFIT);
      double s = PositionGetDouble(POSITION_SWAP);
      sum += (p + s);
   }
   return sum; // contoh: -5.20 artinya hedge SELL floating minus $5.20
}

void ManageHedgeSellStops()
{
   // Pasang TP/SL, BE, dan trailing untuk posisi hedge SELL supaya tidak menjadi floating minus besar saat reversal
   double pip = PipValue();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_SELL)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      // profit pips for SELL: (open - currentBid) / pip
      double profit_pips = (open - bid) / pip;

      // 1) Baseline TP/SL (only if not set)
      double base_tp = 0.0, base_sl = 0.0;
      if(InpHedgeTP_Pips > 0) base_tp = open - (InpHedgeTP_Pips * pip);
      if(InpHedgeSL_Pips > 0) base_sl = open + (InpHedgeSL_Pips * pip);

      bool need_modify = false;
      double new_sl = sl;
      double new_tp = tp;

      if(tp <= 0.0 && base_tp > 0.0)
      {
         new_tp = base_tp;
         need_modify = true;
      }

      if(sl <= 0.0 && base_sl > 0.0)
      {
         new_sl = base_sl;
         need_modify = true;
      }

      // 2) Break-even for hedge SELL
      if(InpHedgeBE_Trigger_Pips > 0 && profit_pips >= InpHedgeBE_Trigger_Pips)
      {
         double be_sl = open - (InpHedgeBE_Lock_Pips * pip); // lock profit (SL below open for SELL)
         // For SELL, SL should be ABOVE current ask? actually SL is a stop (worse price) above market. be_sl < open.
         // In MT5, SL for SELL must be > Ask? No, SL is above current price for SELL. If be_sl is below market, it's invalid.
         // So we clamp: SL cannot be below current ask; else use trailing section to keep it valid.
         if(be_sl > ask)
         {
            if(sl <= 0.0 || sl > be_sl + (pip * InpHedgeTrail_Step_Pips))
            {
               new_sl = be_sl;
               need_modify = true;
            }
         }
      }

      // 3) Trailing for hedge SELL
      if(InpHedgeTrail_Start_Pips > 0 && profit_pips >= InpHedgeTrail_Start_Pips)
      {
         double trail_sl = bid + (InpHedgeTrail_Dist_Pips * pip); // for SELL, SL above market
         // tighten only (move downwards)?? Actually for SELL, as price falls, trail_sl falls too.
         // SL should decrease (get closer to price) when in profit. So we update if sl is 0 or sl > trail_sl + step.
         double step = InpHedgeTrail_Step_Pips * pip;
         if(sl <= 0.0 || sl > trail_sl + step)
         {
            new_sl = trail_sl;
            need_modify = true;
         }
      }

      if(need_modify)
      {
         m_trade.SetExpertMagicNumber(InpMagicNum);
         m_trade.PositionModify(ticket, new_sl, new_tp);
      }
   }
}


double CloseSellHedgeByVolume(double volToClose)
{
   // Close SELL hedge positions (EA+symbol) by total volume, starting from the newest position.
   if(volToClose <= 0.0)
      return 0.0;

   double closed = 0.0;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   for(int i=PositionsTotal()-1; i>=0 && volToClose > 0.0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_SELL)
         continue;

      double posVol = PositionGetDouble(POSITION_VOLUME);
      if(posVol <= 0.0)
         continue;

      double thisClose = MathMin(posVol, volToClose);
      thisClose = NormalizeVolume(thisClose);

      if(thisClose < vmin)
         continue;

      m_trade.SetExpertMagicNumber(InpMagicNum);

      bool ok = false;
      // Close fully if the remaining volume is effectively the whole position.
      if(thisClose >= posVol - 1e-10)
         ok = m_trade.PositionClose(ticket);
      else
         ok = m_trade.PositionClosePartial(ticket, thisClose);

      if(ok)
      {
         closed += thisClose;
         volToClose -= thisClose;
      }
   }

   return closed;
}




bool GetBullMA2(double &ma0, double &ma1)
{
   // Returns MA current (bar0) and previous (bar1) for bullish add-on filter
   ENUM_MA_METHOD method = InpBullishUseEMA ? MODE_EMA : MODE_SMA;

   // (Re)create handle if settings changed or handle invalid
   if(g_bull_ma_handle == INVALID_HANDLE ||
      g_bull_ma_tf_last != InpBullishTF ||
      g_bull_ma_period_last != InpBullishMAPeriod ||
      g_bull_ma_is_ema_last != InpBullishUseEMA)
   {
      if(g_bull_ma_handle != INVALID_HANDLE)
         IndicatorRelease(g_bull_ma_handle);

      g_bull_ma_handle = iMA(_Symbol, InpBullishTF, InpBullishMAPeriod, 0, method, PRICE_CLOSE);

      g_bull_ma_tf_last = InpBullishTF;
      g_bull_ma_period_last = InpBullishMAPeriod;
      g_bull_ma_is_ema_last = InpBullishUseEMA;
   }

   if(g_bull_ma_handle == INVALID_HANDLE)
      return false;

   double buf[];
   ArrayResize(buf, 2);
   ArraySetAsSeries(buf, true);

   int copied = CopyBuffer(g_bull_ma_handle, 0, 0, 2, buf);
   if(copied < 2)
      return false;

   ma0 = buf[0];
   ma1 = buf[1];
   return true;
}

bool IsBullishConfirmed()
{
   double ma0=0, ma1=0;
   if(!GetBullMA2(ma0, ma1))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Bullish: price above MA and MA sloping up
   return (bid > ma0 && ma0 > ma1);
}

int CountOpenAddonBuys()
{
   int cnt = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      if((long)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "EA_V6_ADDON_BUY") >= 0)
         cnt++;
   }
   return cnt;
}

void TryOpenBullishAddOn()
{
   if(!InpUseBullishAddOn)
      return;

   // Respect global disable state
   if(IsTradingDisabled())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Respect spread/news/rollover pauses to avoid entering in bad conditions
   if(SpreadTooWide(ask, bid))
      return;

   bool dummyClose=false;
   string whyRoll="";
   if(InpUseRolloverGuard && IsRolloverPauseWindow(dummyClose, whyRoll))
      return;

   string whyNews="";
   if(InpUseNewsFilter && IsNewsPauseWindow(whyNews))
      return;

   // Limit number of add-on buys
   if(CountOpenAddonBuys() >= InpBullishMaxOpenAddOns)
      return;

   // Cooldown
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   if(g_last_addon_time > 0 && (now - g_last_addon_time) < InpBullishCooldownSeconds)
      return;

   // Confirm bullish
   if(!IsBullishConfirmed())
      return;

   double vol = (InpBullishAddLot > 0.0 ? InpBullishAddLot : InpLotSize);
   vol = NormalizeVolume(vol);

   // Use same TP logic as normal positions
   double tp = ask + (double)InpTP_Pips * PipValue();

   m_trade.SetExpertMagicNumber(InpMagicNum);
   bool ok = m_trade.Buy(vol, _Symbol, 0.0, 0.0, tp, "EA_V6_ADDON_BUY");
   if(ok)
   {
      g_last_addon_time = now;
      PrintFormat("[EA_V6_AddOn] Opened BUY add-on: vol=%.2f tp=%.5f", vol, tp);
   }
   else
   {
      PrintFormat("[EA_V6_AddOn] FAILED to open add-on BUY. retcode=%d", m_trade.ResultRetcode());
   }
}

//--- internal: hedge partial close cooldown
datetime g_lastHedgePartialClose = 0;

bool CloseSellPositionPartial(ulong ticket, double volume)
{
   if(volume <= 0.0)
      return false;

   if(!PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   long type = (long)PositionGetInteger(POSITION_TYPE);
   if(type != POSITION_TYPE_SELL)
      return false;

   double pos_vol = PositionGetDouble(POSITION_VOLUME);
   if(volume > pos_vol)
      volume = pos_vol;

   // normalize volume to symbol step
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(volume < vmin)
      volume = vmin;
   volume = MathFloor(volume / vstep) * vstep;

   if(volume <= 0.0)
      return false;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_DEAL;
   req.symbol   = _Symbol;
   req.magic    = InpMagicNum;
   req.position = ticket;
   req.volume   = volume;
   req.type     = ORDER_TYPE_BUY; // close SELL by BUY
   req.price    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.deviation= 30;
   req.comment  = "EA_V6_HEDGE_SELL_PCLOSE";

   if(!OrderSend(req, res))
      return false;

   return (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED);
}

void CloseHedgeSellGradually(double totalSellLots)
{
   if(!InpHedgePartialClose)
      return;

   datetime nowt = TimeCurrent();
   if(g_lastHedgePartialClose > 0 && (nowt - g_lastHedgePartialClose) < InpHedgePartialCloseCooldownSec)
      return;

   // compute target volume to close this round
   double vol_to_close = totalSellLots * InpHedgePartialCloseFraction;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(vol_to_close < vmin)
      vol_to_close = vmin;

   // close from newest positions first
   for(int i=PositionsTotal()-1; i>=0 && vol_to_close > 0.0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum) continue;
      long type = (long)PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_SELL) continue;

      double pv = PositionGetDouble(POSITION_VOLUME);
      double chunk = (pv <= vol_to_close ? pv : vol_to_close);

      // if chunk equals full volume, use PositionClose for simplicity; else use partial close
      if(MathAbs(chunk - pv) < 1e-9)
      {
         m_trade.PositionClose(ticket);
         vol_to_close -= pv;
      }
      else
      {
         if(CloseSellPositionPartial(ticket, chunk))
            vol_to_close -= chunk;
         else
         {
            // fallback: if partial close fails, try full close only when chunk >= pv (not the case here)
         }
      }
   }

   g_lastHedgePartialClose = nowt;
}


void ManageBearishHedge(bool paused, const string &pauseWhy)
{
   if(!InpUseBearishHedge)
      return;

   // Avoid hedging during news/rollover windows (high slippage/spread) or when spread too wide
   if(SpreadTooWide(SymbolInfoDouble(_Symbol, SYMBOL_ASK), SymbolInfoDouble(_Symbol, SYMBOL_BID)))
      return;

   bool dummyClose=false;
   string tmp="";
   if(IsRolloverPauseWindow(dummyClose, tmp))
      return;

   string tmp2="";
   if(IsNewsPauseWindow(tmp2))
      return;

   // If XAU no-hold is enabled and currently paused, positions will be closed anyway
   if(paused && InpXAU_NoHoldPolicy && IsXAUInstrument())
      return;
   // Manage TP/SL/BE/Trailing untuk hedge SELL yang sudah terbuka
   ManageHedgeSellStops();

   // Trigger hedge (dengan konfirmasi bearish agar tidak menambah SELL saat harga sudah rebound)
   bool hedgeOn = false;
   bool bearishNow = IsBearishNow();
   double buyFloat = 0.0;

   if(InpHedgeTriggerByFloating)
   {
      // gunakan floating minus dari basket BUY
      buyFloat = GetBuyFloatingMoney();

      // hedge hanya aktif kalau: floating BUY sudah minus threshold DAN kondisi bearish masih valid
      if(buyFloat <= -InpHedgeStartLossMoney && bearishNow)
         hedgeOn = true;
   }
   else
   {
      // legacy: pakai sinyal bearish MA saja
      hedgeOn = bearishNow;
   }

   // compute total BUY lots and existing SELL hedge lots for this EA+symbol
   double buyLots=0.0, sellLots=0.0, sellOpenSum=0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long mg = (long)PositionGetInteger(POSITION_MAGIC);
      if(mg != InpMagicNum)
         continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY)  buyLots  += vol;
      if(type == POSITION_TYPE_SELL) { sellLots += vol; sellOpenSum += PositionGetDouble(POSITION_PRICE_OPEN) * vol; }
   }

   
   double sellAvgOpen = (sellLots > 0.0 ? (sellOpenSum / sellLots) : 0.0);
// If no BUY exposure left, close hedge SELL (if any) then return
   if(buyLots <= 0.0)
   {
      if(sellLots > 0.0)
      {
         for(int i=PositionsTotal()-1; i>=0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket))
               continue;

            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
               continue;

            long mg = (long)PositionGetInteger(POSITION_MAGIC);
            if(mg != InpMagicNum)
               continue;

            long type = (long)PositionGetInteger(POSITION_TYPE);
            if(type != POSITION_TYPE_SELL)
               continue;

            m_trade.PositionClose(ticket);
         }
      }
      return;
   }

   // Target hedge size
   double targetSellRaw = buyLots * InpHedgeRatio;

// Optional: step hedge scaling based on floating BUY loss (money)
// This adds extra hedge volume in steps as floating loss deepens, while still respecting HedgeMaxLot.
if(InpHedgeTriggerByFloating && InpHedgeUseStep)
{
   // buyFloat is negative when loss. Convert to positive drawdown.
   double dd = -buyFloat;
   if(dd > InpHedgeStartLossMoney && InpHedgeStepLossMoney > 0.0)
   {
      int steps = (int)MathFloor((dd - InpHedgeStartLossMoney) / InpHedgeStepLossMoney);
      if(steps > 0 && InpHedgeStepLot > 0.0)
         targetSellRaw += steps * InpHedgeStepLot;
   }
}

double targetSell = MathMin(InpHedgeMaxLot, targetSellRaw);

   // CUT-LOSS hedge saat reversal: jika harga bergerak melawan SELL (naik) dan BUY basket sudah mulai pulih,
   // jangan biarkan hedge menjadi floating minus besar.
   if(sellLots > 0.0 && InpHedgeMaxAdverse_Pips > 0)
   {
      double pip = PipValue();
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double adverse_pips = (bid - sellAvgOpen) / pip; // >0 artinya rugi untuk SELL

      // Syarat: (1) rugi hedge sudah lewat batas pips, (2) floating BUY sudah pulih mendekati normal
      double bf = GetBuyFloatingMoney();
      if(adverse_pips >= InpHedgeMaxAdverse_Pips && bf >= -InpHedgeCloseRecoveryMoney)
      {
         // close semua hedge (atau sebagian jika partial aktif)
         if(!InpHedgePartialClose)
            CloseSellHedgeByVolume(sellLots);
         else
            CloseHedgeSellGradually(sellLots);

         return;
      }
   }

   // Partial close / rebalance state
   static datetime s_lastHedgeClose = 0;
   datetime now = TimeCurrent();
   bool cooldown_ok = (InpHedgePartialCloseCooldownSec <= 0) || (now - s_lastHedgeClose >= InpHedgePartialCloseCooldownSec);

   if(hedgeOn)
   {
      // Adjust hedge toward target (open if below; trim if above)
      double diff = targetSell - sellLots;

      if(diff >= InpHedgeMinLot)
      {
         // Need more hedge
         double vol = NormalizeVolume(diff);
         if(vol < InpHedgeMinLot) vol = InpHedgeMinLot;

         m_trade.SetExpertMagicNumber(InpMagicNum);
         m_trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, "EA_V6_HEDGE_SELL");
      }
      else if(diff <= -InpHedgeMinLot)
      {
         // Rebalance: too much hedge (usually because BUY lots decreased after some TP/BE closes,
         // or step target reduced as floating loss improved). Trim excess even if floating has not recovered.
         if(!InpHedgePartialClose || cooldown_ok)
         {
            double excess = -diff;
            double closeVol = excess;

            if(InpHedgePartialClose)
               closeVol = MathMin(excess, sellLots * InpHedgePartialCloseFraction);

            closeVol = NormalizeVolume(closeVol);
            if(closeVol >= InpHedgeMinLot)
            {
               double closed = CloseSellHedgeByVolume(closeVol);
               if(closed > 0.0)
                  s_lastHedgeClose = now;
            }
         }
      }
   }
   else
   {
      // Close hedge condition:
      // - legacy mode: close ketika sinyal bearish hilang
      // - floating mode: close lebih cepat saat trend sudah tidak bearish + BUY basket mulai pulih,
      //                  sehingga hedge SELL tidak sempat berubah jadi floating minus besar.
      bool canClose = false;

      if(!InpHedgeTriggerByFloating)
      {
         // legacy: cukup berdasarkan trend flip
         if(!bearishNow) canClose = true;
      }
      else
      {
         buyFloat = GetBuyFloatingMoney();

         // 1) kondisi normal (hysteresis)
         if(buyFloat >= -InpHedgeStopLossMoney)
            canClose = true;

         // 2) close lebih awal saat sudah tidak bearish + BUY mulai recover
         if(!canClose && !bearishNow && buyFloat >= -InpHedgeCloseRecoveryMoney)
            canClose = true;
      }

      if(InpHedgeCloseWhenNotBearish && sellLots > 0.0 && canClose)
      {
         if(!InpHedgePartialClose)
         {
            // Close all at once
            CloseSellHedgeByVolume(sellLots);
         }
         else if(cooldown_ok)
         {
            // Close in chunks
            double closeVol = sellLots * InpHedgePartialCloseFraction;
            closeVol = NormalizeVolume(closeVol);
            if(closeVol < InpHedgeMinLot) closeVol = InpHedgeMinLot;
            if(closeVol > sellLots) closeVol = sellLots;

            double closed = CloseSellHedgeByVolume(closeVol);
            if(closed > 0.0)
               s_lastHedgeClose = now;
         }
      }
   }
}

int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNum);
   m_trade.SetDeviationInPoints(100);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Setup Nama Variabel Memori
   gv_anchor_name   = "EA_V6_Anchor_" + Symbol();
   gv_max_up_name   = "EA_V6_MaxUp_" + Symbol();
   gv_max_down_name = "EA_V6_MaxDown_" + Symbol();
   gv_disabled_name = "EA_V6_Disabled_" + Symbol() + "_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));
   gv_peak_equity_name  = "EA_V6_PeakEq_"  + Symbol() + "_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));
   gv_start_equity_name = "EA_V6_StartEq_" + Symbol() + "_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));

   double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point        = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(point == 0) return(INIT_FAILED);

   // Init disabled flag + equity baselines (persist across restarts)
   if(!GlobalVariableCheck(gv_disabled_name))
      GlobalVariableSet(gv_disabled_name, 0.0);

   double eq_now  = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal_now = AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq_now <= 0.0) eq_now = bal_now;

   // Start equity baseline (DD from start)
   if(GlobalVariableCheck(gv_start_equity_name))
      g_start_equity = GlobalVariableGet(gv_start_equity_name);
   else
   {
      g_start_equity = eq_now;
      GlobalVariableSet(gv_start_equity_name, g_start_equity);
   }

   // Peak equity baseline (DD from peak)
   if(GlobalVariableCheck(gv_peak_equity_name))
      g_peak_equity = GlobalVariableGet(gv_peak_equity_name);
   else
   {
      g_peak_equity = eq_now;
      GlobalVariableSet(gv_peak_equity_name, g_peak_equity);
   }

   if(eq_now > g_peak_equity)
   {
      g_peak_equity = eq_now;
      GlobalVariableSet(gv_peak_equity_name, g_peak_equity);
   }
// --- LOGIKA SMART RESET ---
   if(!GlobalVariableCheck(gv_anchor_name))
   {
      GlobalVariableSet(gv_anchor_name, currentPrice);
      GlobalVariableSet(gv_max_up_name, InpBatchSize);
      GlobalVariableSet(gv_max_down_name, InpBatchSize);
   }
   else
   {
      double oldAnchor = GlobalVariableGet(gv_anchor_name);
      if(MathAbs(currentPrice - oldAnchor) > 5000 * point)
      {
         GlobalVariableSet(gv_anchor_name, currentPrice);
         GlobalVariableSet(gv_max_up_name, InpBatchSize);
         GlobalVariableSet(gv_max_down_name, InpBatchSize);
      }
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hedge_ma_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_hedge_ma_handle);
      g_hedge_ma_handle = INVALID_HANDLE;
   }


if(g_bull_ma_handle != INVALID_HANDLE)
   IndicatorRelease(g_bull_ma_handle);

}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;

   // 1) Manajemen posisi selalu jalan (TP/BE/Trailing), walau grid sedang pause
   ManagePositions();
   SyncPendingOrdersTP();

   // 2) Update peak equity (for DD guard / basket stop)
   double equity_now = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = equity_now;
   if(equity_now > g_peak_equity)
      g_peak_equity = equity_now;

   // 3) If trading disabled (e.g., after DD guard), do nothing else
   if(IsTradingDisabled())
   {
      // Optional: show cooldown remaining (anti-spam: once per 60s)
      if(InpDDCooldownMinutes > 0 && GlobalVariableCheck(gv_disabled_name))
      {
         double v = GlobalVariableGet(gv_disabled_name);
         datetime now = NowTime();
         datetime until = (datetime)v;

         if(until > 100000 && now < until)
         {
            if(g_last_pause_log == 0 || (now - g_last_pause_log) >= 60)
            {
               int mins_left = (int)MathCeil((double)(until - now) / 60.0);
               PrintFormat("[EA_V6_Pause] DD cooldown active (%d min left). Grid placement paused.", mins_left);
               g_last_pause_log = now;
            }
         }
      }
      return;
   }

   // 4) Safety close BEFORE DD guard (mencegah tail loss / stop-out)
   string bsWhy="";
   if(CheckBasketStop(bsWhy))
      return;

   // 5) Hard guard: Equity/DD (close & stop)
   string ddWhy="";
   if(CheckEquityDDGuard(ddWhy))
      return;

   // 6) High-risk pause condition (rollover/spread/news) untuk STOP pasang pending order
   bool paused=false;
   string why="";

   // 6a) Rollover window (00:00 server)
   bool doCloseRollover=false;
   string rollWhy="";
   if(InpUseRolloverGuard && IsRolloverPauseWindow(doCloseRollover, rollWhy))
   {
      paused=true;
      why = rollWhy;

      if(doCloseRollover)
      {
         // Close positions + delete pendings before rollover
         CloseAllPositionsOfEA();
         DeletePendingOrdersOfEA();
      }
   }

   if(SpreadTooWide(ask, bid))
   {
      paused=true;
      why = StringFormat("Spread too wide (%.1f pips > %d pips)",
                         (ask-bid)/PipValue(), InpMaxSpreadPips);
   }

   string whyNews="";
   if(!paused && IsNewsPauseWindow(whyNews))
   {
      paused=true;
      why = whyNews;
   }

   // 6b) Hedge management always runs (it has its own anti-news/rollover checks)
   ManageBearishHedge(paused, why);

   if(paused)
   {
      // Special: no-hold policy for XAU* (close positions + delete pendings when paused)
      bool isXAU = (InpXAU_NoHoldPolicy && IsXAUInstrument());
      if(isXAU)
      {
         DeletePendingOrdersOfEA();
         CloseAllPositionsOfEA();
      }
      else
      {
         // optional delete pendings
         if(InpDeletePendingsDuringPause)
            DeletePendingOrdersOfEA();
      }

      // anti-spam log: once per minute
      datetime now = NowTime();
      if(now - g_last_pause_log >= 60)
      {
         PrintFormat("[EA_V6_Pause] %s. Grid placement paused.", why);
         g_last_pause_log = now;
      }
      return;
   }

   // 7) Tail-loss control: cut worst BUY bertahap + masuk recovery mode
   ManageCutWorst();

   // 8) Grid pause: Recovery / TrendLock / Exposure caps
   bool gridPaused=false;
   string gridWhy="";

   int mins_left=0;
   if(IsRecoveryActive(mins_left))
   {
      gridPaused=true;
      gridWhy = StringFormat("Recovery cooldown (%d min left)", mins_left);
   }

   if(!gridPaused && InpUseTrendLock && IsBearishNow())
   {
      gridPaused=true;
      gridWhy = "TrendLock bearish (price<MA & MA down)";
   }

   // Exposure caps (untuk akun kecil $100)
   if(!gridPaused)
   {
      if(InpMaxOpenBuyPositions > 0 && CountEABuyPositions() >= InpMaxOpenBuyPositions)
      {
         gridPaused=true;
         gridWhy = StringFormat("Exposure cap: open BUY positions >= %d", InpMaxOpenBuyPositions);
      }

      if(!gridPaused && InpMaxTotalBuyLots > 0.0)
      {
         double buyLots = SumEABuyLots();
         if(buyLots >= (InpMaxTotalBuyLots - 1e-9))
         {
            gridPaused=true;
            gridWhy = StringFormat("Exposure cap: BUY lots %.2f >= %.2f", buyLots, InpMaxTotalBuyLots);
         }
      }

      if(!gridPaused && InpMaxPendingTotal > 0)
      {
         int ptotal = CountEAPendingTotal();
         if(ptotal >= InpMaxPendingTotal)
         {
            gridPaused=true;
            gridWhy = StringFormat("Exposure cap: pending orders %d >= %d", ptotal, InpMaxPendingTotal);
         }
      }
   }

   if(gridPaused)
   {
      if(InpTrendLockDeletePendings)
         DeletePendingOrdersOfEA();

      datetime now = NowTime();
      if(g_last_grid_pause_log == 0 || (now - g_last_grid_pause_log) >= 60)
      {
         PrintFormat("[EA_V6_GridPause] %s. Grid placement paused.", gridWhy);
         g_last_grid_pause_log = now;
      }
      return;
   }

   // 9) Grid placement
   double anchorPrice = GlobalVariableGet(gv_anchor_name);
   int maxUp          = (int)GlobalVariableGet(gv_max_up_name);
   int maxDown        = (int)GlobalVariableGet(gv_max_down_name);

   if(anchorPrice <= 0.0)
      anchorPrice = ask;

   // Kalkulasi spread untuk jarak aman pending order
   double spread = ask - bid;
   double minGap = spread * 2; // safety gap

   int pendingTotal = CountEAPendingTotal();

   // Loop untuk buat order grid
   for(int i=-maxDown; i<=maxUp; i++)
   {
      if(i==0) continue;

      if(InpMaxPendingTotal > 0 && pendingTotal >= InpMaxPendingTotal)
         break;

      double targetPrice = anchorPrice + (i * InpDistance * point);
      targetPrice = NormalizeDouble(targetPrice, _Digits);

      if(!IsSlotEmpty(targetPrice))
         continue;

      // Batasi agar tidak jauh banget dari harga berjalan
      if(MathAbs(targetPrice - ask) > (InpDistance * 60 * point))
         continue;

      // TP
      double pip = PipValue();
      double tp  = NormalizeDouble(targetPrice + (InpTP_Pips * pip), _Digits);

      bool placed=false;
      if(targetPrice > (ask + minGap))
      {
         // Buy Stop
         placed = m_trade.BuyStop(InpLotSize, targetPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "EA_V6_BuyStop_TP");
      }
      else if(targetPrice < (bid - minGap))
      {
         // Buy Limit
         placed = m_trade.BuyLimit(InpLotSize, targetPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "EA_V6_BuyLimit_TP");
      }

      if(placed)
         pendingTotal++;
   }

   // --- CEK REFILL/EKSPANSI (capped) ---
   int buyStopCount  = CountPendingOrders(ORDER_TYPE_BUY_STOP);
   int buyLimitCount = CountPendingOrders(ORDER_TYPE_BUY_LIMIT);

   if(InpMaxPendingTotal > 0)
   {
      int maxSide = (int)MathMax(InpBatchSize, InpMaxPendingTotal/2);

      if(buyStopCount < 5 && maxUp < maxSide && CountEAPendingTotal() < InpMaxPendingTotal)
      {
         maxUp = (int)MathMin(maxUp + InpBatchSize, maxSide);
         GlobalVariableSet(gv_max_up_name, maxUp);
      }
      if(buyLimitCount < 5 && maxDown < maxSide && CountEAPendingTotal() < InpMaxPendingTotal)
      {
         maxDown = (int)MathMin(maxDown + InpBatchSize, maxSide);
         GlobalVariableSet(gv_max_down_name, maxDown);
      }
   }
   else
   {
      // original behavior
      if(buyStopCount < 5)
      {
         maxUp += InpBatchSize;
         GlobalVariableSet(gv_max_up_name, maxUp);
      }
      if(buyLimitCount < 5)
      {
         maxDown += InpBatchSize;
         GlobalVariableSet(gv_max_down_name, maxDown);
      }
   }
}


void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(sym != _Symbol)
      return;

   long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(magic != InpMagicNum)
      return;

   long entry = (long)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN)
      return;

   long dtype = (long)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype != DEAL_TYPE_BUY)
      return;

   string cmt = HistoryDealGetString(trans.deal, DEAL_COMMENT);

   // Anti-loop: add-on should not trigger another add-on
   if(StringFind(cmt, "EA_V6_ADDON_BUY") >= 0)
      return;

   // After a BUY opens, if bullish is confirmed, open a small add-on BUY
   TryOpenBullishAddOn();
}



//+------------------------------------------------------------------+
//| Cek apakah di sekitar harga itu sudah ada pending / posisi        |
//+------------------------------------------------------------------+
bool IsSlotEmpty(double price)
{
   double tolerance = InpDistance * _Point * 0.2;

   // cek orders
   for(int i=0; i<OrdersTotal(); i++)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket==0) continue;
      if(!OrderSelect(oticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNum)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - price) < tolerance)
         return false;
   }

   // cek positions
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      double pp = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(pp - price) < tolerance)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Hitung pending order EA by type                                  |
//+------------------------------------------------------------------+
int CountPendingOrders(ENUM_ORDER_TYPE type)
{
   int count=0;
   for(int i=0; i<OrdersTotal(); i++)
   {
      ulong oticket = OrderGetTicket(i);
      if(oticket==0) continue;
      if(!OrderSelect(oticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((int)OrderGetInteger(ORDER_MAGIC) != InpMagicNum)
         continue;

      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
         count++;
   }
   return count;
}
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "7.15"
#property strict

#include <Trade/Trade.mqh>

//============================================================
//  EA: XAU Buy-Grid + Floating-Loss Hedge (SELL) + Adaptive ATR
//  Fokus perbaikan:
//   1) SELL hedge diberi TP + BE + trailing (opsional)
//   2) Hedge bisa di-trim (reduce) ke target saat BUY lots berkurang / DD membaik
//   3) Hedge bisa dipaksa close ketika basket BUY sudah profit (agar hedge tidak drag profit)
//   4) Grid distance bisa adaptif pakai ATR (opsional)
//============================================================

//--- INPUT (GRID)
input double InpLotSize    = 0.01;   // Lot Size
input int    InpDistance   = 2000;   // Jarak Grid (points) (mode FIXED)
input int    InpBatchSize  = 30;     // Jumlah Layer (N atas & N bawah)
input int    InpMagicNum   = 12345;  // Magic Number

//--- INPUT (ADAPTIVE GRID - ATR)
input bool            InpUseATRGridDistance  = false;     // Pakai ATR untuk jarak grid (lebih adaptif XAU)
input ENUM_TIMEFRAMES InpATRGridTF          = PERIOD_M15; // TF ATR
input int             InpATRGridPeriod      = 14;         // Periode ATR
input double          InpATRGridMultiplier  = 1.0;        // Mult ATR -> jarak grid
input int             InpATRGridMinPoints   = 500;        // Min jarak grid (points) ketika ATR mode
input int             InpATRGridMaxPoints   = 20000;      // Max jarak grid (points) ketika ATR mode

//--- INPUT (AUTO RECENTER GRID)
input bool   InpAutoRecenterWhenFlat     = true;  // Recenter anchor ketika tidak ada posisi (lebih adaptif)
input int    InpRecenterDistancePoints   = 5000;  // Recenter jika jarak dari anchor > ini (points) dan sedang flat

//--- INPUT (RISK/EXIT BUY)
input int    InpTP_Pips          = 1500; // Take Profit per posisi BUY (pips)
input int    InpBE_Trigger_Pips  = 150;  // Profit (pips) untuk set SL ke BE
input int    InpBE_Lock_Pips     = 1;    // Tambahan pips di atas BE
input int    InpTrail_Start_Pips = 155;  // Mulai trailing setelah profit (pips)
input int    InpTrail_Dist_Pips  = 50;   // Jarak trailing (pips)
input int    InpTrail_Step_Pips  = 5;    // Step minimal perubahan SL (pips)

//--- INPUT (FILTERS)
input bool   InpUseSpreadFilter  = true; // Stop pas spread melebar
input int    InpMaxSpreadPips    = 30;   // Maks spread (pips)
input int    InpSpreadConfirmSeconds = 10; // Spread harus wide selama N detik sebelum pause (anti flapping). 0=instan
input int    InpSpreadResumePips      = 25; // Resume jika spread <= ini (pips). Harus < InpMaxSpreadPips agar tidak flapping

// XAU no-hold refinement: saat pause karena SPREAD, defaultnya JANGAN close posisi & JANGAN hapus pending
input bool   InpXAU_CloseOnSpreadPause        = false; // Close posisi jika pause karena spread
input bool   InpXAU_DeletePendingsOnSpreadPause = true;  // Hapus pending jika pause karena spread (hindari fill saat spread ekstrem)

input bool   InpUseNewsFilter           = false;                 // Stop pas news (Economic Calendar MT5)
input int    InpNewsMinutesBefore       = 30;                    // Berhenti X menit sebelum news
input int    InpNewsMinutesAfter        = 30;                    // Berhenti X menit setelah news
input ENUM_CALENDAR_EVENT_IMPORTANCE InpMinNewsImportance = CALENDAR_IMPORTANCE_HIGH; // Min importance
input bool   InpIncludeHolidays         = false;                 // Pause saat holiday event
input string InpNewsCurrencies          = "AUTO";                // "AUTO" (base+quote) atau "USD,EUR,..."
input bool   InpDeletePendingsDuringPause = false;               // Hapus pending order EA saat pause

//--- INPUT (ROLLOVER / RISK GUARDS)
input bool   InpUseRolloverGuard       = true;  // Close & pause menjelang rollover (00:00 server)
input int    InpRolloverMinutesBefore  = 10;    // Tutup posisi X menit sebelum 00:00 server
input int    InpRolloverMinutesAfter   = 5;     // Pause X menit setelah 00:00 server

input bool   InpUseEquityDDGuard       = true;  // Equity/DD guard (close & stop)
input double InpMaxDDPercentFromPeak   = 30.0;  // Max DD % dari peak equity (0=off)
input double InpMaxDDMoney             = 0.0;   // Max DD money dari peak equity (0=off)
input bool   InpDisableAfterDD         = true;  // Setelah DD trigger, stop pasang order
input int    InpDDCooldownMinutes      = 30;    // Jika >0: mulai lagi setelah N menit (0=butuh restart)

//--- INPUT (XAU NO-HOLD)
input bool   InpXAU_NoHoldPolicy       = true;  // Jika XAU*, saat pause (rollover/news) -> close posisi + hapus pending (spread pause bisa diatur terpisah)

//--- INPUT (BEARISH HEDGE - SELL)
input bool   InpUseBearishHedge         = false; // buka SELL hedge kecil saat bearish (akun hedging)
input bool   InpHedgeTriggerByFloating  = true;  // hedge berdasarkan floating BUY minus, false=pakai sinyal bearish MA

// MA bearish filter (jika TriggerByFloating=false)
input ENUM_TIMEFRAMES InpHedgeTF        = PERIOD_M15;
input int    InpHedgeMAPeriod           = 200;
input bool   InpHedgeUseEMA             = true; 

// Sizing
input double InpHedgeRatio              = 0.60; // porsi hedge vs total BUY lots
input double InpHedgeMaxLot             = 0.30; // maksimum lot hedge total
input double InpHedgeMinLot             = 0.01; // minimum lot hedge sekali entry
input bool   InpHedgeUseStep            = true; // tambah hedge bertahap per floating loss step (hanya jika TriggerByFloating=true)
input double InpHedgeStartLossMoney     = 15.0; // mulai hedge jika floating BUY <= -nilai ini
input double InpHedgeStopLossMoney      = 8.0;  // tutup hedge jika floating BUY >= -nilai ini
input double InpHedgeStepLossMoney      = 10.0; // setiap tambahan rugi sebesar ini, target hedge ditambah
input double InpHedgeStepLot            = 0.01; // tambahan lot hedge per step
input bool   InpHedgeCloseWhenNotBearish= true; // Tutup hedge saat kondisi hedge-off (tidak bearish / floating pulih)

// Perbaikan utama: manajemen TP/SL/trailing untuk SELL hedge
input bool   InpHedgeManageSLTP         = true;  // aktifkan pengaturan TP/BE/Trailing untuk posisi SELL hedge
input int    InpHedgeTP_Pips            = 800;   // TP posisi SELL hedge (pips) - agar profit tidak balik jadi minus
input int    InpHedgeBE_Trigger_Pips    = 120;   // Profit (pips) untuk set SL ke BE (SELL)
input int    InpHedgeBE_Lock_Pips       = 1;     // Lock pips setelah BE (SELL)
input int    InpHedgeTrail_Start_Pips   = 150;   // Mulai trailing (SELL)
input int    InpHedgeTrail_Dist_Pips    = 40;    // Jarak trailing (SELL)
input int    InpHedgeTrail_Step_Pips    = 5;     // Step trailing (SELL)

// NEW: Money-based TP untuk SELL hedge (rolling hedge)
input bool   InpHedgeUseMoneyTP              = true;  // TP hedge berdasarkan profit money per posisi
input double InpHedgeTakeProfitMoney         = 2.0;   // TP money per posisi SELL hedge (>=) untuk close & lock profit
input bool   InpHedgeReopenAfterMoneyTP      = true;  // Setelah TP money, buka SELL hedge pengganti (jika hedge masih ON)
input int    InpHedgeMoneyTPCheckSeconds     = 2;     // Interval cek TP money (detik)

// Money trailing untuk hedge basket (agar hedge tidak balik jadi minus setelah sempat plus)
input bool   InpHedgeUseMoneyTrail              = true; // aktifkan trailing profit money (basket)
input double InpHedgeMoneyTrailStartMoney       = 1.0;  // mulai tracking saat profit hedge >= ini
input double InpHedgeMoneyTrailLockMoney        = 0.10; // jika profit hedge turun sampai <= ini, close hedge (lock profit)
input double InpHedgeMoneyTrailDropFromPeak     = 1.0;  // close jika drop dari peak >= ini (0=off)

// Pause BUY grid saat hedge aktif & DD sudah cukup besar (untuk tahan floating)
input bool   InpPauseBuyWhenHedge               = true; // stop tambah BUY saat hedge aktif
input double InpPauseBuyWhenHedgeDDMoney        = 15.0; // aktif jika buy floating <= -nilai ini
input bool   InpPauseBuyDeletePendings          = true; // hapus pending BUY saat pause-by-hedge

// Saat BUY sudah profit, close hedge hanya jika hedge basket minimal profit segini
input double InpHedgeCloseOnBuyProfitMinHedgeProfitMoney = 0.10;
input double InpHedgeCloseOnBuyProfitMinNetMoney = 0.50; // minimal profit NET (BUY+HEDGE) untuk force close hedge saat BUY sudah profit

// NEW: Force close SELL hedge segera ketika total BUY sudah profit (agar hedge tidak sempat jadi minus)
input bool   InpHedgeForceCloseOnBuyProfit   = true;  // Bypass confirm/interval untuk close SELL hedge saat BUY float >= ambang

// Perbaikan utama: hedge tidak boleh drag profit saat BUY basket sudah profit
input bool   InpHedgeCloseOnBuyProfit       = true; // Force close SELL hedge saat total floating BUY sudah profit
input double InpHedgeCloseOnBuyProfitMoney  = 0.0;  // Ambang profit BUY (money). 0=ketika BUY float >= 0

// Perbaikan utama: trim hedge saat over-hedge (misal BUY sudah banyak TP sehingga buyLots turun)
input bool   InpHedgeReduceToTarget     = true;  // jika sellLots > target -> kurangi (close sebagian) agar sesuai target

// Anti-whipsaw (stabilisasi hedge agar tidak open/close cepat yang membuat SELL minus dari spread)
input int    InpHedgeCheckIntervalSeconds     = 5;    // interval cek hedge (detik)
input int    InpHedgeOpenConfirmSeconds       = 30;   // syarat open harus bertahan N detik
input int    InpHedgeCloseConfirmSeconds      = 30;   // syarat close harus bertahan N detik
input int    InpHedgeMinHoldSeconds           = 60;   // minimal hedge aktif sebelum boleh close
input int    InpHedgeReopenCooldownSeconds    = 300;  // cooldown sebelum hedge boleh open lagi setelah close
input int    InpHedgeAddCooldownSeconds       = 20;   // cooldown penambahan lot hedge
input double InpHedgeMaxLotPerOrder         = 0.01; // maksimum lot per 1 order SELL hedge
input bool   InpHedgeRequireBearishForFloating= true; // jika trigger floating, tetap minta bearish filter agar tidak whipsaw
input double InpHedgeRebalanceMinDeltaLot     = 0.02; // minimal selisih lot untuk trim (hindari micro-trim)

// Hard SL untuk SELL hedge sejak awal (0=off). Menghindari loss besar saat harga rebound kuat.
input int    InpHedgeSL_Pips                  = 700;  // SL SELL hedge (pips)

// Saat close hedge, defaultnya jangan close posisi SELL yang masih rugi besar (hindari lock-loss karena spread)
input bool   InpHedgeCloseOnlyIfSmallLoss     = true;
input double InpHedgeCloseMaxLossPerPosMoney  = 0.60; // boleh close jika profit >= -nilai ini

//--- INPUT (BULLISH ADD-ON - OPTIONAL)
input bool            InpUseBullishAddOn        = false;        // setelah ada BUY baru, jika bullish terkonfirmasi buka BUY tambahan
input ENUM_TIMEFRAMES InpBullishTF             = PERIOD_M15;
input int             InpBullishMAPeriod        = 200;
input bool            InpBullishUseEMA          = true;         // true=EMA, false=SMA
input double          InpBullishAddLot          = 0.0;          // 0=pakai InpLotSize
input int             InpBullishCooldownSeconds = 60;           // jeda minimal antar add-on (detik)
input int             InpBullishMaxOpenAddOns   = 1;            // maksimum posisi add-on BUY yang boleh terbuka

//============================================================
// GLOBAL
//============================================================
CTrade m_trade;

string gv_anchor_name;
string gv_max_up_name;
string gv_max_down_name;
string gv_disabled_name;

static double   g_peak_equity = 0.0;
static datetime g_last_addon_time = 0;
static datetime g_last_rollover_close_for = 0;
static datetime g_last_pause_log = 0;
static bool     g_pause_buy_by_hedge = false;

enum EPauseReason
{
   PAUSE_NONE    = 0,
   PAUSE_ROLLOVER= 1,
   PAUSE_SPREAD  = 2,
   PAUSE_NEWS    = 3
};

static bool     g_spread_paused     = false;
static datetime g_spread_wide_since = 0;

// Indicator handles

int g_hedge_ma_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_hedge_ma_tf_last = PERIOD_CURRENT;
int g_hedge_ma_period_last = -1;
bool g_hedge_ma_is_ema_last = true;

int g_bull_ma_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_bull_ma_tf_last = PERIOD_CURRENT;
int g_bull_ma_period_last = -1;
bool g_bull_ma_is_ema_last = true;

int g_atr_handle = INVALID_HANDLE;
ENUM_TIMEFRAMES g_atr_tf_last = PERIOD_CURRENT;
int g_atr_period_last = -1;

//============================================================
// UTILS
//============================================================

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
   StringReplace(cleaned, ";", ",");
   int n = StringSplit(cleaned, ',', arr);
   for(int i=0;i<n;i++) arr[i] = Trim(arr[i]);
   return n;
}

// Extract first 6 alphabetic chars from symbol (ignoring suffix/prefix like "m", ".pro", "_ecn", etc)
string SymbolCore6(const string sym)
{
   string up = sym;
   StringToUpper(up);
   string out = "";
   int len = StringLen(up);
   for(int i=0; i<len; i++)
   {
      ushort ch = StringGetCharacter(up, i);
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
      string core = SymbolCore6(_Symbol);
      if(StringLen(core) == 6)
      {
         string base  = StringSubstr(core, 0, 3);
         string quote = StringSubstr(core, 3, 3);

         if(IsKnownCurrency(base))  AddUnique(outArr, base);
         if(IsKnownCurrency(quote)) AddUnique(outArr, quote);
         return (int)ArraySize(outArr);
      }
      return 0;
   }

   string tmp[];
   int n = SplitCSV(mode, tmp);
   if(n <= 0) return 0;

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
   double max_points = (InpMaxSpreadPips * pip) / _Point; // pips -> points
   if(max_points <= 0) return false;

   return (spread_points > max_points);
}

bool IsSpreadPause(double ask, double bid, string &why)
{
   why = "";
   if(!InpUseSpreadFilter) return false;

   double pip = PipValue();
   if(pip <= 0) return false;

   double spreadPips = (ask - bid) / pip;
   int pausePips  = InpMaxSpreadPips;
   int resumePips = (InpSpreadResumePips > 0 ? InpSpreadResumePips : InpMaxSpreadPips);
   if(resumePips > pausePips) resumePips = pausePips;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   // Saat sedang pause, tunggu sampai spread <= resume threshold
   if(g_spread_paused)
   {
      if(spreadPips <= (double)resumePips)
      {
         g_spread_paused = false;
         g_spread_wide_since = 0;
         return false;
      }

      why = StringFormat("Spread pause (%.1f pips > %d pips)", spreadPips, pausePips);
      return true;
   }

   // Belum pause: butuh konfirmasi beberapa detik (optional)
   if(spreadPips > (double)pausePips)
   {
      if(InpSpreadConfirmSeconds <= 0)
      {
         g_spread_paused = true;
         why = StringFormat("Spread pause (%.1f pips > %d pips)", spreadPips, pausePips);
         return true;
      }

      if(g_spread_wide_since == 0)
         g_spread_wide_since = now;

      if((now - g_spread_wide_since) >= InpSpreadConfirmSeconds)
      {
         g_spread_paused = true;
         why = StringFormat("Spread pause (%.1f pips > %d pips for %d sec)",
                            spreadPips, pausePips, InpSpreadConfirmSeconds);
         return true;
      }

      // belum confirmed
      return false;
   }

   // spread normal -> reset timer
   g_spread_wide_since = 0;
   return false;
}

bool IsNewsPauseWindow(string &why)

{
   why = "";
   if(!InpUseNewsFilter) return false;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   datetime from = now - (InpNewsMinutesAfter * 60);
   datetime to   = now + (InpNewsMinutesBefore * 60);

   string ccy[];
   int ccy_n = GetCurrenciesForFilter(ccy);

   if(ccy_n <= 0)
   {
      ArrayResize(ccy, 1);
      ccy[0] = "";
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

//============================================================
// VOLUME + POSITION HELPERS
//============================================================

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
   if(out < minv) out = minv;
   return out;
}

bool ClosePositionVolume(ulong ticket, double volume)
{
   if(ticket == 0) return false;
   if(volume <= 0) return false;

   if(!PositionSelectByTicket(ticket))
      return false;

   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;

   if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
      return false;

   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double posVol = PositionGetDouble(POSITION_VOLUME);
   if(posVol <= 0.0) return false;

   // normalize close volume
   double vol = NormalizeVolume(volume);
   if(vol > posVol) vol = posVol;

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
   if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("[EA_V7_CloseVol] Failed close pos %I64u vol=%.2f ret=%d err=%d",
                  (long)ticket, vol, (int)res.retcode, GetLastError());
      return false;
   }
   return true;
}

//============================================================
// EA STATE / GUARDS
//============================================================

bool IsTradingDisabled()
{
   if(!InpDisableAfterDD) return false;
   if(!GlobalVariableCheck(gv_disabled_name)) return false;

   double v = GlobalVariableGet(gv_disabled_name);
   if(v <= 0.5) return false;

   if(InpDDCooldownMinutes <= 0)
      return true;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();

   datetime disabled_until = (datetime)v;

   if(disabled_until < 100000)
      return true;

   if(now < disabled_until)
      return true;

   // cooldown selesai
   GlobalVariableSet(gv_disabled_name, 0.0);

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = AccountInfoDouble(ACCOUNT_BALANCE);

   return false;
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
         PrintFormat("[EA_V7_DeletePend] Gagal delete pending ticket=%I64u retcode=%d",
                     (long)ticket, (int)m_trade.ResultRetcode());
   }
   return any;
}

bool CloseAllPositionsOfEA()
{
   bool any=false;

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

      double vol = PositionGetDouble(POSITION_VOLUME);
      if(ClosePositionVolume(ticket, vol))
         any=true;
   }
   return any;
}

bool CheckEquityDDGuard(string &why)
{
   why = "";
   if(!InpUseEquityDDGuard) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = equity;
   if(equity > g_peak_equity)
      g_peak_equity = equity;

   double dd = g_peak_equity - equity;
   if(dd <= 0.0) return false;

   double dd_pct = 0.0;
   if(g_peak_equity > 0.0)
      dd_pct = dd / g_peak_equity * 100.0;

   bool trig=false;
   if(InpMaxDDPercentFromPeak > 0.0 && dd_pct >= InpMaxDDPercentFromPeak)
      trig=true;
   if(InpMaxDDMoney > 0.0 && dd >= InpMaxDDMoney)
      trig=true;

   if(!trig) return false;

   why = StringFormat("Equity DD guard triggered: DD=%.2f (%.1f%%) peak=%.2f equity=%.2f",
                      dd, dd_pct, g_peak_equity, equity);

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

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = AccountInfoDouble(ACCOUNT_BALANCE);

   PrintFormat("[EA_V7_DDGuard] %s", why);
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

   // Midnights (server time): hari ini 00:00 dan besok 00:00
   MqlDateTime dt0 = dt;
   dt0.hour = 0;
   dt0.min  = 0;
   dt0.sec  = 0;

   datetime midnight_today = StructToTime(dt0);
   datetime midnight_next  = midnight_today + 86400;

   datetime start_today = midnight_today - (InpRolloverMinutesBefore * 60);
   datetime end_today   = midnight_today + (InpRolloverMinutesAfter  * 60);

   datetime start_next  = midnight_next  - (InpRolloverMinutesBefore * 60);
   datetime end_next    = midnight_next  + (InpRolloverMinutesAfter  * 60);

   datetime ref_midnight = 0;

   // NOTE: penting untuk menangkap window "sesudah 00:00" (awal hari) juga
   if(now >= start_today && now <= end_today)
      ref_midnight = midnight_today;
   else if(now >= start_next && now <= end_next)
      ref_midnight = midnight_next;
   else
      return false;

   why = StringFormat("Rollover window (00:00 server) around %s",
                      TimeToString(ref_midnight, TIME_DATE|TIME_MINUTES));

   // Close posisi hanya pada bagian "sebelum 00:00"
   datetime ref_start = ref_midnight - (InpRolloverMinutesBefore * 60);
   if(now >= ref_start && now < ref_midnight)
   {
      if(g_last_rollover_close_for != ref_midnight)
      {
         doCloseNow = true;
         g_last_rollover_close_for = ref_midnight;
      }
   }
   return true;
}

//============================================================
// INDICATORS
//============================================================

bool GetMA2(double &ma0, double &ma1)
{
   ENUM_MA_METHOD method = InpHedgeUseEMA ? MODE_EMA : MODE_SMA;

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

bool GetBullMA2(double &ma0, double &ma1)
{
   ENUM_MA_METHOD method = InpBullishUseEMA ? MODE_EMA : MODE_SMA;

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

bool GetATR(double &atr)
{
   atr = 0.0;

   if(!InpUseATRGridDistance)
      return false;

   if(g_atr_handle == INVALID_HANDLE || g_atr_tf_last != InpATRGridTF || g_atr_period_last != InpATRGridPeriod)
   {
      if(g_atr_handle != INVALID_HANDLE)
         IndicatorRelease(g_atr_handle);

      g_atr_handle = iATR(_Symbol, InpATRGridTF, InpATRGridPeriod);
      g_atr_tf_last = InpATRGridTF;
      g_atr_period_last = InpATRGridPeriod;
   }

   if(g_atr_handle == INVALID_HANDLE)
      return false;

   double buf[];
   ArrayResize(buf, 1);
   ArraySetAsSeries(buf, true);

   int copied = CopyBuffer(g_atr_handle, 0, 0, 1, buf);
   if(copied < 1)
      return false;

   atr = buf[0];
   return (atr > 0.0);
}

bool IsBearishNow()
{
   double ma0=0, ma1=0;
   if(!GetMA2(ma0, ma1))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (bid < ma0 && ma0 < ma1);
}

bool IsBullishConfirmed()
{
   double ma0=0, ma1=0;
   if(!GetBullMA2(ma0, ma1))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (bid > ma0 && ma0 > ma1);
}

//============================================================
// P/L CALCS
//============================================================

double GetBuyFloatingMoney()
{
   double sum = 0.0;
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

      double p = PositionGetDouble(POSITION_PROFIT);
      double s = PositionGetDouble(POSITION_SWAP);
      // Commission (jika broker mengisi nilai ini, biasanya negatif)
      double c = 0.0; // POSITION_COMMISSION deprecated; ignored
      sum += (p + s + c);
   }
   return sum;
}

//============================================================
// SL/TP MODIFIER
//============================================================

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
      PrintFormat("[EA_V7_SLTP] OrderSend(SLTP) FAILED. ticket=%I64u err=%d retcode=%d",
                  (long)ticket, GetLastError(), (int)result.retcode);
      return false;
   }

   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("[EA_V7_SLTP] OrderSend(SLTP) not DONE. ticket=%I64u retcode=%d",
                  (long)ticket, (int)result.retcode);
      return false;
   }

   return true;
}

//============================================================
// POSITION MANAGEMENT
//============================================================

void ManageBuyPositions()
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

      // TP target
      double wantTP = 0.0;
      if(InpTP_Pips > 0)
         wantTP = NormalizeDouble(open + (InpTP_Pips * pip), _Digits);

      bool needModify=false;
      double newSL = curSL;
      double newTP = curTP;

      if(wantTP > 0)
      {
         if(curTP <= 0 || MathAbs(curTP - wantTP) > (pip * 0.1))
         {
            // Hindari set TP di bawah harga sekarang (yang bisa reject)
            if(wantTP > bid)
            {
               newTP = wantTP;
               needModify=true;
            }
         }
      }

      double profitPips = (bid - open) / pip;

      // BE
      if(profitPips >= InpBE_Trigger_Pips)
      {
         double beSL = NormalizeDouble(open + (InpBE_Lock_Pips * pip), _Digits);
         if(curSL <= 0 || beSL > curSL)
         {
            newSL = beSL;
            needModify=true;
         }
      }

      // Trailing
      if(profitPips >= InpTrail_Start_Pips)
      {
         double trailSL = NormalizeDouble(bid - (InpTrail_Dist_Pips * pip), _Digits);

         // jangan turun di bawah SL yg sudah ada
         if(newSL > 0 && trailSL < newSL)
            trailSL = newSL;

         double step = InpTrail_Step_Pips * pip;
         if(step < pip) step = pip;

         if(curSL <= 0)
         {
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
         ModifyPositionSLTP(ticket, newSL, newTP);
   }
}

void ManageHedgeSellPositions()
{
   if(!InpHedgeManageSLTP)
      return;

   double pip = PipValue();
   if(pip <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Stops level minimal
   int stops_level_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stops_level = stops_level_points * _Point;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      bool needModify=false;
      double newSL = curSL;
      double newTP = curTP;

      // TP untuk SELL hedge (profit jika harga turun)
      // Jika MoneyTP aktif, jangan pakai TP price (biar exit via money logic)
      if(InpHedgeTP_Pips > 0 && !(InpHedgeUseMoneyTP && InpHedgeTakeProfitMoney > 0.0))
      {
         double wantTP = NormalizeDouble(open - (InpHedgeTP_Pips * pip), _Digits);

         // validasi: TP harus di bawah harga sekarang - minimal stops level
         if(wantTP < (ask - stops_level))
         {
            if(curTP <= 0 || MathAbs(curTP - wantTP) > (pip * 0.1))
            {
               newTP = wantTP;
               needModify=true;
            }
         }
      }

      // Profit pips untuk SELL
      double profitPips = (open - ask) / pip;

      // Jika MoneyTP aktif, biarkan hedge berjalan tanpa BE/trailing supaya bisa mencapai target profit $
      if(!(InpHedgeUseMoneyTP && InpHedgeTakeProfitMoney > 0.0))
      {
   // BE untuk SELL
         if(profitPips >= InpHedgeBE_Trigger_Pips)
         {
            double beSL = NormalizeDouble(open - (InpHedgeBE_Lock_Pips * pip), _Digits);

            // SL untuk SELL harus di atas ASK (lebih besar dari ask + stops)
            double minSL = ask + stops_level;
            if(beSL < minSL)
               beSL = NormalizeDouble(minSL, _Digits);

            if(curSL <= 0 || beSL < curSL)
            {
               newSL = beSL;
               needModify=true;
            }
         }

         // Trailing untuk SELL (SL turun mengikuti harga)
         if(profitPips >= InpHedgeTrail_Start_Pips)
         {
            double trailSL = NormalizeDouble(ask + (InpHedgeTrail_Dist_Pips * pip), _Digits);

            // validasi minimal
            double minSL = ask + stops_level;
            if(trailSL < minSL)
               trailSL = NormalizeDouble(minSL, _Digits);

            // Step
            double step = InpHedgeTrail_Step_Pips * pip;
            if(step < pip) step = pip;

            if(curSL <= 0)
            {
               newSL = trailSL;
               needModify=true;
            }
            else
            {
               // untuk SELL: SL makin kecil makin bagus, jadi kita update jika trailSL < curSL - step
               if(trailSL < curSL && (curSL - trailSL) >= step)
               {
                  newSL = trailSL;
                  needModify=true;
               }
            }
         }

            }

      if(needModify)
         ModifyPositionSLTP(ticket, newSL, newTP);
   }
}

//============================================================
// PENDING MANAGEMENT
//============================================================

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

      double wantTP = 0.0;
      if(InpTP_Pips > 0)
         wantTP = NormalizeDouble(price + (InpTP_Pips * pip), _Digits);

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

      req.type_time  = (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      req.expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

      bool ok = OrderSend(req, res);
      if(!ok || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_DONE_PARTIAL))
      {
         PrintFormat("[EA_V7_TP_SYNC] Failed modify pending TP. ticket=%I64u ret=%u (%s)",
                     (long)ticket, res.retcode, res.comment);
      }
   }
}

//============================================================
// BULLISH ADD-ON (OPTIONAL)
//============================================================

int CountOpenAddonBuys()
{
   int cnt = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(StringFind(cmt, "EA_V7_ADDON_BUY") >= 0)
         cnt++;
   }
   return cnt;
}

void TryOpenBullishAddOn()
{
   if(!InpUseBullishAddOn)
      return;

   if(g_pause_buy_by_hedge)
      return;

   if(IsTradingDisabled())
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(SpreadTooWide(ask, bid))
      return;

   bool dummyClose=false;
   string whyRoll="";
   if(InpUseRolloverGuard && IsRolloverPauseWindow(dummyClose, whyRoll))
      return;

   string whyNews="";
   if(InpUseNewsFilter && IsNewsPauseWindow(whyNews))
      return;

   if(CountOpenAddonBuys() >= InpBullishMaxOpenAddOns)
      return;

   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   if(g_last_addon_time > 0 && (now - g_last_addon_time) < InpBullishCooldownSeconds)
      return;

   if(!IsBullishConfirmed())
      return;

   double vol = (InpBullishAddLot > 0.0 ? InpBullishAddLot : InpLotSize);
   vol = NormalizeVolume(vol);

   double tp = 0.0;
   if(InpTP_Pips > 0)
      tp = ask + (double)InpTP_Pips * PipValue();

   m_trade.SetExpertMagicNumber(InpMagicNum);
   bool ok = m_trade.Buy(vol, _Symbol, 0.0, 0.0, tp, "EA_V7_ADDON_BUY");
   if(ok)
   {
      g_last_addon_time = now;
      PrintFormat("[EA_V7_AddOn] Opened BUY add-on: vol=%.2f tp=%.5f", vol, tp);
   }
   else
   {
      PrintFormat("[EA_V7_AddOn] FAILED open add-on BUY. retcode=%d", m_trade.ResultRetcode());
   }
}

//============================================================
// HEDGE (SELL) MANAGEMENT
//============================================================

struct HedgePos
{
   ulong  ticket;
   double volume;
   double profit;
};

int CollectSellPositions(HedgePos &arr[])
{
   ArrayResize(arr, 0);
   int n=0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      HedgePos hp;
      hp.ticket = ticket;
      hp.volume = PositionGetDouble(POSITION_VOLUME);
      hp.profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      ArrayResize(arr, n+1);
      arr[n] = hp;
      n++;
   }
   return n;
}

void SortHedgeByProfitDesc(HedgePos &arr[])
{
   int n = ArraySize(arr);
   if(n <= 1) return;

   for(int i=0; i<n-1; i++)
   {
      int best=i;
      for(int j=i+1; j<n; j++)
      {
         if(arr[j].profit > arr[best].profit)
            best=j;
      }
      if(best != i)
      {
         HedgePos tmp = arr[i];
         arr[i] = arr[best];
         arr[best] = tmp;
      }
   }
}

void TrimSellHedgeToTarget(double targetLots)
{
   if(!InpHedgeReduceToTarget)
      return;

   // total sell lots
   double sellLots=0.0;
   HedgePos sells[];
   int n = CollectSellPositions(sells);
   for(int i=0;i<n;i++) sellLots += sells[i].volume;

   if(sellLots <= targetLots + 1e-9)
      return;

   double toTrim = sellLots - targetLots;

   // urutkan: profit terbesar dulu (realize profit dulu ketika trim)
   SortHedgeByProfitDesc(sells);

   for(int i=0; i<n && toTrim > 1e-9; i++)
   {
      ulong ticket = sells[i].ticket;
      double vol   = sells[i].volume;
      if(vol <= 0) continue;

      // SAFETY: jangan trim posisi hedge yang loss besar (penyebab realized loss besar)
      double prof = sells[i].profit;
      if(InpHedgeCloseOnlyIfSmallLoss && prof < -InpHedgeCloseMaxLossPerPosMoney)
         continue;

      // close partial sesuai toTrim
      double closeVol = (toTrim < vol ? toTrim : vol);
      closeVol = NormalizeVolume(closeVol);
      if(closeVol <= 0) continue;

      if(closeVol > vol) closeVol = vol;

      if(ClosePositionVolume(ticket, closeVol))
      {
         toTrim -= closeVol;
      }
      else
      {
         // jika gagal partial, coba full close
         if(ClosePositionVolume(ticket, vol))
            toTrim -= vol;
      }
   }
}

void ManageBearishHedge(bool paused)
{
   if(!InpUseBearishHedge)
      return;

   // Hindari open/close hedge saat kondisi pasar buruk
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(SpreadTooWide(ask, bid))
      return;

   bool dummyClose=false;
   string tmp="";
   if(InpUseRolloverGuard && IsRolloverPauseWindow(dummyClose, tmp))
      return;

   string tmp2="";
   if(InpUseNewsFilter && IsNewsPauseWindow(tmp2))
      return;

   // Jika XAU no-hold aktif dan sedang paused, EA akan close semua posisi; hedge tidak perlu di-manage
   if(paused && InpXAU_NoHoldPolicy && IsXAUInstrument())
      return;

   // Hitung exposure
   double buyLots=0.0, sellLots=0.0;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY)  buyLots  += vol;
      if(type == POSITION_TYPE_SELL) sellLots += vol;
   }

   // Jika tidak ada BUY exposure, jangan simpan hedge SELL
   if(buyLots <= 0.0)
   {
      if(sellLots > 0.0)
      {
         // close semua SELL
         for(int i=PositionsTotal()-1; i>=0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket))
               continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
               continue;
            if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
               continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
               continue;

            double vol = PositionGetDouble(POSITION_VOLUME);
            ClosePositionVolume(ticket, vol);
         }
      }
      return;
   }

   // Buy floating (money) dipakai untuk:
   //  - trigger hedge (mode floating)
   //  - force close hedge saat buy sudah profit
   double buyFloat = GetBuyFloatingMoney();
g_pause_buy_by_hedge = false;
// --- Stabilizer / state machine untuk hedge (mengurangi churn SELL)
static int      s_hedge_state = 0; // 0=OFF, 1=ON, 2=CLOSING
static datetime s_last_check  = 0;
static datetime s_open_since  = 0;
static datetime s_close_since = 0;
static datetime s_state_since = 0;
static datetime s_last_off    = 0;
static datetime s_last_add    = 0;
static datetime s_last_moneytp_check = 0;
static double   s_hedge_peak_profit = 0.0;

datetime now = TimeCurrent();

// NEW: close hedge cepat saat BUY basket sudah profit,
// tapi HANYA jika hedge basket juga tidak rugi (>= minimal profit lock).
// Ini mencegah kejadian hedge SELL ditutup dalam rugi besar ketika BUY sudah plus.
if(InpHedgeForceCloseOnBuyProfit && InpHedgeCloseOnBuyProfit && sellLots > 0.0 && buyFloat >= InpHedgeCloseOnBuyProfitMoney)
{
   double hedgeBasketProf = 0.0;
   int hedgeCnt = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      hedgeBasketProf += (PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
      hedgeCnt++;
   }

   double netProf = buyFloat + hedgeBasketProf;

   // boleh close hedge meskipun hedgeBasketProf negatif, asalkan NET (BUY+HEDGE) tetap >= ambang
   if(hedgeCnt > 0 && (hedgeBasketProf >= InpHedgeCloseOnBuyProfitMinHedgeProfitMoney || netProf >= InpHedgeCloseOnBuyProfitMinNetMoney))
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;

         double vol = PositionGetDouble(POSITION_VOLUME);
         ClosePositionVolume(ticket, vol);
      }

      // re-check sellLots
      sellLots = 0.0;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;
         sellLots += PositionGetDouble(POSITION_VOLUME);
      }

      if(sellLots <= 0.0)
      {
         s_hedge_state = 0;
         s_hedge_peak_profit = 0.0;
         s_last_off = now;
         s_state_since = now;
         s_open_since = 0;
         s_close_since = 0;
      }
      else
      {
         s_hedge_state = 2;
         s_state_since = now;
         s_open_since = 0;
         s_close_since = 0;
      }
      return;
   }
}

if(InpHedgeCheckIntervalSeconds > 0 && (now - s_last_check) < InpHedgeCheckIntervalSeconds)
   return;
s_last_check = now;

bool bearishNow = IsBearishNow();

// open signal
bool openSignal=false;
if(InpHedgeTriggerByFloating)
{
   openSignal = (buyFloat <= -InpHedgeStartLossMoney);
   if(InpHedgeRequireBearishForFloating)
      openSignal = (openSignal && bearishNow);
}
else
{
   openSignal = bearishNow;
}

// close signal (dikombinasikan, tapi dipakai dengan konfirmasi waktu)
bool closeSignal=false;

// 1) close jika buy sudah profit (opsional)
if(InpHedgeCloseOnBuyProfit && buyFloat >= InpHedgeCloseOnBuyProfitMoney)
   closeSignal = true;

// 2) hysteresis floating (mode floating)
if(InpHedgeTriggerByFloating)
{
   if(buyFloat >= -InpHedgeStopLossMoney)
      closeSignal = true;
}
else
{
   // mode MA: jika tidak bearish -> close
   if(!bearishNow)
      closeSignal = true;
}

// 3) close ketika tidak bearish (opsional)
if(InpHedgeCloseWhenNotBearish && !bearishNow)
   closeSignal = true;

// Jika tidak ada BUY exposure, jangan simpan hedge SELL (tutup semua)
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
         if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;

         double vol = PositionGetDouble(POSITION_VOLUME);
         ClosePositionVolume(ticket, vol);
      }
   }
   s_hedge_state = 0;
   s_hedge_peak_profit = 0.0;
   s_last_off = now;
   s_state_since = now;
   s_open_since = 0;
   s_close_since = 0;
   return;
}

//=========================================================
// Hard SL untuk SELL hedge (apply ke posisi SELL yang belum punya SL)
//=========================================================
if(InpHedgeSL_Pips > 0 && InpHedgeManageSLTP && !InpHedgeUseMoneyTP)
{
   double pip = PipValue();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int stops_level_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stops_level = stops_level_points * _Point;

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(curSL <= 0.0 && pip > 0.0)
      {
         double wantSL = NormalizeDouble(open + (double)InpHedgeSL_Pips * pip, _Digits);
         // SL SELL harus > ask + stops
         double minSL = ask + stops_level;
         if(wantSL < minSL)
            wantSL = NormalizeDouble(minSL, _Digits);

         ModifyPositionSLTP(ticket, wantSL, curTP);
      }
   }
}

//=========================================================
// State machine transitions
//=========================================================
if(s_state_since == 0) s_state_since = now;

// OFF -> ON
if(s_hedge_state == 0)
{
   if(openSignal && (InpHedgeReopenCooldownSeconds <= 0 || (now - s_last_off) >= InpHedgeReopenCooldownSeconds))
   {
      if(s_open_since == 0) s_open_since = now;
      if((now - s_open_since) >= InpHedgeOpenConfirmSeconds)
      {
         s_hedge_state = 1;
         s_state_since = now;
         s_open_since = 0;
         s_close_since = 0;
      }
   }
   else
   {
      s_open_since = 0;
   }

   // jika OFF tapi masih ada sellLots (misal leftover), coba close pelan-pelan
   if(sellLots > 0.0)
      s_hedge_state = 2;
}

// ON -> CLOSING
if(s_hedge_state == 1)
{
   if(closeSignal)
   {
      if(s_close_since == 0) s_close_since = now;
      if((now - s_close_since) >= InpHedgeCloseConfirmSeconds && (now - s_state_since) >= InpHedgeMinHoldSeconds)
      {
         s_hedge_state = 2;
         s_state_since = now;
         s_close_since = 0;
         s_open_since = 0;
      }
   }
   else
   {
      s_close_since = 0;
   }
}

//=========================================================
// Execute behavior by state
//=========================================================
// target hedge lots (hanya saat ON)
double targetSellRaw = buyLots * InpHedgeRatio;

if(InpHedgeTriggerByFloating && InpHedgeUseStep)
{
   double dd = -buyFloat; // positif jika loss
   if(dd > InpHedgeStartLossMoney && InpHedgeStepLossMoney > 0.0)
   {
      int steps = (int)MathFloor((dd - InpHedgeStartLossMoney) / InpHedgeStepLossMoney);
      if(steps > 0 && InpHedgeStepLot > 0.0)
         targetSellRaw += steps * InpHedgeStepLot;
   }
}

double targetSell = targetSellRaw;
if(InpHedgeMaxLot > 0.0)
   targetSell = MathMin(InpHedgeMaxLot, targetSellRaw);
if(targetSell < 0.0) targetSell = 0.0;

// Pause BUY grid saat hedge aktif & DD cukup besar (tahan floating)
if(InpPauseBuyWhenHedge && s_hedge_state == 1)
{
   if(buyFloat <= -InpPauseBuyWhenHedgeDDMoney)
      g_pause_buy_by_hedge = true;
}

//=========================================================
// State ON: trim / add hedge to target
//=========================================================
if(s_hedge_state == 1)
{
   bool tookProfit = false;

   // NEW: rolling TP berbasis money (basket) untuk SELL hedge
   // Catatan History MT5:
   //  - SELL hedge dibuka:   sell / in
   //  - SELL hedge ditutup:  buy  / out
   if(InpHedgeUseMoneyTP && InpHedgeTakeProfitMoney > 0.0)
   {
      if(InpHedgeMoneyTPCheckSeconds <= 0 || s_last_moneytp_check == 0 || (now - s_last_moneytp_check) >= InpHedgeMoneyTPCheckSeconds)
      {
         s_last_moneytp_check = now;

         // Hitung total profit floating semua SELL hedge
         double totalProf = 0.0;
         int    hedgeCnt  = 0;

         for(int i=PositionsTotal()-1; i>=0; i--)
         {
            ulong ticket = PositionGetTicket(i);
            if(!PositionSelectByTicket(ticket))
               continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
               continue;
            if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
               continue;
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
               continue;

            datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
            if(InpHedgeMinHoldSeconds > 0 && (now - opentime) < InpHedgeMinHoldSeconds)
               continue;

            totalProf += (PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP));
            hedgeCnt++;
         }

         // Update peak profit untuk money trailing
         if(hedgeCnt <= 0)
            s_hedge_peak_profit = 0.0;
         else if(totalProf > s_hedge_peak_profit)
            s_hedge_peak_profit = totalProf;

         // Money trailing: jika hedge basket sudah pernah profit, jangan biarkan balik jadi minus
         if(InpHedgeUseMoneyTrail && hedgeCnt > 0 && s_hedge_peak_profit >= InpHedgeMoneyTrailStartMoney)
         {
            bool doTrailClose = false;

            // hanya close jika masih non-negative (lock profit / BE)
            if(totalProf >= 0.0)
            {
               // close jika profit turun sampai lock level
               if(totalProf <= InpHedgeMoneyTrailLockMoney)
                  doTrailClose = true;

               // atau close jika drop besar dari peak (tapi masih di atas lock)
               if(!doTrailClose && InpHedgeMoneyTrailDropFromPeak > 0.0 &&
                  (s_hedge_peak_profit - totalProf) >= InpHedgeMoneyTrailDropFromPeak &&
                  totalProf >= InpHedgeMoneyTrailLockMoney)
                  doTrailClose = true;
            }

            if(doTrailClose)
            {
               for(int i=PositionsTotal()-1; i>=0; i--)
               {
                  ulong ticket = PositionGetTicket(i);
                  if(!PositionSelectByTicket(ticket))
                     continue;
                  if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                     continue;
                  if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
                     continue;
                  if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
                     continue;

                  datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(InpHedgeMinHoldSeconds > 0 && (now - opentime) < InpHedgeMinHoldSeconds)
                     continue;

                  double vol = PositionGetDouble(POSITION_VOLUME);
                  if(ClosePositionVolume(ticket, vol))
                     tookProfit = true;
               }

               if(tookProfit)
               {
                  s_last_add = 0;
                  s_hedge_peak_profit = 0.0;

                  // re-calc sellLots
                  sellLots = 0.0;
                  for(int k=PositionsTotal()-1; k>=0; k--)
                  {
                     ulong tk = PositionGetTicket(k);
                     if(!PositionSelectByTicket(tk))
                        continue;
                     if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                        continue;
                     if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
                        continue;
                     if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
                        continue;
                     sellLots += PositionGetDouble(POSITION_VOLUME);
                  }
               }
            }
         }

         // Jika basket hedge sudah profit >= ambang, tutup semua hedge untuk lock profit
         if(hedgeCnt > 0 && totalProf >= InpHedgeTakeProfitMoney)
         {
            for(int i=PositionsTotal()-1; i>=0; i--)
            {
               ulong ticket = PositionGetTicket(i);
               if(!PositionSelectByTicket(ticket))
                  continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                  continue;
               if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
                  continue;
               if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
                  continue;

               datetime opentime = (datetime)PositionGetInteger(POSITION_TIME);
               if(InpHedgeMinHoldSeconds > 0 && (now - opentime) < InpHedgeMinHoldSeconds)
                  continue;

               double vol = PositionGetDouble(POSITION_VOLUME);
               if(ClosePositionVolume(ticket, vol))
                  tookProfit = true;
            }

            if(tookProfit)
            {
               // allow immediate replacement (bypass cooldown)
               s_last_add = 0;

               // PENTING: re-calc sellLots supaya EA benar-benar buka hedge pengganti
               sellLots = 0.0;
               for(int k=PositionsTotal()-1; k>=0; k--)
               {
                  ulong tk = PositionGetTicket(k);
                  if(!PositionSelectByTicket(tk))
                     continue;
                  if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                     continue;
                  if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
                     continue;
                  if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
                     continue;
                  sellLots += PositionGetDouble(POSITION_VOLUME);
               }
            }
         }
      }
   }

// 1) Trim (hindari micro-trim)
   if(InpHedgeReduceToTarget && sellLots > targetSell + InpHedgeRebalanceMinDeltaLot)
   {
      TrimSellHedgeToTarget(targetSell);

      // re-calc sellLots (setelah trim)
      sellLots = 0.0;
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
            continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;
         sellLots += PositionGetDouble(POSITION_VOLUME);
      }
   }

   // 2) Add hedge jika kurang (pakai cooldown agar tidak spam)
   double need = targetSell - sellLots;
   if(need >= InpHedgeMinLot)
   {
      if(InpHedgeAddCooldownSeconds <= 0 || (now - s_last_add) >= InpHedgeAddCooldownSeconds || (tookProfit && InpHedgeReopenAfterMoneyTP))
      {
         double vol = NormalizeVolume(need);
         // Enforce max lot per order
         if(InpHedgeMaxLotPerOrder > 0.0 && vol > InpHedgeMaxLotPerOrder)
            vol = NormalizeVolume(InpHedgeMaxLotPerOrder);
         if(vol < InpHedgeMinLot)
            vol = InpHedgeMinLot;

         double pip = PipValue();
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

         double tp = 0.0;
         double sl = 0.0;

         if(InpHedgeManageSLTP && InpHedgeTP_Pips > 0 && pip > 0.0)
            tp = bid - (double)InpHedgeTP_Pips * pip;

         // Jika MoneyTP aktif, jangan pasang TP price agar exit via MoneyTP (profit $)
         if(InpHedgeUseMoneyTP && InpHedgeTakeProfitMoney > 0.0)
            tp = 0.0;

         if(InpHedgeSL_Pips > 0 && pip > 0.0)
            sl = bid + (double)InpHedgeSL_Pips * pip;

         m_trade.SetExpertMagicNumber(InpMagicNum);
         m_trade.Sell(vol, _Symbol, 0.0, sl, tp, "EA_V7_HEDGE_SELL");

         s_last_add = now;
      }
   }
   return;
}

//=========================================================
// State CLOSING: stop open new hedge, close existing SELL
//=========================================================
if(s_hedge_state == 2)
{
   // jika kondisi memburuk lagi -> batal close dan kembali ON
   if(openSignal && (now - s_state_since) >= 10)
   {
      s_hedge_state = 1;
      s_state_since = now;
      s_open_since = 0;
      s_close_since = 0;
      return;
   }

   // close yang profit / small loss saja (anti lock-loss)
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      double prof = PositionGetDouble(POSITION_PROFIT);
      if(!InpHedgeCloseOnlyIfSmallLoss || prof >= -InpHedgeCloseMaxLossPerPosMoney)
      {
         double vol = PositionGetDouble(POSITION_VOLUME);
         ClosePositionVolume(ticket, vol);
      }
   }

   // re-check sellLots
   sellLots = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      sellLots += PositionGetDouble(POSITION_VOLUME);
   }

   if(sellLots <= 0.0)
   {
      s_hedge_state = 0;
      s_hedge_peak_profit = 0.0;
      s_last_off = now;
      s_state_since = now;
      s_open_since = 0;
      s_close_since = 0;
   }
   return;
}

}


//============================================================
// GRID LOGIC
//============================================================

double GetGridDistancePoints()
{
   double distPoints = (double)InpDistance;

   if(InpUseATRGridDistance)
   {
      double atr=0.0;
      if(GetATR(atr))
      {
         double byAtr = (atr * InpATRGridMultiplier) / _Point;
         if(byAtr > 1.0)
            distPoints = byAtr;
      }

      if(InpATRGridMinPoints > 0)
         distPoints = MathMax(distPoints, (double)InpATRGridMinPoints);
      if(InpATRGridMaxPoints > 0)
         distPoints = MathMin(distPoints, (double)InpATRGridMaxPoints);
   }

   if(distPoints < 1.0) distPoints = 1.0;
   return distPoints;
}

bool IsSlotEmpty(double price, double distPoints)
{
   double tolerance = distPoints * _Point * 0.2;

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

int CountOpenPositionsAllTypes()
{
   int count=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;
      count++;
   }
   return count;
}

//============================================================
// INIT/DEINIT
//============================================================

int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNum);
   m_trade.SetDeviationInPoints(100);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);

   gv_anchor_name   = "EA_V7_Anchor_" + Symbol();
   gv_max_up_name   = "EA_V7_MaxUp_" + Symbol();
   gv_max_down_name = "EA_V7_MaxDown_" + Symbol();
   gv_disabled_name = "EA_V7_Disabled_" + Symbol() + "_" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));

   double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double point        = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(point == 0) return(INIT_FAILED);

   if(!GlobalVariableCheck(gv_disabled_name))
      GlobalVariableSet(gv_disabled_name, 0.0);

   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);

   // init anchor & limits
   if(!GlobalVariableCheck(gv_anchor_name))
   {
      GlobalVariableSet(gv_anchor_name, currentPrice);
      GlobalVariableSet(gv_max_up_name, InpBatchSize);
      GlobalVariableSet(gv_max_down_name, InpBatchSize);
   }
   else
   {
      double oldAnchor = GlobalVariableGet(gv_anchor_name);
      // jika beda jauh (mis. setelah restart), reset anchor
      if(MathAbs(currentPrice - oldAnchor) > (double)InpRecenterDistancePoints * point)
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
   {
      IndicatorRelease(g_bull_ma_handle);
      g_bull_ma_handle = INVALID_HANDLE;
   }

   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
   }
}

//============================================================
// TICK
//============================================================

void OnTick()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point == 0) return;

   // 1) Manage positions selalu jalan
   ManageBuyPositions();
   ManageHedgeSellPositions();
   SyncPendingOrdersTP();

   // Peak equity init/update
   double equity_now = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_peak_equity <= 0.0)
      g_peak_equity = equity_now;
   if(equity_now > g_peak_equity)
      g_peak_equity = equity_now;

   // Stop kalau disabled
   if(IsTradingDisabled())
   {
      if(InpDDCooldownMinutes > 0 && GlobalVariableCheck(gv_disabled_name))
      {
         double v = GlobalVariableGet(gv_disabled_name);
         datetime now = TimeTradeServer();
         if(now <= 0) now = TimeCurrent();
         datetime until = (datetime)v;

         if(until > 100000 && now < until)
         {
            if(g_last_pause_log == 0 || (now - g_last_pause_log) >= 60)
            {
               int mins_left = (int)MathCeil((double)(until - now) / 60.0);
               PrintFormat("[EA_V7_Pause] DD cooldown active (%d min left). Grid placement paused.", mins_left);
               g_last_pause_log = now;
            }
         }
      }
      return;
   }

   // 2) DD guard
   string ddWhy="";
   if(CheckEquityDDGuard(ddWhy))
      return;

   // 3) Pause conditions
   bool paused=false;
   EPauseReason pauseReason = PAUSE_NONE;
   string why="";

   bool doCloseRollover=false;
   string rollWhy="";
   if(InpUseRolloverGuard && IsRolloverPauseWindow(doCloseRollover, rollWhy))
   {
      paused=true;
      pauseReason = PAUSE_ROLLOVER;
      why = rollWhy;

      if(doCloseRollover)
      {
         CloseAllPositionsOfEA();
         DeletePendingOrdersOfEA();
      }
   }

   string whySpread="";
   if(!paused)
   {
      if(IsSpreadPause(ask, bid, whySpread))
      {
         paused=true;
         pauseReason = PAUSE_SPREAD;
         why = whySpread;
      }
   }

   string whyNews="";
   if(!paused && InpUseNewsFilter && IsNewsPauseWindow(whyNews))
   {
      paused=true;
      pauseReason = PAUSE_NEWS;
      why = whyNews;
   }

   // 3.5) Hedge management (open/close/trim) - jalan sebelum grid placement
   ManageBearishHedge(paused);

   if(paused)
   {
      bool isXAU = (InpXAU_NoHoldPolicy && IsXAUInstrument());
      if(isXAU)
      {
         bool closePos=false;
         bool deletePend=false;

         if(pauseReason == PAUSE_ROLLOVER)
         {
            // sebelum 00:00: doCloseRollover sudah close+delete.
            // sesudah 00:00: defaultnya hanya delete pending agar tidak ada fill saat spread rollover.
            deletePend = true;
            closePos   = doCloseRollover;
         }
         else if(pauseReason == PAUSE_NEWS)
         {
            // default: no-hold saat news
            deletePend = true;
            closePos   = true;
         }
         else if(pauseReason == PAUSE_SPREAD)
         {
            // default: jangan close posisi hanya karena spread, tapi hapus pending untuk hindari fill saat spread ekstrem
            deletePend = InpXAU_DeletePendingsOnSpreadPause;
            closePos   = InpXAU_CloseOnSpreadPause;
         }

         if(deletePend) DeletePendingOrdersOfEA();
         if(closePos)   CloseAllPositionsOfEA();
      }
      else
      {
         if(InpDeletePendingsDuringPause)
            DeletePendingOrdersOfEA();
      }

      datetime now = TimeCurrent();
      if(now - g_last_pause_log >= 60)
      {
         PrintFormat("[EA_V7_Pause] %s. Grid placement paused.", why);
         g_last_pause_log = now;
      }
      return;
   }

   // Pause BUY karena hedge (untuk tahan floating BUY minus)
   if(g_pause_buy_by_hedge)
   {
      if(InpPauseBuyDeletePendings)
         DeletePendingOrdersOfEA();

      datetime now = TimeCurrent();
      if(now - g_last_pause_log >= 60)
      {
         PrintFormat("[EA_V7_Pause] Buy grid paused by hedge. buyFloat=%.2f", GetBuyFloatingMoney());
         g_last_pause_log = now;
      }
      return;
   }

   // Auto recenter saat flat
   if(InpAutoRecenterWhenFlat)
   {
      int posCount = CountOpenPositionsAllTypes();
      if(posCount == 0)
      {
         double anchor = GlobalVariableGet(gv_anchor_name);
         double dist = MathAbs(ask - anchor);
         if(dist > (double)InpRecenterDistancePoints * point)
         {
            DeletePendingOrdersOfEA();
            GlobalVariableSet(gv_anchor_name, ask);
            GlobalVariableSet(gv_max_up_name, InpBatchSize);
            GlobalVariableSet(gv_max_down_name, InpBatchSize);

            PrintFormat("[EA_V7_Recenter] Anchor reset to %.5f (flat, distance %.0f points)",
                        ask, dist/point);
         }
      }
   }

   // Ambil data grid
   double anchorPrice = GlobalVariableGet(gv_anchor_name);
   int maxUp          = (int)GlobalVariableGet(gv_max_up_name);
   int maxDown        = (int)GlobalVariableGet(gv_max_down_name);

   // Hitung jarak grid (fixed/ATR)
   double distPoints = GetGridDistancePoints();

   // Safety gap
   double spread = ask - bid;
   double minGap = spread * 2.0;

   double pip = PipValue();

   // Pasang pending grid
   for(int i=-maxDown; i<=maxUp; i++)
   {
      if(i==0) continue;

      double targetPrice = anchorPrice + (i * distPoints * point);
      targetPrice = NormalizeDouble(targetPrice, _Digits);

      if(!IsSlotEmpty(targetPrice, distPoints))
         continue;

      // Batasi agar tidak jauh dari harga berjalan
      if(MathAbs(targetPrice - ask) > (distPoints * 60.0 * point))
         continue;

      double tp = 0.0;
      if(InpTP_Pips > 0)
         tp = NormalizeDouble(targetPrice + (InpTP_Pips * pip), _Digits);

      if(targetPrice > (ask + minGap))
      {
         m_trade.BuyStop(InpLotSize, targetPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "EA_V7_BuyStop_TP");
      }
      else if(targetPrice < (bid - minGap))
      {
         m_trade.BuyLimit(InpLotSize, targetPrice, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "EA_V7_BuyLimit_TP");
      }
   }

   // Refill/ekspansi
   int buyStopCount  = CountPendingOrders(ORDER_TYPE_BUY_STOP);
   int buyLimitCount = CountPendingOrders(ORDER_TYPE_BUY_LIMIT);

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

//============================================================
// TRADE TRANSACTION (ADD-ON)
//============================================================

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

   if(StringFind(cmt, "EA_V7_ADDON_BUY") >= 0)
      return;

   TryOpenBullishAddOn();
}
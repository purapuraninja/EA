//+------------------------------------------------------------------+
//| XAUUSD Cent Grid - BUY ONLY (Pending Refill per-level)           |
//| Rewritten: News Filter + BE + Trailing + Min TP                  |
//|                                                                  |
//| Tambahan fitur (sesuai request):                                 |
//| - News filter (MQL5 Economic Calendar): block refill grid saat    |
//|   window news aktif, optional delete pending EA.                 |
//| - Break-even: jika harga sudah +BE_Trigger (USD) dari entry, SL   |
//|   dipindah ke entry (BE).                                        |
//| - Trailing: mulai setelah BE tercapai + TrailDistance (USD); SL   |
//|   mengikuti Bid - TrailDistance (hanya naik, tidak pernah turun).|
//| - TakeProfit minimal: TP >= TP_MinDistance (USD) dari entry.     |
//| - StopLoss default 0 (user bisa isi manual via input).           |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUTS ======================
// --- Grid
input double GridStep                 = 5.0;     // Jarak grid (USD). Contoh 5.0 -> 1985,1990,1995...
input int    BuyLimitCount            = 60;      // Jumlah BUY LIMIT di bawah harga (saat trading allowed)
input int    BuyStopCount             = 60;      // Jumlah BUY STOP di atas harga
input double FixedLot                 = 0.01;    // Lot tetap
input int    ScanInterval             = 60;      // Timer scan (detik)
input long   MagicNumber              = 260107;  // Magic number EA
input int    MaxOpenPositions         = 8;       // Batas maksimum posisi BUY terbuka (0 = tidak dibatasi)

// --- Risk / Protection
input double MaxFloatingLossPercent   = 20.0;    // (%) Floating LOSS (SEMUA posisi symbol ini) >= X% dari BALANCE -> proteksi (hapus BUY LIMIT EA)

// --- Stops management (semua dalam "USD price" untuk XAUUSD)
input double StopLossDistance         = 0.0;     // SL distance dari entry (0 = tidak set, manual)
input double TP_MinDistance           = 15.0;    // TP minimal dari entry (>= 15)
input double BE_Trigger               = 5.0;     // BE aktif jika Bid >= Entry + ini
input double TrailDistance            = 0.5;     // Trailing jarak SL = Bid - ini (mulai setelah BE + TrailDistance)

// --- News filter (MQL5 Economic Calendar)
input bool   EnableNewsFilter         = true;    // Aktifkan news filter
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimal importance (High/Medium/Low)
input int    NewsMinutesBefore        = 30;      // Block sebelum news (menit)
input int    NewsMinutesAfter         = 30;      // Block sesudah news (menit)
input string NewsCurrenciesOverride   = "";      // Kosong = auto dari symbol (mis. "USD" untuk XAUUSD). Bisa isi "USD,EUR"
input bool   DeletePendingsDuringNews = true;    // Jika true: hapus semua pending EA saat masuk window news

//====================== INTERNAL STATE ======================
int  g_scan_interval = 60;
bool g_in_protection = false;   // anti-spam delete state (protection)
bool g_in_news       = false;   // anti-spam delete state (news)
bool g_in_maxpos     = false;   // anti-spam delete state (max positions)
bool g_calendar_warned = false; // print warning sekali kalau calendar tidak ada data

//====================== HELPERS ======================
double Eps()
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return tick * 0.5;
}

int DigitsSymbol()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double NormPrice(double p)
{
   return NormalizeDouble(p, DigitsSymbol());
}

double RoundDownToStep(double price)
{
   if(GridStep <= 0) return price;
   return MathFloor(price / GridStep) * GridStep;
}

double RoundUpToStep(double price)
{
   if(GridStep <= 0) return price;
   return MathCeil(price / GridStep) * GridStep;
}

bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   return true;
}

double StopsMinDistance()
{
   int stops_level_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stops_level_points < 0) stops_level_points = 0;
   return stops_level_points * _Point;
}

//====================== OCCUPANCY CHECK ======================
// Level dianggap "terisi" kalau ada pending order/posisi apapun pada level itu (symbol sama).
bool LevelOccupiedAll(double level_price)
{
   double e = Eps();

   // Pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - level_price) <= e) return true;
   }

   // Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pticket = PositionGetTicket(i);
      if(pticket == 0) continue;
      if(!PositionSelectByTicket(pticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double po = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(po - level_price) <= e) return true;
   }

   return false;
}

//====================== PRICE VALIDATION FOR PENDING ======================
bool PriceLevelAllowed(ENUM_ORDER_TYPE t, double level, double bid, double ask)
{
   double min_dist = StopsMinDistance();

   if(t == ORDER_TYPE_BUY_LIMIT)
   {
      if(level > (bid - min_dist)) return false;
   }
   else if(t == ORDER_TYPE_BUY_STOP)
   {
      if(level < (ask + min_dist)) return false;
   }
   return true;
}

void AdjustStopsForBuy(double entry, double &sl, double &tp)
{
   double min_dist = StopsMinDistance();

   // Enforce min TP distance if TP set
   if(tp > 0.0 && (tp - entry) < min_dist)
      tp = entry + min_dist;

   // Enforce min SL distance if SL set
   if(sl > 0.0 && (entry - sl) < min_dist)
      sl = entry - min_dist;

   sl = (sl > 0.0 ? NormPrice(sl) : 0.0);
   tp = (tp > 0.0 ? NormPrice(tp) : 0.0);
}

//====================== FLOATING LOSS PROTECTION ======================
double TotalFloatingAllPositions()
{
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pticket = PositionGetTicket(i);
      if(pticket == 0) continue;
      if(!PositionSelectByTicket(pticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      sum += PositionGetDouble(POSITION_PROFIT);
   }
   return sum;
}

//====================== POSITION LIMIT ======================
int CountEAOpenBuyPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pticket = PositionGetTicket(i);
      if(pticket == 0) continue;
      if(!PositionSelectByTicket(pticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype != POSITION_TYPE_BUY) continue;

      cnt++;
   }
   return cnt;
}

double CurrentLossPercent()
{
   double fl = TotalFloatingAllPositions();
   if(fl >= 0.0) return 0.0;

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0.0) return 0.0;

   double loss = -fl;
   return (loss / bal) * 100.0;
}

bool ShouldBeInProtection()
{
   if(MaxFloatingLossPercent <= 0.0) return false;
   return (CurrentLossPercent() >= MaxFloatingLossPercent);
}

// Delete BUY LIMIT pendings milik EA (dipakai untuk protection)
void DeleteEABuyLimitPendings()
{
   if(!TradingAllowed()) return;

   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_LIMIT) continue;

      long mg = (long)OrderGetInteger(ORDER_MAGIC);
      if(mg != MagicNumber) continue;

      trade.OrderDelete(ticket);
   }
}

// Delete semua pending (BL + BS) milik EA (dipakai untuk news)
void DeleteEAPendingsAll()
{
   if(!TradingAllowed()) return;

   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_BUY_STOP) continue;

      long mg = (long)OrderGetInteger(ORDER_MAGIC);
      if(mg != MagicNumber) continue;

      trade.OrderDelete(ticket);
   }
}

//====================== NEWS FILTER (ECONOMIC CALENDAR) ======================
string Trim(string s)
{
   // simple trim
   while(StringLen(s) > 0 && (StringGetCharacter(s,0) <= ' ')) s = StringSubstr(s,1);
   while(StringLen(s) > 0 && (StringGetCharacter(s,StringLen(s)-1) <= ' ')) s = StringSubstr(s,0,StringLen(s)-1);
   return s;
}

int SplitCSV(string csv, string &out[])
{
   ArrayResize(out, 0);
   string s = csv;
   if(StringLen(s) == 0) return 0;

   int start = 0;
   for(int i=0; i<StringLen(s); i++)
   {
      if(StringGetCharacter(s,i) == ',')
      {
         string part = Trim(StringSubstr(s, start, i-start));
         if(StringLen(part) > 0)
         {
            int n = ArraySize(out);
            ArrayResize(out, n+1);
            out[n] = part;
         }
         start = i+1;
      }
   }
   string last = Trim(StringSubstr(s, start));
   if(StringLen(last) > 0)
   {
      int n = ArraySize(out);
      ArrayResize(out, n+1);
      out[n] = last;
   }
   return ArraySize(out);
}

// Heuristik: ambil 3-char terakhir (quote) jika symbol format 6 char (FX), atau untuk XAUUSD ambil USD.
string AutoCurrenciesForSymbol()
{
   string sym = _Symbol;
   // strip suffix seperti ".m", "-pro", dll -> ambil huruf A-Z saja untuk heuristic
   string letters = "";
   for(int i=0; i<StringLen(sym); i++)
   {
      ushort ch = (ushort)StringGetCharacter(sym,i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))
         letters += CharToString((uchar)ch);
   }
   // MQL5: StringToUpper() modifies string by reference and returns bool.
   // Do NOT assign its return value.
   StringToUpper(letters);

   // kasus umum FX: 6 huruf, contoh EURUSD
   if(StringLen(letters) >= 6)
   {
      string base = StringSubstr(letters, 0, 3);
      string quote = StringSubstr(letters, 3, 3);
      // Untuk metal/index yang "XAUUSD" -> base XAU bukan currency calendar, tapi quote USD relevan.
      // Jadi prioritas: quote saja, plus base kalau base masuk list currency umum (EUR,USD,GBP,JPY,CHF,CAD,AUD,NZD,CNY,...)
      string majors = "USD,EUR,GBP,JPY,CHF,CAD,AUD,NZD,CNY,HKD,SGD,SEK,NOK,MXN,ZAR,TRY,PLN,RUB,INR,BRL,KRW,IDR";
      if(StringFind(","+majors+",", ","+quote+",") >= 0)
         return quote;
      // fallback: quote tetap
      return quote;
   }
   return "USD"; // fallback aman untuk kebanyakan simbol non-FX (bisa override manual)
}

// returns true jika sekarang berada di window news
bool IsNewsWindowActive(datetime &nearest_event_time, string &nearest_event_name, string &nearest_currency)
{
   nearest_event_time = 0;
   nearest_event_name = "";
   nearest_currency   = "";

   if(!EnableNewsFilter) return false;

   datetime now = TimeTradeServer(); // economic calendar juga memakai trade server time
   if(now <= 0) now = TimeCurrent();

   int before_sec = MathMax(0, NewsMinutesBefore) * 60;
   int after_sec  = MathMax(0, NewsMinutesAfter) * 60;

   datetime from = now - after_sec;
   datetime to   = now + before_sec;

   string cur_list = Trim(NewsCurrenciesOverride);
   if(StringLen(cur_list) == 0)
      cur_list = AutoCurrenciesForSymbol();

   string curs[];
   SplitCSV(cur_list, curs);
   if(ArraySize(curs) == 0)
   {
      ArrayResize(curs, 1);
      curs[0] = "USD";
   }

   bool active = false;
   datetime best_time = 0;
   string best_name = "";
   string best_cur = "";

   // scan setiap currency
   for(int ci=0; ci<ArraySize(curs); ci++)
   {
      string cur = Trim(curs[ci]);
      StringToUpper(cur);
      if(StringLen(cur) != 3) continue;

      MqlCalendarValue values[];
      ResetLastError();
      int n = CalendarValueHistory(values, from, to, NULL, cur);

      if(n <= 0)
      {
         // kalau data tidak tersedia, jangan spam
         int err = _LastError;
         if(!g_calendar_warned && EnableNewsFilter)
         {
            // Error umum: calendar belum diaktifkan / timeout / no data.
            PrintFormat("NewsFilter: CalendarValueHistory returned %d (err=%d). Pastikan Economic Calendar aktif di terminal.", n, err);
            g_calendar_warned = true;
         }
         continue;
      }

      for(int i=0; i<n; i++)
      {
         datetime t = (datetime)values[i].time;
         ulong event_id = (ulong)values[i].event_id;

         MqlCalendarEvent ev;
         if(!CalendarEventById(event_id, ev))
            continue;

         if(ev.importance < NewsMinImportance)
            continue;

         datetime wstart = t - before_sec;
         datetime wend   = t + after_sec;

         if(now >= wstart && now <= wend)
         {
            active = true;

            // pilih event terdekat (secara absolut)
            long dt = (long)MathAbs((long)(t - now));
            long best_dt = (best_time==0 ? 0x7fffffff : (long)MathAbs((long)(best_time - now)));
            if(best_time==0 || dt < best_dt)
            {
               best_time = t;
               best_name = ev.name;
               best_cur  = cur;
            }
         }
      }
   }

   nearest_event_time = best_time;
   nearest_event_name = best_name;
   nearest_currency   = best_cur;
   return active;
}

//====================== STOPS MANAGEMENT (BE + TRAIL + MIN TP) ======================
double EffectiveTPDistance()
{
   // enforce minimum 15
   if(TP_MinDistance < 15.0) return 15.0;
   return TP_MinDistance;
}

void ManagePositionsStops()
{
   if(!TradingAllowed()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0) return;

   double min_dist = StopsMinDistance();
   double tp_dist = EffectiveTPDistance();
   double e = Eps();

   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pticket = PositionGetTicket(i);
      if(pticket == 0) continue;
      if(!PositionSelectByTicket(pticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype != POSITION_TYPE_BUY) continue; // EA buy-only

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      double desiredTP = NormPrice(entry + tp_dist);
      double newTP = curTP;
      if(curTP <= 0.0 || curTP < (desiredTP - e))
         newTP = desiredTP;

      // BE & trailing
      double dist = bid - entry; // untuk BUY
      double newSL = curSL;

      // BE trigger
      if(dist >= BE_Trigger)
      {
         double be = entry;
         // Pastikan SL valid (tidak terlalu dekat dengan Bid)
         if((bid - be) >= min_dist)
         {
            if(newSL <= 0.0 || be > (newSL + e))
               newSL = be;
         }
      }

      // Trailing start setelah BE + TrailDistance
      if(dist >= (BE_Trigger + TrailDistance))
      {
         double trail = bid - TrailDistance;
         // validasi stop level
         double max_allowed = bid - min_dist;
         if(trail > max_allowed) trail = max_allowed;

         trail = NormPrice(trail);
         if(trail > (newSL + e))
            newSL = trail;
      }

      // jangan pernah turunkan SL
      if(curSL > 0.0 && newSL > 0.0 && newSL < (curSL - e))
         newSL = curSL;

      // normalize
      newSL = (newSL > 0.0 ? NormPrice(newSL) : 0.0);

      bool needModify = false;
      if((newSL > 0.0 && (curSL <= 0.0 || MathAbs(newSL - curSL) > e)) ||
         (newTP > 0.0 && (curTP <= 0.0 || MathAbs(newTP - curTP) > e)))
         needModify = true;

      if(needModify)
      {
         // PositionModify butuh SL dan TP sekaligus (kalau salah satu tidak berubah, kirim yang existing)
         double sl_to_send = (newSL > 0.0 ? newSL : curSL);
         double tp_to_send = (newTP > 0.0 ? newTP : curTP);

         trade.PositionModify(pticket, sl_to_send, tp_to_send);
      }
   }
}

// Pastikan pending EA punya TP minimal >= entry+TP_MinDistance (dan SL sesuai input kalau ada)
void EnforcePendingStops()
{
   if(!TradingAllowed()) return;

   double tp_dist = EffectiveTPDistance();
   double e = Eps();

   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(t != ORDER_TYPE_BUY_LIMIT && t != ORDER_TYPE_BUY_STOP) continue;

      long mg = (long)OrderGetInteger(ORDER_MAGIC);
      if(mg != MagicNumber) continue;

      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSL = OrderGetDouble(ORDER_SL);
      double curTP = OrderGetDouble(ORDER_TP);

      double desiredTP = NormPrice(price + tp_dist);
      double newTP = curTP;
      if(curTP <= 0.0 || curTP < (desiredTP - e))
         newTP = desiredTP;

      double newSL = curSL;
      if(StopLossDistance > 0.0)
      {
         double desiredSL = NormPrice(price - StopLossDistance);
         // hanya set kalau belum ada SL (atau mau dipaksa) - di sini kita "enforce" input
         newSL = desiredSL;
      }

      AdjustStopsForBuy(price, newSL, newTP);

      bool need = false;
      if((newSL > 0.0 && (curSL <= 0.0 || MathAbs(newSL - curSL) > e)) ||
         (newTP > 0.0 && (curTP <= 0.0 || MathAbs(newTP - curTP) > e)))
         need = true;

      if(need)
      {
         // Preserve expiration if any; otherwise treat as GTC.
         datetime exp = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         ENUM_ORDER_TYPE_TIME ttime = (exp > 0 ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC);

         // StopLimit price is only relevant for STOP_LIMIT orders; for BUY LIMIT/STOP it's typically 0.
         double stoplimit = 0.0;
         // Some brokers may still return a value; keep it if available.
         if(OrderGetDouble(ORDER_PRICE_STOPLIMIT) > 0.0)
            stoplimit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);

         trade.OrderModify(ticket, price, newSL, newTP, ttime, exp, stoplimit);
      }
   }
}

//====================== CORE GRID ======================
void EnsureGrid(bool allowBuyLimit)
{
   if(!TradingAllowed()) return;
   if(GridStep <= 0) return;
   if(FixedLot <= 0) return;
   if(BuyLimitCount < 0 || BuyStopCount < 0) return;

   // Batasi jumlah posisi terbuka (market) untuk mencegah grid kebablasan.
   if(MaxOpenPositions > 0)
   {
      int open_buys = CountEAOpenBuyPositions();
      if(open_buys >= MaxOpenPositions)
         return; // jangan refill grid kalau sudah mencapai limit
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   double baseDown = RoundDownToStep(bid);
   double baseUp   = RoundUpToStep(ask);

   double tp_dist = EffectiveTPDistance();

   // BUY LIMIT (bawah)
   if(allowBuyLimit)
   {
      for(int i = 0; i < BuyLimitCount; i++)
      {
         if(MaxOpenPositions > 0 && CountEAOpenBuyPositions() >= MaxOpenPositions)
            break;

         double level = NormPrice(baseDown - (i * GridStep));
         if(LevelOccupiedAll(level)) continue;
         if(!PriceLevelAllowed(ORDER_TYPE_BUY_LIMIT, level, bid, ask)) continue;

         double sl = 0.0;
         double tp = 0.0;

         // SL default 0 (manual), hanya set kalau input StopLossDistance > 0
         if(StopLossDistance > 0.0)
            sl = level - StopLossDistance;

         // TP minimal
         tp = level + tp_dist;

         AdjustStopsForBuy(level, sl, tp);

         trade.BuyLimit(FixedLot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "BL grid");
      }
   }

   // BUY STOP (atas)
   for(int i = 0; i < BuyStopCount; i++)
   {
      if(MaxOpenPositions > 0 && CountEAOpenBuyPositions() >= MaxOpenPositions)
         break;

      double level = NormPrice(baseUp + (i * GridStep));
      if(LevelOccupiedAll(level)) continue;
      if(!PriceLevelAllowed(ORDER_TYPE_BUY_STOP, level, bid, ask)) continue;

      double sl = 0.0;
      double tp = 0.0;

      if(StopLossDistance > 0.0)
         sl = level - StopLossDistance;

      tp = level + tp_dist;

      AdjustStopsForBuy(level, sl, tp);

      trade.BuyStop(FixedLot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "BS grid");
   }
}

//====================== MAIN CYCLE ======================
void RunLogic()
{
   // -1) Position cap: jika sudah mencapai limit, hapus pending supaya tidak nambah posisi baru (sekali).
   if(MaxOpenPositions > 0)
   {
      int open_buys = CountEAOpenBuyPositions();
      if(open_buys >= MaxOpenPositions && !g_in_maxpos)
      {
         DeleteEAPendingsAll();
         g_in_maxpos = true;
      }
      else if(open_buys < MaxOpenPositions && g_in_maxpos)
      {
         g_in_maxpos = false;
      }
   }

   // 0) News filter state
   datetime ntime;
   string nname, ncur;
   bool news_active = IsNewsWindowActive(ntime, nname, ncur);

   if(news_active && !g_in_news)
   {
      if(DeletePendingsDuringNews)
         DeleteEAPendingsAll();
      g_in_news = true;
   }
   else if(!news_active && g_in_news)
   {
      g_in_news = false;
   }

   // 1) Floating loss protection state machine
   bool shouldProtect = ShouldBeInProtection();

   // Masuk proteksi (edge): delete BUY LIMIT EA hanya SEKALI
   if(shouldProtect && !g_in_protection)
   {
      DeleteEABuyLimitPendings();
      g_in_protection = true;
   }
   else if(!shouldProtect && g_in_protection)
   {
      g_in_protection = false;
   }

   // 2) Enforce TP minimum on existing pending EA
   EnforcePendingStops();

   // 3) Grid refill per-level (diblock jika news aktif)
   if(!news_active)
   {
      // Jika proteksi ON -> stop bikin BUY LIMIT, BUY STOP tetap jalan
      EnsureGrid(!g_in_protection);
   }

   // 4) Status
   double lp = CurrentLossPercent();
   string stP = g_in_protection ? "PROTECTION ON" : "PROTECTION OFF";
   string stN = news_active ? "NEWS BLOCK ON" : "NEWS BLOCK OFF";
   int openPos = CountEAOpenBuyPositions();

   string ninfo = "";
   if(news_active && ntime > 0)
      ninfo = StringFormat("%s (%s) @ %s", nname, ncur, TimeToString(ntime, TIME_DATE|TIME_MINUTES));

   Comment("EA: XAU Grid Buy Only (News+BE+Trail)\n",
           "News: ", stN, (ninfo=="" ? "" : ("\nNearest: " + ninfo)), "\n",
           "Protection: ", stP, "\n",
           "OpenPos: ", IntegerToString(openPos), " / ", (MaxOpenPositions>0 ? IntegerToString(MaxOpenPositions) : "∞"), "\n",
           "FloatingLoss%: ", DoubleToString(lp, 2), "% (threshold ", DoubleToString(MaxFloatingLossPercent,2), "%)\n",
           "TP(min): ", DoubleToString(EffectiveTPDistance(),2), " | BE: ", DoubleToString(BE_Trigger,2),
           " | Trail: ", DoubleToString(TrailDistance,2));
}

//====================== EVENTS ======================
int OnInit()
{
   g_scan_interval = ScanInterval;
   if(g_scan_interval < 1) g_scan_interval = 60;

   EventSetTimer(g_scan_interval);
   RunLogic();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   RunLogic();
}

void OnTick()
{
   // Stop management butuh respon cepat -> jalan di tick.
   // Grid refill tetap pakai timer/transaction supaya ringan.
   ManagePositionsStops();
}

void OnTradeTransaction(const MqlTradeTransaction&,
                        const MqlTradeRequest&,
                        const MqlTradeResult&)
{
   // responsif saat pending tereksekusi / posisi ditutup manual
   RunLogic();
}
//+------------------------------------------------------------------+

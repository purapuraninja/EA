//+------------------------------------------------------------------+
//| EA: XAUUSD Grid Buy + Smart Sell Engine v2.0                    |
//|                                                                  |
//| GRID BUY (original, preserved):                                 |
//|   BUY LIMIT + BUY STOP refill per-level                        |
//|   News filter, Floating Loss Protection, MaxPos BUY            |
//|   BE + Trailing + Min TP                                        |
//|                                                                  |
//| SELL ENGINE (new):                                               |
//|   S1 : Trend-Following   (H4+H1 bearish, LH-LL structure)      |
//|   S2 : Breakout-Retest   (Daily/H4/Asian support broken)       |
//|   S3 : Mean-Reversion    (at resistance, ADX ranging)          |
//|   S4 : News-Driven       (hawkish USD surprise)                |
//|   S5 : Failed-Breakout   (liquidity sweep rejection)           |
//|   S6 : MTF-Confluence    (D1 + H4 + H1 aligned bearish)       |
//|   BE + Trailing + Min TP (mirrored from buy, inverted for sell)|
//|   Separate MaxSellPositions from MaxOpenPositions (buy)        |
//+------------------------------------------------------------------+
#property strict
#property copyright "XAUUSD Grid+Sell EA v2.0"
#property version   "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

//======================================================================
// INPUT PARAMETERS
//======================================================================

// --- GRID BUY ---
input group "=== GRID BUY ==="
input double GridStep               = 5.0;    // Grid step (USD per level)
input int    BuyLimitCount          = 10;     // BUY LIMIT levels below price
input int    BuyStopCount           = 0;      // BUY STOP levels above price (0=off, recovery-friendly)
input double FixedLot               = 0.01;   // Lot per grid order
input int    MaxOpenPositions       = 8;      // Max open BUY positions (0=unlimited)

// --- SELL ENGINE GENERAL ---
input group "=== SELL ENGINE ==="
input bool   EnableSellEngine       = false;   // Enable sell strategies
input double SellLot                = 0.01;   // Lot per sell position
input int    MaxSellPositions       = 3;      // Max open SELL positions (0=unlimited)
input int    SellCooldownMinutes    = 240;    // Min minutes between any sell entries
input double Sell_SLDistance        = 0.0;    // Sell SL distance from entry (0 = no SL, same as grid buy)

// --- SELL STRATEGY TOGGLES ---
input group "=== SELL STRATEGIES ==="
input bool   Enable_S1_TrendFollow  = true;   // S1: Trend-Following (H4+H1 bearish, LH-LL)
input bool   Enable_S2_BreakRetest  = true;   // S2: Breakout-Retest below support
input bool   Enable_S3_MeanRev      = true;   // S3: Mean-Reversion at resistance (ranging)
input bool   Enable_S4_NewsDriven   = true;   // S4: News-Driven (hawkish USD data)
input bool   Enable_S5_FailBreak    = true;   // S5: Failed-Breakout / Liquidity Sweep
input bool   Enable_S6_MTF          = true;   // S6: MTF Confluence (D1+H4+H1)

// --- S2 BREAKOUT-RETEST ---
input group "=== S2: Breakout-Retest ==="
input double BR_BreakBuffer         = 1.5;    // Min USD below support = confirmed break
input double BR_RetestBuffer        = 2.5;    // Retest zone: ±USD from broken level
input int    BR_MaxRetestHours      = 48;     // Hours to wait for retest before expiry
input bool   BR_UseDailyLow         = true;   // Use yesterday Daily Low as support
input bool   BR_UseH4Low            = true;   // Use H4 recent low (5 bars) as support
input bool   BR_UseAsianLow         = true;   // Use Asian session (00-08h) low

// --- S3 MEAN-REVERSION ---
input group "=== S3: Mean-Reversion ==="
input double MR_ADX_Max             = 25.0;   // Max H4 ADX for ranging filter
input double MR_ResistBuffer        = 3.0;    // Within this USD of resistance = at-level
input double MR_MinWickRatio        = 2.0;    // Upper wick >= body * this = rejection

// --- S4 NEWS-DRIVEN ---
input group "=== S4: News-Driven ==="
input int    S4_DelayBarsAfterNews  = 1;      // H1 bars to wait after news window closes
input bool   S4_RequireBearishBar   = true;   // Require bearish H1 candle confirmation

// --- S5 FAILED BREAKOUT ---
input group "=== S5: Failed-Breakout ==="
input int    FB_LookbackBars        = 20;     // H1 bars to identify recent high
input double FB_ATRMultiplier        = 0.3;    // Breach buffer = ATR(H1) * this (dynamic)

// --- SPREAD FILTER (SELL) ---
input group "=== SPREAD FILTER (SELL) ==="
input bool   EnableSpreadFilter     = true;   // Filter out wide-spread entries
input double SpreadMaxATRRatio      = 0.30;   // Max spread / ATR(H1) ratio

// --- SESSION FILTER (SELL) ---
input group "=== SESSION FILTER (SELL) ==="
input bool   EnableSessionFilter    = true;   // Restrict sell to active sessions
input int    SessionStartHour       = 7;      // Session start hour (server time)
input int    SessionEndHour         = 21;     // Session end hour (server time)
input bool   S3_AllowOutsideSession = true;   // Allow S3 Mean-Rev outside session

// --- SELL LOT MULTIPLIERS ---
input group "=== SELL LOT MULTIPLIERS ==="
input double LotMult_S1             = 1.0;    // S1 Trend-Following
input double LotMult_S2             = 1.0;    // S2 Breakout-Retest
input double LotMult_S3             = 0.5;    // S3 Mean-Reversion (lower confidence)
input double LotMult_S4             = 1.0;    // S4 News-Driven
input double LotMult_S5             = 0.8;    // S5 Failed-Breakout
input double LotMult_S6             = 1.5;    // S6 MTF Confluence (highest quality)

// --- STOPS GRID BUY ---
input group "=== STOPS - GRID BUY ==="
input double StopLossDistance       = 0.0;    // Grid BUY SL distance (0=no SL)
input double TP_MinDistance         = 15.0;   // Min TP for grid buy (USD)
input double BE_Trigger             = 5.0;    // Buy BE trigger: Bid >= Entry + this
input double BE_LockProfit          = 2.0;    // Buy BE lock: SL = Entry + this (0=breakeven)
input double TrailDistance          = 0.5;    // Buy trail: SL = Bid - this

// --- STOPS SELL ---
input group "=== STOPS - SELL ==="
input double Sell_TP_Min            = 15.0;   // Min TP for sell positions (USD)
input double Sell_BE_Trigger        = 5.0;    // Sell BE trigger: Ask <= Entry - this
input double Sell_BE_LockProfit     = 2.0;    // Sell BE lock: SL = Entry - this (0=breakeven)
input double Sell_TrailDistance     = 0.5;    // Sell trail: SL = Ask + this

// --- RISK & TIMER ---
input group "=== RISK & TIMER ==="
input double MaxFloatingLossPercent = 20.0;   // Max floating loss % → protection
input int    ScanInterval           = 60;     // Timer interval (seconds)
input long   MagicNumber            = 260107; // EA Magic Number

// --- MOBILE DASHBOARD CONTROL ---
input group "=== MOBILE DASHBOARD CONTROL ==="
input bool   DashboardControlEnabled = true;  // Read runtime controls from Common Files
input string DashboardControlFile    = "EA_GRID_2026_dashboard_control.ini";
input string DashboardStatusFile     = "EA_GRID_2026_dashboard_status.ini";
input int    DashboardPollSeconds    = 3;     // How often EA checks dashboard file

// --- NEWS FILTER ---
input group "=== NEWS FILTER ==="
input bool   EnableNewsFilter         = true;
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_HIGH;
input int    NewsMinutesBefore        = 30;
input int    NewsMinutesAfter         = 30;
input string NewsCurrenciesOverride   = "";
input bool   DeletePendingsDuringNews = true;

// --- RECOVERY GRID MODE ---
input group "=== RECOVERY GRID MODE ==="
input bool   EnableRecoveryGridMode                    = true;   // Master ON/OFF for recovery grid mode
input bool   Recovery_EnableBuyGrid                    = true;   // Enable BUY LIMIT grid below price
input bool   Recovery_EnableSellGrid                   = true;   // Enable SELL LIMIT grid above price
input double Recovery_GridStep                         = 0.25;   // Grid step between levels (USD)
input int    Recovery_BuyLimitCount                    = 30;     // Number of BUY LIMIT levels
input int    Recovery_SellLimitCount                   = 30;     // Number of SELL LIMIT levels
input double Recovery_BaseLot                          = 0.01;   // Base lot per level
input bool   Recovery_UseLotStep                       = true;   // Increase lot every N levels
input int    Recovery_LotStepEveryLevels               = 10;     // Levels per lot increment
input double Recovery_LotStepAdd                       = 0.01;   // Lot added per increment
input int    Recovery_MaxBuyPositions                  = 60;      // Max BUY positions (0=unlimited)
input int    Recovery_MaxSellPositions                 = 60;      // Max SELL positions (0=unlimited)
input int    Recovery_MaxTotalPositions                = 120;      // Max total positions (0=unlimited)
input bool   Recovery_UseTP                            = false;  // Attach TP to grid orders
input double Recovery_TPDistance                       = 0.0;    // TP distance (USD) if UseTP
input bool   Recovery_UseInitialSL                     = false;  // Attach initial SL to grid orders
input double Recovery_InitialSLDistance                = 0.0;    // Initial SL distance (USD) if UseInitialSL
input bool   Recovery_UseBasketTrailing                = true;   // Common/basket trailing SL
input double Recovery_BasketBETrigger                  = 1.50;   // Basket BE trigger distance (USD)
input double Recovery_BasketLockProfit                 = 0.30;   // Profit lock when BE triggers (USD)
input double Recovery_BasketTrailDistance              = 0.50;   // Basket trailing distance (USD)
input bool   Recovery_DeleteOppositePendingsOnBasketTrail = false; // Delete opposite pendings when basket trails
input bool   Recovery_UseBasketMoneyTP                 = true;   // Close basket on floating-profit target
input double Recovery_BasketMoneyTP                    = 500.0;  // Target profit in ACCOUNT currency (cent acc: 500=$5)
input bool   Recovery_BasketMoneyTP_ProfitOnly         = false;  // Legacy toggle; false = close whole basket by net P/L
input bool   Recovery_BasketMoneyTP_InclSwap           = true;   // Include swap in profit calc
input bool   Recovery_UseBasketEquitySL                = true;   // Cut-loss: close whole basket on equity drawdown
input double Recovery_BasketEquitySL_Percent           = 25.0;   // Close ALL if floating loss >= this % of equity
input bool   Recovery_BasketEquitySL_InclSwap          = true;   // Include swap in floating loss calc
input bool   Recovery_KeepOldStrategyWhenEnabled       = false;  // Run old grid+sell engine alongside recovery

input group "=== RECOVERY SELECTIVE NET CLOSE ==="
input bool   Recovery_UseSelectiveNetClose       = true;
input double Recovery_SelectiveNetTarget         = 100.0;   // profit bersih minimal setelah close winner + loser
input double Recovery_SelectiveCloseBuffer       = 30.0;    // cadangan spread/slippage/komisi
input double Recovery_MinLossToOffset            = 20.0;    // minimal loss yang layak ditutup
input double Recovery_MaxLossClosePerPass        = 700.0;   // batas total loss yang boleh ditutup per siklus close
input int    Recovery_MaxTicketsClosePerPass     = 20;      // batas jumlah posisi yang ditutup sekali jalan
input int    Recovery_CloseCooldownSeconds       = 30;      // pause refill setelah close

input group "=== RECOVERY GLOBAL BASKET CLOSE ==="
input bool   Recovery_UseGlobalBasketClose       = true;
input double Recovery_GlobalBasketMoneyTP        = 500.0;   // kalau total semua posisi aktif sudah profit sebesar ini, close all
input double Recovery_GlobalBasketCloseBuffer    = 30.0;
input int    Recovery_CloseDeviationPoints       = 50;

//======================================================================
// GLOBAL STATE
//======================================================================
int  g_scan_interval   = 60;
bool g_in_protection   = false;
bool g_in_news         = false;
bool g_in_maxpos       = false;
bool g_in_maxpos_sell  = false;
bool g_calendar_warned = false;

// Mobile dashboard runtime overrides
bool     g_dashboard_ea_enabled   = true;
bool     g_dashboard_prev_enabled = true;
int      g_dashboard_max_buy      = -1;   // -1 = use EA input, 0 = unlimited
int      g_dashboard_max_sell     = -1;   // -1 = use EA input, 0 = unlimited
datetime g_dashboard_last_poll    = 0;
datetime g_dashboard_last_load    = 0;

// Sell cooldown
datetime g_sell_last_entry = 0;

// Recovery exit-management state
bool     g_recovery_close_in_progress = false;
datetime g_recovery_pause_until       = 0;

// S2 breakout-retest state machine (0=DailyLow, 1=H4Low, 2=AsianLow)
struct BRState
{
   bool     active;
   bool     waiting_retest;
   double   level;
   datetime break_time;
};
BRState g_br[3];

// S4 news-driven state
bool     g_s4_pending    = false;
datetime g_s4_window_end = 0;
datetime g_last_h1_bar   = 0;

// Asian range cache
double   g_asian_high  = 0;
double   g_asian_low   = 0;
datetime g_asian_date  = 0;

// Indicator handles
int h_ema20_h1 = INVALID_HANDLE;
int h_ema50_h1 = INVALID_HANDLE;
int h_ema20_h4 = INVALID_HANDLE;
int h_ema50_h4 = INVALID_HANDLE;
int h_ema50_d1 = INVALID_HANDLE;
int h_atr_h1   = INVALID_HANDLE;
int h_atr_h4   = INVALID_HANDLE;
int h_adx_h4   = INVALID_HANDLE;

//======================================================================
// UTILITY HELPERS
//======================================================================
double Eps()
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return tick * 0.5;
}

int DigitsSymbol() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

double NormPrice(double p) { return NormalizeDouble(p, DigitsSymbol()); }

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
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   return true;
}

string TrimText(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

int ClampDashboardMax(int value)
{
   if(value < -1) return -1;
   return value;
}

int EffectiveLegacyMaxBuyPositions()
{
   return (g_dashboard_max_buy >= 0) ? g_dashboard_max_buy : MaxOpenPositions;
}

int EffectiveLegacyMaxSellPositions()
{
   return (g_dashboard_max_sell >= 0) ? g_dashboard_max_sell : MaxSellPositions;
}

int EffectiveRecoveryMaxBuyPositions()
{
   return (g_dashboard_max_buy >= 0) ? g_dashboard_max_buy : Recovery_MaxBuyPositions;
}

int EffectiveRecoveryMaxSellPositions()
{
   return (g_dashboard_max_sell >= 0) ? g_dashboard_max_sell : Recovery_MaxSellPositions;
}

void LoadDashboardControl(bool force = false)
{
   if(!DashboardControlEnabled) return;

   datetime now = TimeCurrent();
   int poll = (DashboardPollSeconds < 1) ? 3 : DashboardPollSeconds;
   if(!force && g_dashboard_last_poll > 0 && (now - g_dashboard_last_poll) < poll) return;
   g_dashboard_last_poll = now;

   int h = FileOpen(DashboardControlFile, FILE_READ | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   while(!FileIsEnding(h))
   {
      string line = TrimText(FileReadString(h));
      if(line == "" || StringSubstr(line, 0, 1) == "#") continue;

      int sep = StringFind(line, "=");
      if(sep <= 0) continue;

      string key = TrimText(StringSubstr(line, 0, sep));
      string val = TrimText(StringSubstr(line, sep + 1));

      if(key == "enabled")
         g_dashboard_ea_enabled = (StringToInteger(val) != 0);
      else if(key == "max_buy")
         g_dashboard_max_buy = ClampDashboardMax((int)StringToInteger(val));
      else if(key == "max_sell")
         g_dashboard_max_sell = ClampDashboardMax((int)StringToInteger(val));
   }

   FileClose(h);
   g_dashboard_last_load = now;
}

void WriteDashboardStatus(string state = "RUNNING")
{
   if(!DashboardControlEnabled) return;

   int h = FileOpen(DashboardStatusFile, FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   int obuy  = CountEAOpenBuyPositions();
   int osell = CountEAOpenSellPositions();
   string mode = EnableRecoveryGridMode ? (Recovery_KeepOldStrategyWhenEnabled ? "hybrid" : "recovery") : "classic";

   FileWriteString(h, "state=" + state + "\n");
   FileWriteString(h, "enabled=" + (g_dashboard_ea_enabled ? "1" : "0") + "\n");
   FileWriteString(h, "symbol=" + _Symbol + "\n");
   FileWriteString(h, "mode=" + mode + "\n");
   FileWriteString(h, "buy_positions=" + IntegerToString(obuy) + "\n");
   FileWriteString(h, "sell_positions=" + IntegerToString(osell) + "\n");
   FileWriteString(h, "total_positions=" + IntegerToString(obuy + osell) + "\n");
   FileWriteString(h, "max_buy=" + IntegerToString(EnableRecoveryGridMode ? EffectiveRecoveryMaxBuyPositions() : EffectiveLegacyMaxBuyPositions()) + "\n");
   FileWriteString(h, "max_sell=" + IntegerToString(EnableRecoveryGridMode ? EffectiveRecoveryMaxSellPositions() : EffectiveLegacyMaxSellPositions()) + "\n");
   FileWriteString(h, "dashboard_max_buy=" + IntegerToString(g_dashboard_max_buy) + "\n");
   FileWriteString(h, "dashboard_max_sell=" + IntegerToString(g_dashboard_max_sell) + "\n");
   FileWriteString(h, "floating_loss_percent=" + DoubleToString(CurrentLossPercent(), 2) + "\n");
   FileWriteString(h, "protection=" + (g_in_protection ? "1" : "0") + "\n");
   FileWriteString(h, "news_block=" + (g_in_news ? "1" : "0") + "\n");
   FileWriteString(h, "server_time=" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\n");
   FileWriteString(h, "last_control_load=" + TimeToString(g_dashboard_last_load, TIME_DATE | TIME_SECONDS) + "\n");
   FileClose(h);
}

bool DashboardAllowsNewTrading()
{
   return (!DashboardControlEnabled || g_dashboard_ea_enabled);
}

void HandleDashboardPause()
{
   if(DashboardAllowsNewTrading()) return;

   DeleteEAPendingsAll();
   RecoveryDeletePendings();

   if(EnableRecoveryGridMode)
   {
      RecoveryManageBasketEquitySL();
      RecoveryManageBasketMoneyTP();
      RecoveryManageBasketTrailing();
      if(Recovery_KeepOldStrategyWhenEnabled)
         ManagePositionsStops();
   }
   else
      ManagePositionsStops();

   Comment(
      "EA MOBILE DASHBOARD: PAUSED\n",
      "New entries are OFF. Existing positions are still managed.\n",
      "BUY pos: ", CountEAOpenBuyPositions(), " / ", (EnableRecoveryGridMode ? EffectiveRecoveryMaxBuyPositions() : EffectiveLegacyMaxBuyPositions()), "\n",
      "SELL pos: ", CountEAOpenSellPositions(), " / ", (EnableRecoveryGridMode ? EffectiveRecoveryMaxSellPositions() : EffectiveLegacyMaxSellPositions())
   );
   WriteDashboardStatus("PAUSED");
}

double StopsMinDistance()
{
   int lv = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(lv < 0) lv = 0;
   return lv * _Point;
}

double FreezeMinDistance()
{
   int lv = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(lv < 0) lv = 0;
   return lv * _Point;
}

//======================================================================
// INDICATOR INIT / RELEASE
//======================================================================
bool InitIndicators()
{
   h_ema20_h1 = iMA(_Symbol, PERIOD_H1,  20, 0, MODE_EMA, PRICE_CLOSE);
   h_ema50_h1 = iMA(_Symbol, PERIOD_H1,  50, 0, MODE_EMA, PRICE_CLOSE);
   h_ema20_h4 = iMA(_Symbol, PERIOD_H4,  20, 0, MODE_EMA, PRICE_CLOSE);
   h_ema50_h4 = iMA(_Symbol, PERIOD_H4,  50, 0, MODE_EMA, PRICE_CLOSE);
   h_ema50_d1 = iMA(_Symbol, PERIOD_D1,  50, 0, MODE_EMA, PRICE_CLOSE);
   h_atr_h1   = iATR(_Symbol, PERIOD_H1, 14);
   h_atr_h4   = iATR(_Symbol, PERIOD_H4, 14);
   h_adx_h4   = iADX(_Symbol, PERIOD_H4, 14);

   if(h_ema20_h1 == INVALID_HANDLE || h_ema50_h1 == INVALID_HANDLE ||
      h_ema20_h4 == INVALID_HANDLE || h_ema50_h4 == INVALID_HANDLE ||
      h_ema50_d1 == INVALID_HANDLE || h_atr_h1   == INVALID_HANDLE ||
      h_atr_h4   == INVALID_HANDLE || h_adx_h4   == INVALID_HANDLE)
   {
      Print("EA INIT ERROR: gagal buat indicator handles");
      return false;
   }
   return true;
}

void ReleaseIndicators()
{
   int arr[] = {h_ema20_h1, h_ema50_h1, h_ema20_h4, h_ema50_h4,
                h_ema50_d1, h_atr_h1,   h_atr_h4,   h_adx_h4};
   for(int i = 0; i < 8; i++)
      if(arr[i] != INVALID_HANDLE) IndicatorRelease(arr[i]);
}

// Read single value from indicator buffer (shift=1 → completed bar)
double GetInd(int handle, int buf = 0, int shift = 1)
{
   if(handle == INVALID_HANDLE) return EMPTY_VALUE;
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buf, shift, 1, arr) < 1) return EMPTY_VALUE;
   return arr[0];
}

//======================================================================
// MARKET STRUCTURE HELPERS
//======================================================================

// Highest H1 high over lookback completed bars
double GetH1SwingHigh(int lookback = 10)
{
   double hi = 0;
   for(int i = 1; i <= lookback; i++)
   {
      double h = iHigh(_Symbol, PERIOD_H1, i);
      if(h > hi) hi = h;
   }
   return hi;
}

// Lowest H4 low over lookback completed bars
double GetH4RecentLow(int lookback = 5)
{
   double lo = 1e10;
   for(int i = 1; i <= lookback; i++)
   {
      double l = iLow(_Symbol, PERIOD_H4, i);
      if(l < lo) lo = l;
   }
   return (lo < 1e10) ? lo : 0;
}

// Highest H4 high over lookback completed bars
double GetH4RecentHigh(int lookback = 10)
{
   double hi = 0;
   for(int i = 1; i <= lookback; i++)
   {
      double h = iHigh(_Symbol, PERIOD_H4, i);
      if(h > hi) hi = h;
   }
   return hi;
}

// Asian session range (00:00 – 07:59 server time, H1 bars)
void UpdateAsianRange()
{
   MqlDateTime dt;
   datetime server_now = TimeTradeServer();
   if(server_now <= 0) server_now = TimeCurrent();
   TimeToStruct(server_now, dt);

   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today_start = StructToTime(dt);

   if(g_asian_date == today_start && g_asian_high > 0) return; // already done

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_H1, today_start, server_now, rates);
   if(copied <= 0) return;

   double hi = 0, lo = 1e10;
   for(int i = 0; i < copied; i++)
   {
      MqlDateTime bdt;
      TimeToStruct(rates[i].time, bdt);
      if(bdt.hour >= 0 && bdt.hour <= 7)
      {
         if(rates[i].high > hi) hi = rates[i].high;
         if(rates[i].low  < lo) lo = rates[i].low;
      }
   }
   if(hi > 0 && lo < 1e10)
   {
      g_asian_high = hi;
      g_asian_low  = lo;
      g_asian_date = today_start;
   }
}

// Lower-High detection on H1 (recent 3-bar cluster vs previous 3-bar cluster)
bool IsLowerHigh_H1()
{
   double curr = 0, prev = 0;
   for(int i = 1; i <= 3; i++) { double h = iHigh(_Symbol, PERIOD_H1, i); if(h > curr) curr = h; }
   for(int i = 4; i <= 8; i++) { double h = iHigh(_Symbol, PERIOD_H1, i); if(h > prev) prev = h; }
   return (curr > 0 && prev > 0 && curr < prev);
}

// Lower-Low detection on H1
bool IsLowerLow_H1()
{
   double curr = 1e10, prev = 1e10;
   for(int i = 1; i <= 3; i++) { double l = iLow(_Symbol, PERIOD_H1, i); if(l < curr) curr = l; }
   for(int i = 4; i <= 8; i++) { double l = iLow(_Symbol, PERIOD_H1, i); if(l < prev) prev = l; }
   return (curr < 1e10 && prev < 1e10 && curr < prev);
}

// Bearish H4 trend: EMA20 < EMA50
bool IsBearishH4()
{
   double e20 = GetInd(h_ema20_h4);
   double e50 = GetInd(h_ema50_h4);
   if(e20 == EMPTY_VALUE || e50 == EMPTY_VALUE) return false;
   return e20 < e50;
}

// Bearish H1 trend: EMA20 < EMA50
bool IsBearishH1()
{
   double e20 = GetInd(h_ema20_h1);
   double e50 = GetInd(h_ema50_h1);
   if(e20 == EMPTY_VALUE || e50 == EMPTY_VALUE) return false;
   return e20 < e50;
}

// Bearish Daily: price below EMA50
bool IsBearishDaily()
{
   double d1close = iClose(_Symbol, PERIOD_D1, 1);
   double e50     = GetInd(h_ema50_d1);
   if(e50 == EMPTY_VALUE || d1close <= 0) return false;
   return d1close < e50;
}

// Ranging market: H4 ADX < MR_ADX_Max
bool IsRangingH4()
{
   double adx = GetInd(h_adx_h4, 0, 1);
   if(adx == EMPTY_VALUE) return false;
   return adx < MR_ADX_Max;
}

// Bearish engulfing on H1 shift (shift=1 = last completed bar)
bool IsBearishEngulfing_H1(int shift = 1)
{
   double o1 = iOpen (_Symbol, PERIOD_H1, shift);
   double c1 = iClose(_Symbol, PERIOD_H1, shift);
   double o2 = iOpen (_Symbol, PERIOD_H1, shift + 1);
   double c2 = iClose(_Symbol, PERIOD_H1, shift + 1);
   if(o1 <= 0 || c1 <= 0 || o2 <= 0 || c2 <= 0) return false;
   // Prev bullish, current bearish and engulfs prev body
   return (c2 > o2 && c1 < o1 && o1 >= c2 && c1 <= o2);
}

// Rejection wick: upper wick >= body * MR_MinWickRatio, on bearish H1
bool HasRejectionWick_H1(int shift = 1)
{
   double o = iOpen (_Symbol, PERIOD_H1, shift);
   double c = iClose(_Symbol, PERIOD_H1, shift);
   double h = iHigh (_Symbol, PERIOD_H1, shift);
   if(o <= 0 || c <= 0 || h <= 0) return false;
   double body       = MathAbs(c - o);
   double upper_wick = h - MathMax(o, c);
   if(body < _Point) body = _Point;
   return (c < o && upper_wick >= body * MR_MinWickRatio);
}

//======================================================================
// SPREAD & SESSION FILTERS
//======================================================================
bool IsSpreadOK()
{
   if(!EnableSpreadFilter) return true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;
   double spread = ask - bid;
   double atr = GetInd(h_atr_h1);
   if(atr == EMPTY_VALUE || atr <= 0) return true; // no data → allow
   return (spread <= atr * SpreadMaxATRRatio);
}

bool IsInTradingSession()
{
   if(!EnableSessionFilter) return true;
   MqlDateTime dt;
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   TimeToStruct(now, dt);
   if(SessionStartHour < SessionEndHour)
      return (dt.hour >= SessionStartHour && dt.hour < SessionEndHour);
   else // overnight wrap (e.g. 22 → 06)
      return (dt.hour >= SessionStartHour || dt.hour < SessionEndHour);
}

double CalcSellLot(double multiplier)
{
   double lot    = NormalizeDouble(SellLot * multiplier, 2);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   if(step > 0) lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, 2);
}

//======================================================================
// NEWS HELPERS (original, unchanged + WasLastNewsHawkish for S4)
//======================================================================
string Trim(string s)
{
   while(StringLen(s) > 0 && StringGetCharacter(s, 0) <= ' ')
      s = StringSubstr(s, 1);
   while(StringLen(s) > 0 && StringGetCharacter(s, StringLen(s) - 1) <= ' ')
      s = StringSubstr(s, 0, StringLen(s) - 1);
   return s;
}

int SplitCSV(string csv, string &out[])
{
   ArrayResize(out, 0);
   if(StringLen(csv) == 0) return 0;
   int start = 0;
   for(int i = 0; i < StringLen(csv); i++)
   {
      if(StringGetCharacter(csv, i) == ',')
      {
         string part = Trim(StringSubstr(csv, start, i - start));
         if(StringLen(part) > 0) { int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = part; }
         start = i + 1;
      }
   }
   string last = Trim(StringSubstr(csv, start));
   if(StringLen(last) > 0) { int n = ArraySize(out); ArrayResize(out, n + 1); out[n] = last; }
   return ArraySize(out);
}

string AutoCurrenciesForSymbol()
{
   string sym = _Symbol, letters = "";
   for(int i = 0; i < StringLen(sym); i++)
   {
      ushort ch = (ushort)StringGetCharacter(sym, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))
         letters += CharToString((uchar)ch);
   }
   StringToUpper(letters);
   if(StringLen(letters) >= 6)
   {
      string quote = StringSubstr(letters, 3, 3);
      return quote;
   }
   return "USD";
}

bool IsNewsWindowActive(datetime &nearest_time, string &nearest_name, string &nearest_cur)
{
   nearest_time = 0; nearest_name = ""; nearest_cur = "";
   if(!EnableNewsFilter) return false;

   datetime now   = TimeTradeServer();
   if(now <= 0)   now = TimeCurrent();
   int  b_sec     = MathMax(0, NewsMinutesBefore) * 60;
   int  a_sec     = MathMax(0, NewsMinutesAfter)  * 60;
   datetime from  = now - a_sec;
   datetime to    = now + b_sec;

   string cur_list = Trim(NewsCurrenciesOverride);
   if(StringLen(cur_list) == 0) cur_list = AutoCurrenciesForSymbol();
   string curs[];
   SplitCSV(cur_list, curs);
   if(ArraySize(curs) == 0) { ArrayResize(curs, 1); curs[0] = "USD"; }

   bool     active    = false;
   datetime best_time = 0;
   string   best_name = "", best_cur = "";

   for(int ci = 0; ci < ArraySize(curs); ci++)
   {
      string cur = Trim(curs[ci]);
      StringToUpper(cur);
      if(StringLen(cur) != 3) continue;

      MqlCalendarValue values[];
      ResetLastError();
      int n = CalendarValueHistory(values, from, to, NULL, cur);
      if(n <= 0)
      {
         if(!g_calendar_warned)
         {
            PrintFormat("NewsFilter: CalendarValueHistory n=%d err=%d", n, _LastError);
            g_calendar_warned = true;
         }
         continue;
      }
      for(int i = 0; i < n; i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance < NewsMinImportance)           continue;
         datetime t  = (datetime)values[i].time;
         datetime ws = t - b_sec, we = t + a_sec;
         if(now >= ws && now <= we)
         {
            active = true;
            long dt      = (long)MathAbs((long)(t - now));
            long best_dt = (best_time == 0) ? (long)0x7fffffff : (long)MathAbs((long)(best_time - now));
            if(best_time == 0 || dt < best_dt) { best_time = t; best_name = ev.name; best_cur = cur; }
         }
      }
   }
   nearest_time = best_time; nearest_name = best_name; nearest_cur = best_cur;
   return active;
}

// Returns true if the most recent completed High-importance USD news was hawkish
// (actual > forecast → USD strong → Gold bearish)
bool WasLastNewsHawkish()
{
   if(!EnableNewsFilter) return false;
   datetime now  = TimeTradeServer();
   if(now <= 0)  now = TimeCurrent();
   datetime from = now - 7200; // look 2h back
   datetime to   = now;

   string cur_list = Trim(NewsCurrenciesOverride);
   if(StringLen(cur_list) == 0) cur_list = AutoCurrenciesForSymbol();

   MqlCalendarValue values[];
   string curs[];
   SplitCSV(cur_list, curs);
   if(ArraySize(curs) == 0) { ArrayResize(curs, 1); curs[0] = "USD"; }

   for(int ci = 0; ci < ArraySize(curs); ci++)
   {
      string cur = Trim(curs[ci]);
      StringToUpper(cur);
      if(StringLen(cur) != 3) continue;

      int n = CalendarValueHistory(values, from, to, NULL, cur);
      if(n <= 0) continue;

      // Walk newest first
      for(int i = n - 1; i >= 0; i--)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance < NewsMinImportance)           continue;
         long actual   = values[i].actual_value;
         long forecast = values[i].forecast_value;
         // LONG_MIN sentinel (-9223372036854775808) = value not reported
         // Use threshold: any real economic value will be >> -4e18
         if(actual   < -4000000000000000000LL) continue;
         if(forecast < -4000000000000000000LL) continue;
         // Hawkish for USD = actual > forecast (positive surprise)
         return (actual > forecast);
      }
   }
   return false;
}

//======================================================================
// PROTECTION & FLOATING
//======================================================================
double TotalFloatingAllPositions()
{
   double sum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      sum += PositionGetDouble(POSITION_PROFIT);
   }
   return sum;
}

double CurrentLossPercent()
{
   double fl = TotalFloatingAllPositions();
   if(fl >= 0) return 0;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal <= 0) return 0;
   return (-fl / bal) * 100.0;
}

bool ShouldBeInProtection()
{
   if(MaxFloatingLossPercent <= 0) return false;
   return CurrentLossPercent() >= MaxFloatingLossPercent;
}

//======================================================================
// POSITION COUNTERS
//======================================================================
int CountEAOpenBuyPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      cnt++;
   }
   return cnt;
}

int CountEAOpenSellPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      cnt++;
   }
   return cnt;
}

//======================================================================
// PENDING ORDER MANAGEMENT (GRID BUY)
//======================================================================
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
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      trade.OrderDelete(ticket);
   }
}

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
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      trade.OrderDelete(ticket);
   }
}

//======================================================================
// STOP MANAGEMENT HELPERS
//======================================================================
double EffectiveTPDistance()   { return (TP_MinDistance  < 15.0) ? 15.0 : TP_MinDistance;  }
double EffectiveSellTPMin()    { return (Sell_TP_Min      < 15.0) ? 15.0 : Sell_TP_Min;     }

void AdjustStopsForBuy(double entry, double &sl, double &tp)
{
   double md = StopsMinDistance();
   if(tp > 0 && (tp - entry) < md) tp = entry + md;
   if(sl > 0 && (entry - sl) < md) sl = entry - md;
   sl = (sl > 0 ? NormPrice(sl) : 0.0);
   tp = (tp > 0 ? NormPrice(tp) : 0.0);
}

void AdjustStopsForSell(double entry, double &sl, double &tp)
{
   double md = StopsMinDistance();
   if(sl > 0 && (sl - entry) < md) sl = entry + md; // SL above entry
   if(tp > 0 && (entry - tp) < md) tp = entry - md; // TP below entry
   sl = (sl > 0 ? NormPrice(sl) : 0.0);
   tp = (tp > 0 ? NormPrice(tp) : 0.0);
}

//======================================================================
// GRID BUY – OCCUPANCY & PENDING VALIDATION
//======================================================================
bool LevelOccupiedAll(double level_price)
{
   double e = Eps();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - level_price) <= e) return true;
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - level_price) <= e) return true;
   }
   return false;
}

bool PriceLevelAllowed(ENUM_ORDER_TYPE t, double level, double bid, double ask)
{
   double md = StopsMinDistance();
   if(t == ORDER_TYPE_BUY_LIMIT && level > (bid - md)) return false;
   if(t == ORDER_TYPE_BUY_STOP  && level < (ask + md)) return false;
   return true;
}

//======================================================================
// CORE GRID BUY ENGINE (original logic, unchanged)
//======================================================================
void EnsureGrid(bool allowBuyLimit)
{
   if(!TradingAllowed()) return;
   if(GridStep <= 0 || FixedLot <= 0) return;
   if(BuyLimitCount < 0 || BuyStopCount < 0) return;

   int maxBuy = EffectiveLegacyMaxBuyPositions();
   if(maxBuy > 0 && CountEAOpenBuyPositions() >= maxBuy) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   double baseDown = RoundDownToStep(bid);
   double baseUp   = RoundUpToStep(ask);
   double tp_dist  = EffectiveTPDistance();

   if(allowBuyLimit)
   {
      for(int i = 0; i < BuyLimitCount; i++)
      {
         if(maxBuy > 0 && CountEAOpenBuyPositions() >= maxBuy) break;
         double level = NormPrice(baseDown - (i * GridStep));
         if(LevelOccupiedAll(level)) continue;
         if(!PriceLevelAllowed(ORDER_TYPE_BUY_LIMIT, level, bid, ask)) continue;
         double sl = (StopLossDistance > 0) ? level - StopLossDistance : 0.0;
         double tp = level + tp_dist;
         AdjustStopsForBuy(level, sl, tp);
         trade.BuyLimit(FixedLot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "BL grid");
      }
   }

   for(int i = 0; i < BuyStopCount; i++)
   {
      if(maxBuy > 0 && CountEAOpenBuyPositions() >= maxBuy) break;
      double level = NormPrice(baseUp + (i * GridStep));
      if(LevelOccupiedAll(level)) continue;
      if(!PriceLevelAllowed(ORDER_TYPE_BUY_STOP, level, bid, ask)) continue;
      double sl = (StopLossDistance > 0) ? level - StopLossDistance : 0.0;
      double tp = level + tp_dist;
      AdjustStopsForBuy(level, sl, tp);
      trade.BuyStop(FixedLot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "BS grid");
   }
}

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
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

      double price  = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSL  = OrderGetDouble(ORDER_SL);
      double curTP  = OrderGetDouble(ORDER_TP);
      double desTP  = NormPrice(price + tp_dist);
      double newTP  = ((curTP <= 0) || (curTP < desTP - e)) ? desTP : curTP;
      double newSL  = curSL;
      if(StopLossDistance > 0) newSL = NormPrice(price - StopLossDistance);
      AdjustStopsForBuy(price, newSL, newTP);

      bool need = ((newSL > 0 && (curSL <= 0 || MathAbs(newSL - curSL) > e)) ||
                   (newTP > 0 && (curTP <= 0 || MathAbs(newTP - curTP) > e)));
      if(need)
      {
         datetime exp  = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
         ENUM_ORDER_TYPE_TIME tt = (exp > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
         double stoplimit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
         trade.OrderModify(ticket, price, newSL, newTP, tt, exp, stoplimit);
      }
   }
}

//======================================================================
// SELL ENTRY HELPER
//======================================================================
bool CanEnterSell()
{
   if(!EnableSellEngine || !TradingAllowed()) return false;
   if(ShouldBeInProtection()) return false;
   int maxSell = EffectiveLegacyMaxSellPositions();
   if(maxSell > 0 && CountEAOpenSellPositions() >= maxSell) return false;
   int cooldown_sec = SellCooldownMinutes * 60;
   if(g_sell_last_entry > 0 && (TimeCurrent() - g_sell_last_entry) < cooldown_sec) return false;
   if(!IsSpreadOK()) return false;
   return true;
}

// Place market sell. SL = Sell_SLDistance above ask (0 = no SL, same as grid buy).
// Protection: BE + Trailing (mirrored from buy).
bool PlaceSell(string sig_comment, double lot_override = 0)
{
   if(!CanEnterSell()) return false;

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0)   return false;

   double lot     = (lot_override > 0) ? lot_override : SellLot;
   double tp_dist = EffectiveSellTPMin();
   double tp      = NormPrice(ask - tp_dist);

   // SL: 0 means no hard SL (relying on BE+Trail), same philosophy as grid buy
   double sl_price = 0.0;
   if(Sell_SLDistance > 0.0)
      sl_price = NormPrice(ask + Sell_SLDistance);

   AdjustStopsForSell(ask, sl_price, tp);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   bool ok = trade.Sell(lot, _Symbol, 0, sl_price, tp, sig_comment);
   if(ok)
   {
      g_sell_last_entry = TimeCurrent();
      PrintFormat("[SELL] %s | lot=%.2f ask=%.2f sl=%.2f tp=%.2f", sig_comment, lot, ask, sl_price, tp);
   }
   return ok;
}

//======================================================================
// SELL STRATEGIES
//======================================================================

//----------------------------------------------------------------------
// S1 – TREND FOLLOWING SELL
// Conditions: H4 bearish (EMA20<EMA50) + H1 bearish (EMA20<EMA50)
//             + LH pattern on H1 + last H1 bar bearish close
//----------------------------------------------------------------------
bool RunS1_TrendFollow()
{
   if(!Enable_S1_TrendFollow) return false;

   if(!IsBearishH4()) return false;
   if(!IsBearishH1()) return false;
   if(!IsLowerHigh_H1()) return false;

   // Last H1 bar must be bearish
   double o1 = iOpen (_Symbol, PERIOD_H1, 1);
   double c1 = iClose(_Symbol, PERIOD_H1, 1);
   if(o1 <= 0 || c1 <= 0 || c1 >= o1) return false;

   // Price below H1 EMA20 (confirm momentum)
   double ema20 = GetInd(h_ema20_h1);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ema20 != EMPTY_VALUE && ask > ema20) return false;

   return PlaceSell("S1-Trend", CalcSellLot(LotMult_S1));
}

//----------------------------------------------------------------------
// S2 – BREAKOUT-RETEST SELL
// Tracks up to 3 support levels (DailyLow, H4Low, AsianLow).
// State machine: IDLE → BREAK_CONFIRMED → WAITING_RETEST → SIGNAL
//----------------------------------------------------------------------
void UpdateBRLevels()
{
   if(BR_UseDailyLow)
   {
      double dl = iLow(_Symbol, PERIOD_D1, 1);
      if(dl > 0 && !g_br[0].active) g_br[0].level = dl;
   }
   if(BR_UseH4Low)
   {
      double h4l = GetH4RecentLow(5);
      if(h4l > 0 && !g_br[1].active) g_br[1].level = h4l;
   }
   if(BR_UseAsianLow)
   {
      UpdateAsianRange();
      if(g_asian_low > 0 && !g_br[2].active) g_br[2].level = g_asian_low;
   }
}

bool RunS2_BreakRetest()
{
   if(!Enable_S2_BreakRetest) return false;

   UpdateBRLevels();

   double h1c1  = iClose(_Symbol, PERIOD_H1, 1);
   double h1c2  = iClose(_Symbol, PERIOD_H1, 2);
   double h1o1  = iOpen (_Symbol, PERIOD_H1, 1);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(h1c1 <= 0 || h1c2 <= 0 || ask <= 0) return false;

   for(int k = 0; k < 3; k++)
   {
      double lv = g_br[k].level;
      if(lv <= 0) continue;

      if(!g_br[k].active)
      {
         // Detect fresh break: H1 close below level - buffer, prev close above
         if(h1c1 < (lv - BR_BreakBuffer) && h1c2 >= (lv - BR_BreakBuffer))
         {
            g_br[k].active          = true;
            g_br[k].waiting_retest  = true;
            g_br[k].break_time      = TimeCurrent();
         }
      }
      else
      {
         // Check expiry
         long elapsed_h = (long)(TimeCurrent() - g_br[k].break_time) / 3600;
         if(elapsed_h > (long)BR_MaxRetestHours)
         {
            g_br[k].active = false; g_br[k].waiting_retest = false;
            continue;
         }

         if(g_br[k].waiting_retest)
         {
            // Retest zone: ask returned to level ± buffer
            bool in_zone = (ask >= (lv - BR_RetestBuffer) && ask <= (lv + BR_RetestBuffer));
            if(in_zone)
            {
               // Rejection: H1 bearish close below level
               if(h1c1 < lv && h1c1 < h1o1)
               {
                  g_br[k].active         = false;
                  g_br[k].waiting_retest = false;
                  if(PlaceSell(StringFormat("S2-BR%d", k), CalcSellLot(LotMult_S2))) return true;
               }
            }
         }
      }
   }
   return false;
}

//----------------------------------------------------------------------
// S3 – MEAN-REVERSION SELL
// Conditions: ranging market (H4 ADX < max), price near resistance
//             (DailyHigh or H4 recent high), bearish confirmation
//----------------------------------------------------------------------
bool RunS3_MeanRev()
{
   if(!Enable_S3_MeanRev) return false;
   if(!IsRangingH4())      return false;

   // Not a strong uptrend (H4 EMA not strongly bullish)
   double e20h4 = GetInd(h_ema20_h4);
   double e50h4 = GetInd(h_ema50_h4);
   if(e20h4 != EMPTY_VALUE && e50h4 != EMPTY_VALUE && (e20h4 - e50h4) > 10.0) return false;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double dh    = iHigh(_Symbol, PERIOD_D1, 1);         // yesterday daily high
   double h4h   = GetH4RecentHigh(10);                  // H4 recent high
   double resist = MathMax(dh, h4h);
   if(resist <= 0) return false;

   bool near_resist = (MathAbs(ask - resist) <= MR_ResistBuffer);
   if(!near_resist) return false;

   // Bearish confirmation: rejection wick OR bearish engulfing
   bool confirmed = HasRejectionWick_H1(1) || IsBearishEngulfing_H1(1);
   if(!confirmed) return false;

   return PlaceSell("S3-MeanRev", CalcSellLot(LotMult_S3));
}

//----------------------------------------------------------------------
// S4 – NEWS-DRIVEN SELL
// Fires after news window closes if the news was hawkish for USD.
// S4 state (g_s4_pending) is set in RunLogic news-transition handler.
//----------------------------------------------------------------------
bool RunS4_NewsDriven()
{
   if(!Enable_S4_NewsDriven) return false;
   if(!g_s4_pending)         return false;

   // Check we've waited enough bars
   datetime now     = TimeCurrent();
   datetime h1_bar0 = iTime(_Symbol, PERIOD_H1, 0);
   long bars_elapsed = (long)(h1_bar0 - g_s4_window_end) / 3600;
   if(bars_elapsed < (long)S4_DelayBarsAfterNews) return false;

   if(S4_RequireBearishBar)
   {
      // Last H1 bar must be bearish
      double o1 = iOpen (_Symbol, PERIOD_H1, 1);
      double c1 = iClose(_Symbol, PERIOD_H1, 1);
      if(o1 <= 0 || c1 <= 0 || c1 >= o1) return false;
   }

   g_s4_pending = false;
   return PlaceSell("S4-News", CalcSellLot(LotMult_S4));
}

//----------------------------------------------------------------------
// S5 – FAILED BREAKOUT / LIQUIDITY SWEEP SELL
// Price breaches above recent H1 swing high but closes back below it.
// Entry on the close of that failed-breakout candle.
//----------------------------------------------------------------------
bool RunS5_FailBreak()
{
   if(!Enable_S5_FailBreak) return false;

   // Identify recent H1 high (excluding current and last bar)
   double ref_high = 0;
   for(int i = 2; i <= FB_LookbackBars + 1; i++)
   {
      double h = iHigh(_Symbol, PERIOD_H1, i);
      if(h > ref_high) ref_high = h;
   }
   if(ref_high <= 0) return false;

   // Last completed H1 bar: high breached above ref_high but close was below it
   double h1_high1  = iHigh (_Symbol, PERIOD_H1, 1);
   double h1_close1 = iClose(_Symbol, PERIOD_H1, 1);
   double h1_open1  = iOpen (_Symbol, PERIOD_H1, 1);

   double atr_h1     = GetInd(h_atr_h1);
   double dyn_buffer = (atr_h1 != EMPTY_VALUE && atr_h1 > 0) ? atr_h1 * FB_ATRMultiplier : 2.0;
   bool breached     = (h1_high1 > ref_high + dyn_buffer);
   bool closed_back = (h1_close1 < ref_high);
   bool bearish_bar = (h1_close1 < h1_open1);

   if(!breached || !closed_back || !bearish_bar) return false;

   return PlaceSell("S5-FailBrk", CalcSellLot(LotMult_S5));
}

//----------------------------------------------------------------------
// S6 – MULTI-TF CONFLUENCE SELL
// Daily bearish + H4 bearish + H1 bearish (engulfing or wick)
// Highest-quality setup → SL uses H4 ATR for larger buffer
//----------------------------------------------------------------------
bool RunS6_MTF()
{
   if(!Enable_S6_MTF) return false;

   if(!IsBearishDaily()) return false;
   if(!IsBearishH4())    return false;
   if(!IsBearishH1())    return false;

   // H1 confirmation: bearish engulfing OR rejection wick
   bool confirmed = IsBearishEngulfing_H1(1) || HasRejectionWick_H1(1);
   if(!confirmed) return false;

   // Extra filter: H4 bar also bearish (close < open)
   double h4o = iOpen (_Symbol, PERIOD_H4, 1);
   double h4c = iClose(_Symbol, PERIOD_H4, 1);
   if(h4o <= 0 || h4c <= 0 || h4c >= h4o) return false;

   return PlaceSell("S6-MTF", CalcSellLot(LotMult_S6));
}

//----------------------------------------------------------------------
// SELL ENGINE DISPATCHER
// Runs on new H1 bar (bar-close confirmation for all strategies)
//----------------------------------------------------------------------
void RunSellEngine()
{
   if(!EnableSellEngine)   return;
   if(!TradingAllowed())   return;
   if(ShouldBeInProtection()) return;
   if(!CanEnterSell())    return; // checks max pos + cooldown + spread

   bool session_ok = IsInTradingSession();

   // Run strategies in priority order; stop at first successful entry
   if(session_ok && RunS6_MTF())          return; // highest quality first
   if(session_ok && RunS1_TrendFollow())  return;
   if(session_ok && RunS5_FailBreak())    return;
   if(session_ok && RunS4_NewsDriven())   return; // state-based, may not fire
   if((session_ok || S3_AllowOutsideSession) && RunS3_MeanRev()) return;
   if(session_ok && RunS2_BreakRetest())  return;
}

//======================================================================
// STOP MANAGEMENT – BUY & SELL (BE + Trailing, runs on every tick)
//======================================================================
void ManagePositionsStops()
{
   if(!TradingAllowed()) return;

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double md    = StopsMinDistance();
   double e     = Eps();
   double tp_buy = EffectiveTPDistance();
   double tp_sel = EffectiveSellTPMin();

   trade.SetExpertMagicNumber(MagicNumber);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE ptype  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      double newSL = curSL;
      double newTP = curTP;

      if(ptype == POSITION_TYPE_BUY)
      {
         //--- Enforce min TP
         double desTP = NormPrice(entry + tp_buy);
         if(curTP <= 0 || curTP < (desTP - e)) newTP = desTP;

         //--- BE + Trail (buy)
         double dist = bid - entry;
         if(dist >= BE_Trigger)
         {
            double be = entry + BE_LockProfit; // lock profit instead of $0
            if((bid - be) >= md && (newSL <= 0 || be > newSL + e)) newSL = be;
         }
         if(dist >= (BE_Trigger + TrailDistance))
         {
            double trail = bid - TrailDistance;
            double max_ok = bid - md;
            if(trail > max_ok) trail = max_ok;
            trail = NormPrice(trail);
            if(trail > newSL + e) newSL = trail;
         }
         // Never lower SL for buy
         if(curSL > 0 && newSL > 0 && newSL < curSL - e) newSL = curSL;
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         //--- Enforce min TP (TP is BELOW entry for sell)
         double desTP = NormPrice(entry - tp_sel);
         if(curTP <= 0 || curTP > (desTP + e)) newTP = desTP;

         //--- BE + Trail (sell, mirrored)
         double dist = entry - ask; // profit distance for sell
         if(dist >= Sell_BE_Trigger)
         {
            double be = entry - Sell_BE_LockProfit; // lock profit instead of $0
            if((be - ask) >= md && (newSL <= 0 || be < newSL - e)) newSL = be;
         }
         if(dist >= (Sell_BE_Trigger + Sell_TrailDistance))
         {
            double trail   = ask + Sell_TrailDistance;
            double min_ok  = ask + md;
            if(trail < min_ok) trail = min_ok;
            trail = NormPrice(trail);
            if(newSL <= 0 || trail < newSL - e) newSL = trail;
         }
         // Never raise SL for sell (SL only moves down)
         if(curSL > 0 && newSL > 0 && newSL > curSL + e) newSL = curSL;
      }
      else continue;

      newSL = (newSL > 0 ? NormPrice(newSL) : 0.0);

      bool need = ((newSL > 0 && (curSL <= 0 || MathAbs(newSL - curSL) > e)) ||
                   (newTP > 0 && (curTP <= 0 || MathAbs(newTP - curTP) > e)));
      if(need)
      {
         double sl_send = (newSL > 0) ? newSL : curSL;
         double tp_send = (newTP > 0) ? newTP : curTP;
         trade.PositionModify(pt, sl_send, tp_send);
      }
   }
}

//======================================================================
// RECOVERY GRID MODE  (bidirectional grid recovery, mirrors target EA)
//======================================================================

// Lot sizing per level with optional stepping, normalized to broker limits.
double RecoveryCalcLot(int levelIndex)
{
   double lot = Recovery_BaseLot;
   if(Recovery_UseLotStep && Recovery_LotStepEveryLevels > 0)
      lot = Recovery_BaseLot
          + MathFloor((double)levelIndex / (double)Recovery_LotStepEveryLevels) * Recovery_LotStepAdd;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step > 0) lot = MathRound(lot / step) * step;
   if(minLot > 0 && lot < minLot) lot = minLot;
   if(maxLot > 0 && lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

// Occupancy check: is there already a pending/position on this symbol+magic
// at (or extremely close to) the requested level for the given side?
bool RecoveryLevelOccupied(double level, ENUM_ORDER_TYPE side)
{
   double e = Eps();

   // Pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(side == ORDER_TYPE_BUY_LIMIT  && ot != ORDER_TYPE_BUY_LIMIT)  continue;
      if(side == ORDER_TYPE_SELL_LIMIT && ot != ORDER_TYPE_SELL_LIMIT) continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - level) <= e) return true;
   }

   // Open positions
   ENUM_POSITION_TYPE wantPos = (side == ORDER_TYPE_BUY_LIMIT) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != wantPos) continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - level) <= e) return true;
   }
   return false;
}

// Refill BUY LIMIT grid below price (no forced TP15, optional SL/TP).
void RecoveryEnsureBuyGrid()
{
   if(!EnableRecoveryGridMode || !Recovery_EnableBuyGrid) return;
   if(!TradingAllowed()) return;
   if(Recovery_GridStep <= 0 || Recovery_BaseLot <= 0) return;
   if(Recovery_BuyLimitCount <= 0) return;

   int buyPos  = CountEAOpenBuyPositions();
   int sellPos = CountEAOpenSellPositions();
   int maxBuy  = EffectiveRecoveryMaxBuyPositions();
   if(maxBuy > 0 && buyPos >= maxBuy) return;
   if(Recovery_MaxTotalPositions > 0 && (buyPos + sellPos) >= Recovery_MaxTotalPositions) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double md = StopsMinDistance();
   double fz = FreezeMinDistance();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   // Base anchored to current price, aligned to grid step (stable across ticks).
   double baseDown = MathFloor(bid / Recovery_GridStep) * Recovery_GridStep;

   for(int i = 0; i < Recovery_BuyLimitCount; i++)
   {
      if(maxBuy > 0 && CountEAOpenBuyPositions() >= maxBuy) break;
      if(Recovery_MaxTotalPositions > 0 &&
         (CountEAOpenBuyPositions() + CountEAOpenSellPositions()) >= Recovery_MaxTotalPositions) break;

      double level = NormPrice(baseDown - i * Recovery_GridStep);
      if(level <= 0) break;

      // BUY LIMIT must sit below current Bid by at least stops/freeze level.
      if(level > (bid - md)) continue;
      if(fz > 0 && level > (bid - fz)) continue;

      if(RecoveryLevelOccupied(level, ORDER_TYPE_BUY_LIMIT)) continue;

      double lot = RecoveryCalcLot(i);
      double sl  = Recovery_UseInitialSL ? NormPrice(level - Recovery_InitialSLDistance) : 0.0;
      double tp  = Recovery_UseTP        ? NormPrice(level + Recovery_TPDistance)        : 0.0;

      trade.BuyLimit(lot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RG BL");
   }
}

// Refill SELL LIMIT grid above price (no S1-S6 market sell, no forced TP15).
void RecoveryEnsureSellGrid()
{
   if(!EnableRecoveryGridMode || !Recovery_EnableSellGrid) return;
   if(!TradingAllowed()) return;
   if(Recovery_GridStep <= 0 || Recovery_BaseLot <= 0) return;
   if(Recovery_SellLimitCount <= 0) return;

   int buyPos  = CountEAOpenBuyPositions();
   int sellPos = CountEAOpenSellPositions();
   int maxSell = EffectiveRecoveryMaxSellPositions();
   if(maxSell > 0 && sellPos >= maxSell) return;
   if(Recovery_MaxTotalPositions > 0 && (buyPos + sellPos) >= Recovery_MaxTotalPositions) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double md = StopsMinDistance();
   double fz = FreezeMinDistance();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   // Base anchored to current price, aligned to grid step.
   double baseUp = MathCeil(ask / Recovery_GridStep) * Recovery_GridStep;

   for(int i = 0; i < Recovery_SellLimitCount; i++)
   {
      if(maxSell > 0 && CountEAOpenSellPositions() >= maxSell) break;
      if(Recovery_MaxTotalPositions > 0 &&
         (CountEAOpenBuyPositions() + CountEAOpenSellPositions()) >= Recovery_MaxTotalPositions) break;

      double level = NormPrice(baseUp + i * Recovery_GridStep);
      if(level <= 0) break;

      // SELL LIMIT must sit above current Ask by at least stops/freeze level.
      if(level < (ask + md)) continue;
      if(fz > 0 && level < (ask + fz)) continue;

      if(RecoveryLevelOccupied(level, ORDER_TYPE_SELL_LIMIT)) continue;

      double lot = RecoveryCalcLot(i);
      double sl  = Recovery_UseInitialSL ? NormPrice(level + Recovery_InitialSLDistance) : 0.0;
      double tp  = Recovery_UseTP        ? NormPrice(level - Recovery_TPDistance)        : 0.0;

      trade.SellLimit(lot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RG SL");
   }
}

// Apply a single common SL to every BUY position (never lowers SL).
// Clears TP when Recovery_UseTP=false.
void RecoveryApplyBuyBasketSL(double commonSL, bool haveSL)
{
   double e = Eps();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      double newTP = Recovery_UseTP ? curTP : 0.0;
      bool slNeed  = (haveSL && (curSL <= 0 || commonSL > curSL + e)); // only raise
      bool tpNeed  = (!Recovery_UseTP && curTP > 0);                   // strip old TP

      if(slNeed || tpNeed)
      {
         double slSend = slNeed ? commonSL : curSL;
         trade.PositionModify(pt, slSend, newTP);
      }
   }
}

// Apply a single common SL to every SELL position (never raises SL).
// Clears TP when Recovery_UseTP=false.
void RecoveryApplySellBasketSL(double commonSL, bool haveSL)
{
   double e = Eps();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      double newTP = Recovery_UseTP ? curTP : 0.0;
      bool slNeed  = (haveSL && (curSL <= 0 || commonSL < curSL - e)); // only lower
      bool tpNeed  = (!Recovery_UseTP && curTP > 0);                   // strip old TP

      if(slNeed || tpNeed)
      {
         double slSend = slNeed ? commonSL : curSL;
         trade.PositionModify(pt, slSend, newTP);
      }
   }
}

// Common/basket trailing: many positions receive the same locking SL once
// the basket is sufficiently in profit. BUY and SELL baskets handled separately.
void RecoveryManageBasketTrailing()
{
   if(!EnableRecoveryGridMode) return;
   if(!TradingAllowed()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double md = StopsMinDistance();
   double fz = FreezeMinDistance();

   trade.SetExpertMagicNumber(MagicNumber);

   //=== BUY BASKET ===
   double buyLots = 0, buyWeighted = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      buyLots     += v;
      buyWeighted += PositionGetDouble(POSITION_PRICE_OPEN) * v;
   }
   if(buyLots > 0)
   {
      double avg        = buyWeighted / buyLots;
      double profitDist = bid - avg;
      double commonSL   = 0.0;
      bool   haveSL     = false;

      if(Recovery_UseBasketTrailing && profitDist >= Recovery_BasketBETrigger)
      {
         commonSL = avg + Recovery_BasketLockProfit;
         haveSL   = true;
         if(profitDist >= (Recovery_BasketBETrigger + Recovery_BasketTrailDistance))
         {
            double trailSL = bid - Recovery_BasketTrailDistance;
            if(trailSL > commonSL) commonSL = trailSL;
         }
         commonSL = NormPrice(commonSL);

         // Validate against stops/freeze level; must stay below Bid.
         if(commonSL >= (bid - md))           haveSL = false;
         if(fz > 0 && commonSL >= (bid - fz)) haveSL = false;
      }

      // Apply (also strips stale TP when Recovery_UseTP=false).
      if(haveSL || !Recovery_UseTP)
         RecoveryApplyBuyBasketSL(commonSL, haveSL);

      if(haveSL && Recovery_DeleteOppositePendingsOnBasketTrail)
         RecoveryDeletePendingsSide(ORDER_TYPE_SELL_LIMIT);
   }

   //=== SELL BASKET ===
   double sellLots = 0, sellWeighted = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      sellLots     += v;
      sellWeighted += PositionGetDouble(POSITION_PRICE_OPEN) * v;
   }
   if(sellLots > 0)
   {
      double avg        = sellWeighted / sellLots;
      double profitDist = avg - ask;
      double commonSL   = 0.0;
      bool   haveSL     = false;

      if(Recovery_UseBasketTrailing && profitDist >= Recovery_BasketBETrigger)
      {
         commonSL = avg - Recovery_BasketLockProfit;
         haveSL   = true;
         if(profitDist >= (Recovery_BasketBETrigger + Recovery_BasketTrailDistance))
         {
            double trailSL = ask + Recovery_BasketTrailDistance;
            if(trailSL < commonSL) commonSL = trailSL;
         }
         commonSL = NormPrice(commonSL);

         // Validate against stops/freeze level; must stay above Ask.
         if(commonSL <= (ask + md))           haveSL = false;
         if(fz > 0 && commonSL <= (ask + fz)) haveSL = false;
      }

      if(haveSL || !Recovery_UseTP)
         RecoveryApplySellBasketSL(commonSL, haveSL);

      if(haveSL && Recovery_DeleteOppositePendingsOnBasketTrail)
         RecoveryDeletePendingsSide(ORDER_TYPE_BUY_LIMIT);
   }
}

// Delete recovery pendings of one side (symbol+magic).
void RecoveryDeletePendingsSide(ENUM_ORDER_TYPE side)
{
   if(!TradingAllowed()) return;
   trade.SetExpertMagicNumber(MagicNumber);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != side) continue;
      trade.OrderDelete(t);
   }
}

// Delete ALL recovery pendings (BUY_LIMIT + SELL_LIMIT) on symbol+magic.
void RecoveryDeletePendings()
{
   if(!TradingAllowed()) return;
   trade.SetExpertMagicNumber(MagicNumber);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(!OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_SELL_LIMIT)
         trade.OrderDelete(t);
   }
}

//======================================================================
// RECOVERY EXIT MANAGEMENT — SELECTIVE NET CLOSE + GLOBAL BASKET CLOSE
//======================================================================

// ── Part 3: position-aggregate helpers (symbol + magic filter) ───────

// Net floating P/L (profit + swap) of all open EA positions on symbol+magic.
double RecoveryOpenNetProfit()
{
   double net = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      net += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return net;
}

// Total profit of positions currently in profit (winners only).
double RecoveryOpenWinnerProfit()
{
   double win = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pl > 0) win += pl;
   }
   return win;
}

// Total loss of positions currently in loss, returned as a POSITIVE number.
double RecoveryOpenGrossLoss()
{
   double loss = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pl < 0) loss += -pl;
   }
   return loss;
}

// Count of open EA positions on symbol+magic.
int RecoveryCountOpenPositionsByMagic()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      n++;
   }
   return n;
}

// ── Part 6: close helpers ─────────────────────────────────────────────

// Close a list of tickets one-by-one. Returns true only if ALL succeed.
bool RecoveryCloseTickets(ulong &tickets[], string reason)
{
   if(!TradingAllowed()) return false;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Recovery_CloseDeviationPoints);

   bool allOk = true;
   int n = ArraySize(tickets);
   for(int i = 0; i < n; i++)
   {
      if(tickets[i] == 0) continue;
      if(!PositionSelectByTicket(tickets[i])) continue; // already gone
      if(!trade.PositionClose(tickets[i]))
      {
         allOk = false;
         PrintFormat("[RG CLOSE] failed ticket=%I64u reason=%s retcode=%d desc=%s",
                     tickets[i], reason, trade.ResultRetcode(), trade.ResultRetcodeDescription());
         PrintFormat("[RG CLOSE FAILED] ticket=%I64u retcode=%d desc=%s",
                     tickets[i], trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
   return allOk;
}

// Collect every open EA position (symbol+magic) and close them all.
bool RecoveryCloseAllPositionsByMagic(string reason)
{
   ulong tickets[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      tickets[sz] = pt;
   }
   if(ArraySize(tickets) == 0) return true;
   return RecoveryCloseTickets(tickets, reason);
}

// ── Part 4: selective net close ───────────────────────────────────────
// Close some winners together with some losers, provided the realized
// result still leaves a net profit:
//   selectedWinnerProfit - selectedLossAmount - buffer >= target
void RecoveryManageSelectiveNetClose()
{
   if(!EnableRecoveryGridMode)               return;
   if(!Recovery_UseSelectiveNetClose)        return;
   if(g_recovery_close_in_progress)          return;
   if(TimeCurrent() < g_recovery_pause_until) return;
   if(!TradingAllowed())                     return;

   // 4) Collect winners & losers (symbol+magic)
   ulong  winTickets[];   double winPL[];
   ulong  lossTickets[];  double lossAmt[];  datetime lossTime[];
   double totalWinnerProfit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pl > 0)
      {
         int sz = ArraySize(winTickets);
         ArrayResize(winTickets, sz + 1); ArrayResize(winPL, sz + 1);
         winTickets[sz] = pt; winPL[sz] = pl;
         totalWinnerProfit += pl;
      }
      else if(pl < 0)
      {
         double amt = -pl; // positive loss amount
         if(amt < Recovery_MinLossToOffset) continue; // skip tiny losses
         int sz = ArraySize(lossTickets);
         ArrayResize(lossTickets, sz + 1); ArrayResize(lossAmt, sz + 1); ArrayResize(lossTime, sz + 1);
         lossTickets[sz] = pt; lossAmt[sz] = amt;
         lossTime[sz] = (datetime)PositionGetInteger(POSITION_TIME);
      }
   }

   if(ArraySize(winTickets) == 0 || ArraySize(lossTickets) == 0) return;

   // 7) Loss budget payable by winners while still leaving target+buffer.
   double lossBudget = totalWinnerProfit - Recovery_SelectiveNetTarget - Recovery_SelectiveCloseBuffer;
   if(lossBudget <= 0) return;                                   // 8)
   if(Recovery_MaxLossClosePerPass > 0 && lossBudget > Recovery_MaxLossClosePerPass)
      lossBudget = Recovery_MaxLossClosePerPass;                 // 10) cap

   // 9-11) Pick losers: largest loss first (still payable by remaining budget).
   //       Sort indices by loss amount desc; tie-break by oldest float.
   int lcount = ArraySize(lossTickets);
   int lidx[];
   ArrayResize(lidx, lcount);
   for(int i = 0; i < lcount; i++) lidx[i] = i;
   for(int a = 0; a < lcount - 1; a++)
      for(int b = a + 1; b < lcount; b++)
      {
         bool swap = (lossAmt[lidx[b]] > lossAmt[lidx[a]]) ||
                     (lossAmt[lidx[b]] == lossAmt[lidx[a]] && lossTime[lidx[b]] < lossTime[lidx[a]]);
         if(swap) { int tmp = lidx[a]; lidx[a] = lidx[b]; lidx[b] = tmp; }
      }

   ulong  selLoss[];
   double selectedLossAmount = 0.0;
   double remaining = lossBudget;
   for(int i = 0; i < lcount; i++)
   {
      int idx = lidx[i];
      if(Recovery_MaxTicketsClosePerPass > 0 &&
         ArraySize(selLoss) >= Recovery_MaxTicketsClosePerPass) break;
      if(lossAmt[idx] <= remaining)
      {
         int sz = ArraySize(selLoss);
         ArrayResize(selLoss, sz + 1);
         selLoss[sz] = lossTickets[idx];
         selectedLossAmount += lossAmt[idx];
         remaining          -= lossAmt[idx];
      }
   }

   if(ArraySize(selLoss) == 0 || selectedLossAmount <= 0) return;

   // 13) Pick just enough winners to cover loss + target + buffer.
   double needWin = selectedLossAmount + Recovery_SelectiveNetTarget + Recovery_SelectiveCloseBuffer;

   // Sort winners by profit desc so fewest tickets are needed.
   int wcount = ArraySize(winTickets);
   int widx[];
   ArrayResize(widx, wcount);
   for(int i = 0; i < wcount; i++) widx[i] = i;
   for(int a = 0; a < wcount - 1; a++)
      for(int b = a + 1; b < wcount; b++)
         if(winPL[widx[b]] > winPL[widx[a]])
         { int tmp = widx[a]; widx[a] = widx[b]; widx[b] = tmp; }

   ulong  selWin[];
   double selectedWinnerProfit = 0.0;
   for(int i = 0; i < wcount; i++)
   {
      if(selectedWinnerProfit >= needWin) break;     // 14) don't over-close
      int idx = widx[i];
      int sz  = ArraySize(selWin);
      ArrayResize(selWin, sz + 1);
      selWin[sz] = winTickets[idx];
      selectedWinnerProfit += winPL[idx];
   }

   // 15) Final validation before any execution.
   double netResult = selectedWinnerProfit - selectedLossAmount - Recovery_SelectiveCloseBuffer;
   if(netResult < Recovery_SelectiveNetTarget) return;

   // 16) Execute.
   PrintFormat("[RG SELECTIVE CLOSE] win=%.2f loss=%.2f net=%.2f target=%.2f buffer=%.2f",
               selectedWinnerProfit, selectedLossAmount, netResult,
               Recovery_SelectiveNetTarget, Recovery_SelectiveCloseBuffer);

   g_recovery_close_in_progress = true;
   Print("[RG CLOSE] delete pendings before close");
   RecoveryDeletePendings(); // stop new orders entering mid-close

   bool okWin  = RecoveryCloseTickets(selWin,  "selective-winner");
   bool okLoss = RecoveryCloseTickets(selLoss, "selective-loser");

   Print("[RG CLOSE] delete pendings after close");
   RecoveryDeletePendings();

   g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

   // 17) If everything closed, release the in-progress flag; otherwise the
   //     close-in-progress handler retries on subsequent ticks.
   if(okWin && okLoss)
      g_recovery_close_in_progress = false;
}

// ── Part 5: global basket close ───────────────────────────────────────
// Close ALL active positions + clear pendings when total net profit of the
// symbol+magic basket reaches a large target.
void RecoveryManageGlobalBasketClose()
{
   if(!EnableRecoveryGridMode)               return;
   if(!Recovery_UseGlobalBasketClose)        return;
   if(g_recovery_close_in_progress)          return;
   if(TimeCurrent() < g_recovery_pause_until) return;
   if(!TradingAllowed())                     return;

   if(RecoveryCountOpenPositionsByMagic() == 0) return;

   double netProfit = RecoveryOpenNetProfit();
   if(netProfit < (Recovery_GlobalBasketMoneyTP + Recovery_GlobalBasketCloseBuffer)) return;

   PrintFormat("[RG GLOBAL CLOSE] openNet=%.2f target=%.2f buffer=%.2f",
               netProfit, Recovery_GlobalBasketMoneyTP, Recovery_GlobalBasketCloseBuffer);

   g_recovery_close_in_progress = true;
   Print("[RG CLOSE] delete pendings before close");
   RecoveryDeletePendings();

   bool ok = RecoveryCloseAllPositionsByMagic("global-basket");

   Print("[RG CLOSE] delete pendings after close");
   RecoveryDeletePendings();

   g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

   // Only release the flag if the whole basket is gone; otherwise retry.
   if(ok && RecoveryCountOpenPositionsByMagic() == 0)
      g_recovery_close_in_progress = false;
}

// ── Part 7: close-in-progress handler ─────────────────────────────────
// While a close is in progress, never refill the grid. Keep retrying the
// close until the basket is empty, then arm the cooldown.
void RecoveryHandleCloseInProgress()
{
   if(!g_recovery_close_in_progress) return;

   RecoveryDeletePendings();

   if(RecoveryCountOpenPositionsByMagic() > 0)
   {
      RecoveryCloseAllPositionsByMagic("retry-close-in-progress");
      if(RecoveryCountOpenPositionsByMagic() > 0)
         return; // still failing → wait for next tick, no refill
   }

   // Basket cleared.
   RecoveryDeletePendings();
   g_recovery_close_in_progress = false;
   g_recovery_pause_until       = TimeCurrent() + Recovery_CloseCooldownSeconds;
}

// Floating-profit basket take-profit. When the net profit of all positions
// on symbol+magic reaches the target, close the whole basket together.
void RecoveryManageBasketMoneyTP()
{
   if(!EnableRecoveryGridMode)       return;
   if(!Recovery_UseBasketMoneyTP)    return;
   if(!TradingAllowed())             return;
   if(Recovery_BasketMoneyTP <= 0)   return;

   ulong  tickets[];
   double netProfit = 0.0;   // all open positions on symbol+magic
   double winProfit = 0.0;   // diagnostic only
   int    n = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double pl = PositionGetDouble(POSITION_PROFIT);
      if(Recovery_BasketMoneyTP_InclSwap)
         pl += PositionGetDouble(POSITION_SWAP);

      netProfit += pl;
      if(pl > 0) winProfit += pl;

      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      tickets[sz] = pt;
      n++;
   }

   if(n == 0) return;
   if(netProfit < Recovery_BasketMoneyTP) return;

   // Target reached → close the collected positions.
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   int closed = 0;
   for(int i = 0; i < n; i++)
   {
      if(trade.PositionClose(tickets[i]))
         closed++;
      else
         PrintFormat("[RG BASKET TP] close failed ticket=%I64u ret=%d %s",
                     tickets[i], trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   // Remove stale recovery pendings; the next cycle rebuilds the grid around current price.
   RecoveryDeletePendings();

   PrintFormat("[RG BASKET TP] closed %d/%d position(s), net=%.2f winners=%.2f target=%.2f",
               closed, n, netProfit, winProfit, Recovery_BasketMoneyTP);
}

// Equity-based basket stop-loss (hard tail-risk guard). When the floating loss
// of all EA positions (symbol+magic) reaches a percentage of account EQUITY,
// close the entire basket and clear pendings. Equity is used (not balance)
// because it tracks live account health and aligns with broker margin/stop-out.
void RecoveryManageBasketEquitySL()
{
   if(!EnableRecoveryGridMode)              return;
   if(!Recovery_UseBasketEquitySL)          return;
   if(!TradingAllowed())                    return;
   if(Recovery_BasketEquitySL_Percent <= 0) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0) return;

   ulong  tickets[];
   double floating = 0.0;   // net floating P/L of EA positions
   int    n = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double pl = PositionGetDouble(POSITION_PROFIT);
      if(Recovery_BasketEquitySL_InclSwap)
         pl += PositionGetDouble(POSITION_SWAP);
      floating += pl;

      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      tickets[sz] = pt;
      n++;
   }

   if(n == 0)        return;
   if(floating >= 0) return;   // only a loss can trigger the cut

   double lossPct = (-floating / equity) * 100.0;
   if(lossPct < Recovery_BasketEquitySL_Percent) return;

   // Breach → close the whole basket and clear pendings.
   // Failed closes (requote/slippage) are retried on the next tick since the
   // breach condition still holds.
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   int closed = 0;
   for(int i = 0; i < n; i++)
   {
      if(trade.PositionClose(tickets[i]))
         closed++;
      else
         PrintFormat("[RG BASKET SL] close failed ticket=%I64u ret=%d %s",
                     tickets[i], trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   RecoveryDeletePendings();

   PrintFormat("[RG BASKET SL] closed %d/%d position(s), floatingLoss=%.2f (%.2f%% of equity %.2f, limit %.2f%%)",
               closed, n, floating, lossPct, equity, Recovery_BasketEquitySL_Percent);
}

// Recovery-mode main cycle (risk protection + news + grid refill + basket trail).
void RunRecoveryLogic()
{
   LoadDashboardControl();
   if(!DashboardAllowsNewTrading())
   {
      HandleDashboardPause();
      return;
   }
   // ── News filter ───────────────────────────────────────────────────
   datetime ntime; string nname, ncur;
   bool news_active = IsNewsWindowActive(ntime, nname, ncur);

   if(news_active && !g_in_news)
   {
      if(DeletePendingsDuringNews) RecoveryDeletePendings();
      g_in_news = true;
   }
   else if(!news_active && g_in_news)
      g_in_news = false;

   // ── Floating loss protection ──────────────────────────────────────
   bool shouldProtect = ShouldBeInProtection();
   if(shouldProtect && !g_in_protection)
   { RecoveryDeletePendings(); g_in_protection = true; }
   else if(!shouldProtect && g_in_protection)
      g_in_protection = false;

   int effMaxBuy  = EffectiveRecoveryMaxBuyPositions();
   int effMaxSell = EffectiveRecoveryMaxSellPositions();
   if(effMaxBuy > 0 && CountEAOpenBuyPositions() >= effMaxBuy)
      RecoveryDeletePendingsSide(ORDER_TYPE_BUY_LIMIT);
   if(effMaxSell > 0 && CountEAOpenSellPositions() >= effMaxSell)
      RecoveryDeletePendingsSide(ORDER_TYPE_SELL_LIMIT);

   // ── Exit management FIRST (selective net close + global basket close) ──
   //    These must run, and complete, before any grid refill so we never
   //    refill on the same tick/trade transaction that closed a basket.
   RecoveryHandleCloseInProgress();
   if(g_recovery_close_in_progress)
   {
      RecoveryDeletePendings();
      return;
   }
   if(TimeCurrent() < g_recovery_pause_until)
   {
      Print("[RG PAUSE] waiting cooldown before grid refill");
      RecoveryDeletePendings();
      return;
   }

   RecoveryManageSelectiveNetClose();
   if(g_recovery_close_in_progress)
   {
      RecoveryDeletePendings();
      return;
   }

   RecoveryManageGlobalBasketClose();
   if(g_recovery_close_in_progress)
   {
      RecoveryDeletePendings();
      return;
   }

   // A close may have armed the cooldown; respect it before refilling.
   if(TimeCurrent() < g_recovery_pause_until)
   {
      Print("[RG PAUSE] waiting cooldown before grid refill");
      RecoveryDeletePendings();
      return;
   }

   // ── Grid refill (only when no news / no protection) ───────────────
   if(!news_active && !shouldProtect)
   {
      RecoveryEnsureBuyGrid();
      RecoveryEnsureSellGrid();
   }
   else
   {
      // Keep recovery pendings cleared while protection/news is active.
      RecoveryDeletePendings();
   }

   // ── Basket equity stop-loss (hard tail-risk guard, every tick) ────
   RecoveryManageBasketEquitySL();

   // ── Basket / common trailing (also runs on every tick) ────────────
   RecoveryManageBasketMoneyTP();
   RecoveryManageBasketTrailing();

   // ── HUD ───────────────────────────────────────────────────────────
   double lp    = CurrentLossPercent();
   int    obuy  = CountEAOpenBuyPositions();
   int    osell = CountEAOpenSellPositions();
   string stP   = g_in_protection ? "⚠ PROTECTION ON" : "OK";
   string stN   = news_active      ? "⚠ NEWS BLOCK ON" : "OK";
   string ninfo = "";
   if(news_active && ntime > 0)
      ninfo = StringFormat("  → %s (%s) @ %s", nname, ncur, TimeToString(ntime, TIME_DATE|TIME_MINUTES));

   Comment(
      "══ RECOVERY GRID MODE (XAUUSD bidirectional) ══\n",
      "News   : ", stN, ninfo, "\n",
      "Protect: ", stP, "\n",
      "Dashboard: ", (g_dashboard_ea_enabled ? "ON" : "OFF"), "\n",
      "BUY pos: ", obuy,  " / ", (effMaxBuy  > 0 ? IntegerToString(effMaxBuy)  : "∞"),
      "  |  SELL pos: ", osell, " / ", (effMaxSell > 0 ? IntegerToString(effMaxSell) : "∞"), "\n",
      "Total pos: ", (obuy + osell), " / ", (Recovery_MaxTotalPositions > 0 ? IntegerToString(Recovery_MaxTotalPositions) : "∞"), "\n",
      "Floating loss: ", DoubleToString(lp, 2), "% (limit ", DoubleToString(MaxFloatingLossPercent, 1), "%)\n",
      "Grid step: ", DoubleToString(Recovery_GridStep, 2),
      "  BL levels: ", IntegerToString(Recovery_BuyLimitCount),
      "  SL levels: ", IntegerToString(Recovery_SellLimitCount), "\n",
      "Basket  → BE:", DoubleToString(Recovery_BasketBETrigger, 2),
      " lock+", DoubleToString(Recovery_BasketLockProfit, 2),
      "  trail:", DoubleToString(Recovery_BasketTrailDistance, 2), "\n",
      "TP:", (Recovery_UseTP ? DoubleToString(Recovery_TPDistance,2) : "OFF"),
      "  InitSL:", (Recovery_UseInitialSL ? DoubleToString(Recovery_InitialSLDistance,2) : "OFF"), "\n",
      "Basket MoneyTP: ", (Recovery_UseBasketMoneyTP ? DoubleToString(Recovery_BasketMoneyTP,2) : "OFF"),
      (Recovery_UseBasketMoneyTP ? (Recovery_BasketMoneyTP_ProfitOnly ? " (legacy ignored: net basket)" : " (net basket)") : ""), "\n",
      "Basket EquitySL: ", (Recovery_UseBasketEquitySL ? (DoubleToString(Recovery_BasketEquitySL_Percent,1) + "% equity") : "OFF")
   );
}

//======================================================================
// MAIN LOGIC CYCLE
//======================================================================
void RunLogic()
{
   // ── Recovery Grid Mode takes over (bypass old grid/sell strategy) ──
   if(EnableRecoveryGridMode && !Recovery_KeepOldStrategyWhenEnabled)
   {
      RunRecoveryLogic();
      return;
   }

   // ── 0) New H1 bar? → run sell engine ──────────────────────────────
   datetime cur_h1 = iTime(_Symbol, PERIOD_H1, 0);
   bool new_h1 = (cur_h1 != 0 && cur_h1 != g_last_h1_bar);
   if(new_h1) g_last_h1_bar = cur_h1;

   // ── 1) Max BUY position cap ───────────────────────────────────────
   if(MaxOpenPositions > 0)
   {
      int ob = CountEAOpenBuyPositions();
      if(ob >= MaxOpenPositions && !g_in_maxpos)
      { DeleteEAPendingsAll(); g_in_maxpos = true; }
      else if(ob < MaxOpenPositions && g_in_maxpos)
         g_in_maxpos = false;
   }

   // ── 2) Max SELL position cap ──────────────────────────────────────
   if(MaxSellPositions > 0)
   {
      int os = CountEAOpenSellPositions();
      if(os >= MaxSellPositions && !g_in_maxpos_sell)
         g_in_maxpos_sell = true;
      else if(os < MaxSellPositions && g_in_maxpos_sell)
         g_in_maxpos_sell = false;
   }

   // ── 3) News filter ────────────────────────────────────────────────
   datetime ntime; string nname, ncur;
   bool news_active = IsNewsWindowActive(ntime, nname, ncur);

   if(news_active && !g_in_news)
   {
      if(DeletePendingsDuringNews) DeleteEAPendingsAll();
      g_in_news = true;
   }
   else if(!news_active && g_in_news)
   {
      // News window just closed → check S4 hawkish trigger
      if(Enable_S4_NewsDriven && WasLastNewsHawkish())
      {
         g_s4_pending    = true;
         g_s4_window_end = TimeCurrent();
      }
      g_in_news = false;
   }

   // ── 4) Floating loss protection ───────────────────────────────────
   bool shouldProtect = ShouldBeInProtection();
   if(shouldProtect && !g_in_protection)
   { DeleteEABuyLimitPendings(); g_in_protection = true; }
   else if(!shouldProtect && g_in_protection)
      g_in_protection = false;

   // ── 5) Enforce pending TP on grid buy ────────────────────────────
   EnforcePendingStops();

   // ── 6) Grid buy refill (blocked during news) ─────────────────────
   if(!news_active)
      EnsureGrid(!g_in_protection);

   // ── 7) Sell engine (on new H1 bar, no news, no protection) ───────
   if(new_h1 && !news_active && !shouldProtect)
      RunSellEngine();

   // ── 8) Also check S4 (state-driven, runs every scan) ─────────────
   if(!news_active && g_s4_pending && !shouldProtect)
      RunS4_NewsDriven();

   // ── 8b) Recovery grid alongside old strategy (KeepOld=true) ──────
   if(EnableRecoveryGridMode && Recovery_KeepOldStrategyWhenEnabled)
   {
      if(!news_active && !shouldProtect)
      {
         RecoveryEnsureBuyGrid();
         RecoveryEnsureSellGrid();
      }
      else
         RecoveryDeletePendings();
      RecoveryManageBasketTrailing();
   }

   // ── 9) HUD Comment ───────────────────────────────────────────────
   double lp     = CurrentLossPercent();
   int    obuy   = CountEAOpenBuyPositions();
   int    osell  = CountEAOpenSellPositions();
   string stP    = g_in_protection  ? "⚠ PROTECTION ON"  : "OK";
   string stN    = news_active       ? "⚠ NEWS BLOCK ON"  : "OK";
   string ninfo  = "";
   if(news_active && ntime > 0)
      ninfo = StringFormat("  → %s (%s) @ %s", nname, ncur, TimeToString(ntime, TIME_DATE|TIME_MINUTES));

   Comment(
      "══ EA: XAUUSD Grid Buy + Smart Sell v2.0 ══\n",
      "News   : ", stN, ninfo, "\n",
      "Protect: ", stP, "\n",
      "BUY pos: ", obuy,  " / ", (MaxOpenPositions  > 0 ? IntegerToString(MaxOpenPositions)  : "∞"),
      "  |  SELL pos: ", osell, " / ", (MaxSellPositions > 0 ? IntegerToString(MaxSellPositions) : "∞"), "\n",
      "Floating loss: ", DoubleToString(lp, 2), "% (limit ", DoubleToString(MaxFloatingLossPercent, 1), "%)\n",
      "BUY  → TP:", DoubleToString(EffectiveTPDistance(), 1),
      "  BE:", DoubleToString(BE_Trigger, 1),
      " (lock+", DoubleToString(BE_LockProfit, 1), ")",
      "  Trail:", DoubleToString(TrailDistance, 1), "\n",
      "SELL → TP:", DoubleToString(EffectiveSellTPMin(), 1),
      "  BE:", DoubleToString(Sell_BE_Trigger, 1),
      " (lock+", DoubleToString(Sell_BE_LockProfit, 1), ")",
      "  Trail:", DoubleToString(Sell_TrailDistance, 1), "\n",
      "S4 pending: ", (g_s4_pending ? "YES" : "no"),
      "  Cooldown left: ", IntegerToString(
         (int)MathMax(0, SellCooldownMinutes * 60 - (int)(TimeCurrent() - g_sell_last_entry)) / 60), "m"
   );
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_scan_interval = (ScanInterval < 1) ? 60 : ScanInterval;

   // Init indicator handles (sell engine)
   if(!InitIndicators()) return INIT_FAILED;

   // Init BRState
   for(int k = 0; k < 3; k++)
   {
      g_br[k].active         = false;
      g_br[k].waiting_retest = false;
      g_br[k].level          = 0;
      g_br[k].break_time     = 0;
   }

   g_sell_last_entry = 0;
   g_s4_pending      = false;
   g_last_h1_bar     = 0;

   EventSetTimer(g_scan_interval);
   RunLogic();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseIndicators();
   Comment("");
}

void OnTimer()
{
   RunLogic();
}

void OnTick()
{
   // Stop management (BE + Trailing) runs on every tick for fast response
   if(EnableRecoveryGridMode)
   {
      // ── Exit management runs first, before any trailing/refill. ──────
      RecoveryHandleCloseInProgress();

      if(!g_recovery_close_in_progress && TimeCurrent() >= g_recovery_pause_until)
      {
         RecoveryManageSelectiveNetClose();
         RecoveryManageGlobalBasketClose();
      }

      // While a close is in progress, skip trailing/basket TP entirely.
      if(g_recovery_close_in_progress)
         return;

      // Recovery basket/common trailing reacts fast on every tick.
      RecoveryManageBasketEquitySL();
      RecoveryManageBasketMoneyTP();
      RecoveryManageBasketTrailing();
      if(Recovery_KeepOldStrategyWhenEnabled)
         ManagePositionsStops();
   }
   else
   {
      ManagePositionsStops();
   }
}

void OnTradeTransaction(const MqlTradeTransaction &,
                        const MqlTradeRequest &,
                        const MqlTradeResult &)
{
   RunLogic(); // refresh grid + sell state after any trade event
}
//+------------------------------------------------------------------+

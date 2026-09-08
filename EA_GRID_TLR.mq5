//+------------------------------------------------------------------+
//| EA: XAUUSD Recovery Grid Side Net Basket                        |
//|                                                                  |
//| Recovery-only engine:                                            |
//|   BUY/SELL recovery grid                                       |
//|   Trend/DD brake + counter recovery                            |
//|   Side/global/selective net-profit exits                       |
//+------------------------------------------------------------------+
#property strict
#property copyright "XAUUSD Recovery Grid EA"
#property version   "2.00"

#include <Trade/Trade.mqh>
CTrade trade;

enum RecoveryTrendMode
{
   TREND_BUY_ONLY,
   TREND_SELL_ONLY,
   TREND_BOTH,
   TREND_PAUSE
};

enum RecoveryCounterState
{
   COUNTER_IDLE,          // kondisi normal
   COUNTER_SOFT_BRAKE,    // floating mulai bahaya, stop tambah sisi rusak
   COUNTER_ACTIVE,        // counter grid aktif
   COUNTER_OFFSET_CLOSE,  // profit counter dipakai close loser lama
   COUNTER_RECOVERED      // basket sudah bersih / DD turun
};

//======================================================================
// INPUT PARAMETERS
//======================================================================

// --- RISK & TIMER ---
input group "=== RISK & TIMER ==="
input double MaxFloatingLossPercent = 60.0;   // Max floating loss % → protection
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
input int    Recovery_MaxBuyPositions                  = 75;      // Max BUY positions (0=unlimited)
input int    Recovery_MaxSellPositions                 = 75;      // Max SELL positions (0=unlimited)
input int    Recovery_MaxTotalPositions                = 150;      // Max total positions (0=unlimited)
input bool   Recovery_UseTP                            = false;  // Attach TP to grid orders
input double Recovery_TPDistance                       = 0.0;    // TP distance (USD) if UseTP
input bool   Recovery_UseInitialSL                     = false;  // ⚠ CUT-LOSS! true=pasang SL per order grid (bisa realisasi rugi per posisi). Biarkan false utk no-SL
input double Recovery_InitialSLDistance                = 0.0;    // ⚠ Hanya aktif jika UseInitialSL=true. Jarak SL (USD) per order
input bool   Recovery_UseBasketTrailing                = true;   // Common/basket trailing SL
input double Recovery_BasketBETrigger                  = 1.50;   // Basket BE trigger distance (USD)
input double Recovery_BasketLockProfit                 = 0.30;   // Profit lock when BE triggers (USD)
input double Recovery_BasketTrailDistance              = 0.50;   // Basket trailing distance (USD)
input bool   Recovery_DeleteOppositePendingsOnBasketTrail = false; // Delete opposite pendings when basket trails
input bool   Recovery_UseBasketMoneyTP                 = true;   // Close basket on floating-profit target
input double Recovery_BasketMoneyTP                    = 300.0;  // Target profit in ACCOUNT currency (cent acc: 500=$5)
input bool   Recovery_BasketMoneyTP_ProfitOnly         = false;  // Legacy toggle; false = close whole basket by net P/L
input bool   Recovery_BasketMoneyTP_InclSwap           = true;   // Include swap in profit calc
input bool   Recovery_UseSideBasketMoneyTP             = true;   // Close BUY/SELL side basket by NET P/L
input double Recovery_BuyBasketTPMoney                 = 100.0;  // BUY side net target in ACCOUNT currency
input double Recovery_SellBasketTPMoney                = 100.0;  // SELL side net target in ACCOUNT currency
input bool   Recovery_SideBasketMoneyTP_InclSwap       = true;   // Include swap in side net profit calc
input bool   Recovery_UseBasketEquitySL                = false;   // ⚠ CUT-LOSS! true=close seluruh basket rugi saat DD equity. Biarkan false utk mode "tidak pernah cut loss"
input double Recovery_BasketEquitySL_Percent           = 25.0;   // ⚠ Hanya aktif jika UseBasketEquitySL=true. Close ALL (realisasi rugi) bila floating loss >= % equity ini
input bool   Recovery_BasketEquitySL_InclSwap          = true;   // Include swap in floating loss calc

input group "=== RECOVERY SELECTIVE NET CLOSE ==="
input bool   Recovery_UseSelectiveNetClose       = true;
input double Recovery_SelectiveNetTarget         = 100.0;   // profit bersih minimal setelah close winner + loser
input double Recovery_SelectiveCloseBuffer       = 30.0;    // cadangan spread/slippage/komisi
input double Recovery_MinLossToOffset            = 20.0;    // minimal loss yang layak ditutup
input double Recovery_MaxLossClosePerPass        = 300.0;   // batas total loss yang boleh ditutup per siklus close
input int    Recovery_MaxTicketsClosePerPass     = 20;      // batas jumlah posisi yang ditutup sekali jalan
input int    Recovery_CloseCooldownSeconds       = 30;      // pause refill setelah close

input group "=== RECOVERY CLOSE EXECUTION GUARD ==="
input bool   Recovery_PrecloseRecheckNet         = true;    // Re-check live net sebelum close massal/offset
input double Recovery_CloseSlipBufferPerLot      = 0.0;     // Tambahan buffer per 1.00 lot saat preclose (0=off)

input group "=== RECOVERY GLOBAL BASKET CLOSE ==="
input bool   Recovery_UseGlobalBasketClose       = true;
input double Recovery_GlobalBasketMoneyTP        = 250.0;   // kalau total semua posisi aktif sudah profit sebesar ini, close all
input double Recovery_GlobalBasketCloseBuffer    = 30.0;
input int    Recovery_CloseDeviationPoints       = 50;

input group "=== RECOVERY TREND / DD BRAKE ==="
input bool            Recovery_UseTrendFilter              = true;      // Guard arah grid, bukan trigger entry lambat
input ENUM_TIMEFRAMES Recovery_TrendTF                     = PERIOD_H1;
input ENUM_TIMEFRAMES Recovery_GuardTF                     = PERIOD_H4;
input int             Recovery_TrendFastEMA                = 50;
input int             Recovery_TrendSlowEMA                = 200;
input int             Recovery_ADXPeriod                   = 14;
input double          Recovery_ADXTrendMin                 = 20.0;
input double          Recovery_ADXRangeMax                 = 18.0;
input int             Recovery_DirectionConfirmBars        = 1;
input int             Recovery_DirectionCooldownMinutes    = 15;
input bool            Recovery_DontFlipIfSideDDActive      = true;
input bool            Recovery_UseSideDDBrake              = true;
input double          Recovery_SideDDSoftLimitMoney        = 1000.0;
input bool            Recovery_DeleteSameSidePendingsOnDD  = true;
input bool            Recovery_PauseSameSideGridOnDD       = true;
input bool            Recovery_ConvertPauseToCounterOnDD   = false;     // false=PAUSE konflik sinyal -> EA tunggu sinyal arah (TIDAK nebak counter). true=paksa counter saat PAUSE+DD
input int             Recovery_PauseHudReferenceMinutes    = 45;        // HUD: acuan durasi PAUSE (info saja, bukan trigger aksi)
input double          Recovery_MaxDistanceFromFastEMA_ATR  = 2.5;       // Pause kalau harga terlalu jauh dari EMA cepat (0=off)
input bool            Recovery_FarEMA_PreferTrend          = true;      // Saat harga jauh dari EMA + ADX kuat: ikut trend (bukan PAUSE)
input bool            Recovery_CloseADXDeadZone            = true;      // Tutup gap ADX 18-20: zona tanggung pakai arah EMA, bukan PAUSE
input bool            Recovery_IgnoreGuardWhenH1Strong     = true;      // Abaikan guard H4 saat H1 jelas+ADX kuat (kurangi PAUSE konflik H1/H4)
input double          Recovery_IgnoreGuardADXMin           = 25.0;      // ADX min agar guard H4 boleh diabaikan
input bool            Recovery_RelaxGuardOnLongPause       = true;      // Saat PAUSE > acuan menit: longgarkan ambang ignore-guard agar lebih cepat dapat arah (tetap ikut trend)
input double          Recovery_RelaxGuardADXMin            = 20.0;      // Ambang ADX ignore-guard saat PAUSE lama (lebih rendah dari IgnoreGuardADXMin)
input bool            Recovery_BothWhenMomentumConflict    = true;      // Arah tak pasti (struktur EMA vs harga thd EMA50 konflik) -> buka BOTH, bukan satu arah

input group "=== TOTAL LOSS TREND RECOVERY ==="
input bool   Recovery_UseTotalLossTrendRecovery = true;    // Aktifkan entry tambahan saat total floating loss besar
input double Recovery_TotalLossTrendStartMoney  = 2000.0;  // Trigger saat net floating basket <= -nilai ini
input double Recovery_TL_BaseLot                = 0.01;    // Lot awal TLR
input double Recovery_TL_LossStepMoney          = 1000.0;  // Tiap tambahan loss sebesar ini, lot naik
input double Recovery_TL_LotAddPerStep          = 0.01;    // Tambahan lot per step loss
input double Recovery_TL_MaxLot                 = 0.05;    // Maks lot per entry TLR
input int    Recovery_TL_MaxPositions           = 10;      // Maks posisi TLR aktif
input double Recovery_TL_MaxTotalLot            = 0.30;    // Maks total lot TLR aktif
input double Recovery_TL_MinMarginLevel         = 500.0;   // Min margin level % untuk entry TLR (0=abaikan)
input int    Recovery_TL_CooldownMinutes        = 15;      // Cooldown antar entry TLR
input bool   Recovery_TL_BlockDamagedSide       = true;    // Jangan tambah TLR ke sisi yang sedang DD; wajib counter searah trend

// --- RECOVERY COUNTER (Bagian C) ---
input group "=== RECOVERY COUNTER ==="
input bool   Recovery_UseCounterRecovery    = true;    // Master ON/OFF counter recovery
input double Recovery_CounterStartLossMoney = 500.0;   // Floating sisi rusak (ACCOUNT cur) → aktifkan counter
input double Recovery_CounterHardLossMoney  = 1500.0;  // Floating sisi rusak → hard recovery mode
input bool   Recovery_CounterRequireTrend   = true;    // Counter hanya saat trend filter mendukung arah counter
input double Recovery_CounterMinADX         = 20.0;    // Min ADX (trend TF) untuk aktifkan counter
input bool   Recovery_RelaxCounterADXOnLongSoftBrake = true;  // SOFT_BRAKE lama: turunkan CounterMinADX (TETAP wajib trend searah counter)
input int    Recovery_SoftBrakeRelaxMinutes = 45;      // SOFT_BRAKE berapa menit sebelum CounterMinADX dilonggarkan
input double Recovery_RelaxCounterADXMin     = 15.0;   // CounterMinADX saat SOFT_BRAKE lama (lebih rendah dari CounterMinADX)
input double Recovery_CounterMinMarginLevel = 300.0;   // Min margin level % untuk tambah counter (0=abaikan)
input double Recovery_CounterGridStep       = 0.50;    // Step grid counter (USD), lebih lebar dari grid utama
input int    Recovery_CounterMaxPositions   = 10;      // Max posisi counter
input double Recovery_CounterLotMultiplier  = 0.50;    // Counter lot = avg lot sisi rusak × ini
input double Recovery_CounterMaxExposureRatio = 0.50;  // Total lot counter <= total lot sisi rusak × ini
input double Recovery_CounterMinLot         = 0.01;    // Lot minimum counter
input double Recovery_CounterMaxLot         = 0.10;    // Lot maksimum per order counter
input int    Recovery_CounterCooldownMinutes = 15;     // Cooldown antar refill counter

// --- COUNTER OFFSET CLOSE (Bagian D) ---
input group "=== COUNTER OFFSET CLOSE ==="
input bool   Recovery_CounterUseOffsetClose        = true;   // Pakai profit counter untuk tutup loser lama
input double Recovery_CounterProfitTarget          = 50.0;   // Net profit minimal tiap offset close
input double Recovery_CounterCloseBuffer           = 20.0;   // Cadangan spread/slippage/komisi
input double Recovery_CounterMaxLossClosePerPass   = 200.0;  // Batas total loss damaged side per siklus
input double Recovery_CounterMinDamagedLossToClose = 10.0;   // Loss minimal posisi damaged yang layak ditutup

// --- HARD RECOVERY MODE (Bagian E) ---
input group "=== HARD RECOVERY MODE ==="
input bool   Recovery_HardUseTighterTargets        = true;   // Saat hard recovery: pakai target lebih kecil
input double Recovery_HardCounterProfitTarget      = 20.0;   // Override Recovery_CounterProfitTarget saat hard
input double Recovery_HardCounterCloseBuffer       = 10.0;   // Override buffer saat hard
input double Recovery_HardGlobalBasketMoneyTP      = 20.0;   // Override Recovery_GlobalBasketMoneyTP saat hard

//======================================================================
// GLOBAL STATE
//======================================================================
int  g_scan_interval   = 60;
bool g_in_protection   = false;
bool g_in_news         = false;
bool g_calendar_warned = false;

// Server-blocked-trading throttle (retcode 10026 = autotrading disabled by server).
// When the server rejects orders, stop hammering it every tick; retry only
// periodically and surface a clear status instead of flooding the log.
bool     g_server_blocked        = false;
datetime g_server_blocked_until  = 0;
datetime g_server_blocked_since  = 0;
int      g_server_block_retry_sec = 60;   // how long to back off before retrying

// Mobile dashboard runtime overrides
bool     g_dashboard_ea_enabled   = true;
bool     g_dashboard_prev_enabled = true;
int      g_dashboard_max_buy      = -1;   // -1 = use EA input, 0 = unlimited
int      g_dashboard_max_sell     = -1;   // -1 = use EA input, 0 = unlimited
datetime g_dashboard_last_poll    = 0;
datetime g_dashboard_last_load    = 0;

// Recovery exit-management state
bool     g_recovery_close_in_progress = false;
datetime g_recovery_pause_until       = 0;
// 0=none, 1=all positions, 2=BUY side, 3=SELL side.
// Used so retry-close never turns a side/partial close into accidental CloseAll.
int      g_recovery_close_scope       = 0;
RecoveryTrendMode g_recovery_trend_mode      = TREND_BOTH;
RecoveryTrendMode g_recovery_pending_mode    = TREND_BOTH;
int               g_recovery_mode_confirm    = 0;
datetime          g_recovery_last_mode_change = 0;
bool              g_recovery_buy_dd_active    = false;
bool              g_recovery_sell_dd_active   = false;
// Waktu mulai EA masuk TREND_PAUSE (0 = sedang tidak PAUSE). Untuk HUD durasi pause.
datetime          g_recovery_pause_started    = 0;

// Recovery counter state
RecoveryCounterState g_counter_state        = COUNTER_IDLE;
// Sisi yang sedang dipulihkan oleh counter (sisi rusak). -1 = tidak ada.
// POSITION_TYPE_BUY = BUY rusak (counter = SELL); POSITION_TYPE_SELL = SELL rusak (counter = BUY).
int               g_counter_damaged_side    = -1;
bool              g_counter_hard_mode       = false;
datetime          g_counter_last_refill     = 0;
// Waktu mulai counter masuk SOFT_BRAKE (0 = sedang tidak SOFT_BRAKE). Untuk auto-relax ADX.
datetime          g_counter_softbrake_started = 0;

// Total Loss Trend Recovery state
datetime          g_tlr_last_entry          = 0;

// Indicator handles
int h_recovery_fast_trend = INVALID_HANDLE;
int h_recovery_slow_trend = INVALID_HANDLE;
int h_recovery_fast_guard = INVALID_HANDLE;
int h_recovery_slow_guard = INVALID_HANDLE;
int h_recovery_adx_trend  = INVALID_HANDLE;
int h_recovery_atr_trend  = INVALID_HANDLE;

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

bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return false;
   // Back off while the server is actively rejecting orders (retcode 10026).
   if(g_server_blocked && TimeCurrent() < g_server_blocked_until) return false;
   return true;
}

// Call after any trade attempt. retcode 10026 = server disabled autotrading.
// Arms a back-off window so the EA stops retrying every tick. Any other
// outcome means the server is responding again, so the block is cleared.
void NoteTradeResult(int retcode)
{
   if(retcode == 10026)
   {
      if(!g_server_blocked)
      {
         g_server_blocked       = true;
         g_server_blocked_since = TimeCurrent();
         PrintFormat("[SERVER BLOCK] retcode=10026 autotrading disabled by server. Backing off %ds between retries.", g_server_block_retry_sec);
      }
      g_server_blocked_until = TimeCurrent() + g_server_block_retry_sec;
   }
   else if(retcode != 0)
   {
      // Server accepted/answered a real request → trading is alive again.
      if(g_server_blocked)
         Print("[SERVER BLOCK] cleared: server responded to trade request again.");
      g_server_blocked      = false;
      g_server_blocked_until = 0;
      g_server_blocked_since = 0;
   }
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

   FileWriteString(h, "state=" + state + "\n");
   FileWriteString(h, "enabled=" + (g_dashboard_ea_enabled ? "1" : "0") + "\n");
   FileWriteString(h, "symbol=" + _Symbol + "\n");
   FileWriteString(h, "mode=recovery\n");
   FileWriteString(h, "buy_positions=" + IntegerToString(obuy) + "\n");
   FileWriteString(h, "sell_positions=" + IntegerToString(osell) + "\n");
   FileWriteString(h, "total_positions=" + IntegerToString(obuy + osell) + "\n");
   FileWriteString(h, "max_buy=" + IntegerToString(EffectiveRecoveryMaxBuyPositions()) + "\n");
   FileWriteString(h, "max_sell=" + IntegerToString(EffectiveRecoveryMaxSellPositions()) + "\n");
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

   RecoveryDeletePendings();

   if(EnableRecoveryGridMode)
   {
      RecoveryManageBasketEquitySL();
      RecoveryManageSideBasketMoneyTP();
      RecoveryManageBasketMoneyTP();
      RecoveryManageBasketTrailing();
   }

   Comment(
      "EA MOBILE DASHBOARD: PAUSED\n",
      "New entries are OFF. Existing positions are still managed.\n",
      "BUY pos: ", CountEAOpenBuyPositions(), " / ", EffectiveRecoveryMaxBuyPositions(), "\n",
      "SELL pos: ", CountEAOpenSellPositions(), " / ", EffectiveRecoveryMaxSellPositions()
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
   h_recovery_fast_trend = iMA(_Symbol, Recovery_TrendTF, Recovery_TrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_recovery_slow_trend = iMA(_Symbol, Recovery_TrendTF, Recovery_TrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_recovery_fast_guard = iMA(_Symbol, Recovery_GuardTF, Recovery_TrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_recovery_slow_guard = iMA(_Symbol, Recovery_GuardTF, Recovery_TrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   h_recovery_adx_trend  = iADX(_Symbol, Recovery_TrendTF, Recovery_ADXPeriod);
   h_recovery_atr_trend  = iATR(_Symbol, Recovery_TrendTF, 14);

   if(h_recovery_fast_trend == INVALID_HANDLE || h_recovery_slow_trend == INVALID_HANDLE ||
      h_recovery_fast_guard == INVALID_HANDLE || h_recovery_slow_guard == INVALID_HANDLE ||
      h_recovery_adx_trend  == INVALID_HANDLE || h_recovery_atr_trend  == INVALID_HANDLE)
   {
      Print("EA INIT ERROR: gagal buat indicator handles");
      return false;
   }
   return true;
}

void ReleaseIndicators()
{
   int arr[] = {h_recovery_fast_trend, h_recovery_slow_trend,
                h_recovery_fast_guard, h_recovery_slow_guard,
                h_recovery_adx_trend,  h_recovery_atr_trend};
   for(int i = 0; i < ArraySize(arr); i++)
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
// NEWS HELPERS
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
// RECOVERY GRID MODE  (bidirectional grid recovery, mirrors target EA)
//======================================================================

string RecoveryTrendModeText(RecoveryTrendMode mode)
{
   if(mode == TREND_BUY_ONLY)  return "BUY_ONLY";
   if(mode == TREND_SELL_ONLY) return "SELL_ONLY";
   if(mode == TREND_PAUSE)     return "PAUSE";
   return "BOTH";
}

double RecoverySideNetProfit(ENUM_POSITION_TYPE ptype, bool includeSwap = true)
{
   double net = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;

      double pl = PositionGetDouble(POSITION_PROFIT);
      if(includeSwap) pl += PositionGetDouble(POSITION_SWAP);
      net += pl;
   }
   return net;
}

RecoveryTrendMode RecoveryRawTrendMode()
{
   if(!Recovery_UseTrendFilter) return TREND_BOTH;

   double fast1 = GetInd(h_recovery_fast_trend, 0, 1);
   double fast2 = GetInd(h_recovery_fast_trend, 0, 2);
   double slow1 = GetInd(h_recovery_slow_trend, 0, 1);
   double adx   = GetInd(h_recovery_adx_trend,  0, 1);
   double atr   = GetInd(h_recovery_atr_trend,  0, 1);
   double gfast = GetInd(h_recovery_fast_guard, 0, 1);
   double gslow = GetInd(h_recovery_slow_guard, 0, 1);
   double close = iClose(_Symbol, Recovery_TrendTF, 1);

   if(fast1 == EMPTY_VALUE || fast2 == EMPTY_VALUE || slow1 == EMPTY_VALUE ||
      adx == EMPTY_VALUE || gfast == EMPTY_VALUE || gslow == EMPTY_VALUE || close <= 0)
      return TREND_PAUSE;

   bool guardBullStrong = (gfast > gslow);
   bool guardBearStrong = (gfast < gslow);

   // Ambang ADX untuk "abaikan guard H4 saat H1 jelas".
   // Normal = Recovery_IgnoreGuardADXMin. Tapi kalau EA sudah stuck di PAUSE
   // lebih lama dari acuan menit, longgarkan ke Recovery_RelaxGuardADXMin agar
   // konflik H1/H4 lebih cepat terurai (TETAP ikut trend H1, bukan nebak arah).
   double ignoreGuardADXMin = Recovery_IgnoreGuardADXMin;
   if(Recovery_RelaxGuardOnLongPause &&
      g_recovery_trend_mode == TREND_PAUSE && g_recovery_pause_started > 0 &&
      Recovery_PauseHudReferenceMinutes > 0)
   {
      long pausedMin = (long)((TimeCurrent() - g_recovery_pause_started) / 60);
      if(pausedMin >= Recovery_PauseHudReferenceMinutes)
         ignoreGuardADXMin = MathMin(Recovery_IgnoreGuardADXMin, Recovery_RelaxGuardADXMin);
   }

   // Optional: when H1 itself is clearly directional and ADX is strong, let H1
   // win over a conflicting H4 guard. Without this, an H1-vs-H4 disagreement
   // (very common in transitions) forces PAUSE indefinitely.
   if(Recovery_IgnoreGuardWhenH1Strong && adx >= ignoreGuardADXMin)
   {
      if(fast1 < slow1 && close < slow1) guardBullStrong = false; // don't let H4 block a clear H1 downtrend
      if(fast1 > slow1 && close > slow1) guardBearStrong = false; // don't let H4 block a clear H1 uptrend
   }

   bool buyTrend  = (close > slow1 && fast1 > slow1 && fast1 > fast2 && adx >= Recovery_ADXTrendMin && !guardBearStrong);
   bool sellTrend = (close < slow1 && fast1 < slow1 && fast1 < fast2 && adx >= Recovery_ADXTrendMin && !guardBullStrong);

   // Harga terlalu jauh dari EMA cepat = momentum impulsif.
   // Default lama: selalu PAUSE. Itu justru mengunci EA saat trend kuat
   // (drop tajam yang bikin BUY nyangkut menjauhkan harga dari EMA),
   // sehingga SELL counter tidak pernah jalan.
   // Dengan Recovery_FarEMA_PreferTrend: kalau arah trend jelas, ikut trend.
   bool farFromEMA = (atr > 0 && Recovery_MaxDistanceFromFastEMA_ATR > 0 &&
                      MathAbs(close - fast1) > atr * Recovery_MaxDistanceFromFastEMA_ATR);
   if(farFromEMA)
   {
      if(!Recovery_FarEMA_PreferTrend) return TREND_PAUSE;
      // Ikut arah momentum saat harga melesat jauh dari EMA.
      if(close < fast1 && !guardBullStrong) return TREND_SELL_ONLY;
      if(close > fast1 && !guardBearStrong) return TREND_BUY_ONLY;
      return TREND_PAUSE; // jauh dari EMA tapi guard TF melawan → tetap pause
   }

   if(buyTrend)  return TREND_BUY_ONLY;
   if(sellTrend) return TREND_SELL_ONLY;
   if(adx <= Recovery_ADXRangeMax) return TREND_BOTH;

   // Arah tak pasti: struktur EMA (50 vs 200) mengarah satu sisi, TAPI harga sudah
   // di sisi BERLAWANAN dari EMA50 (momentum jangka pendek berbalik).
   // Contoh kasus user: EMA50<EMA200 (struktur bearish) tapi harga > EMA50 (momentum naik).
   // Memaksa SELL_ONLY di sini berisiko (filter EMA200 lagging). Lebih aman BOTH:
   // selalu ada sisi yang profit untuk offset, tanpa menebak arah.
   if(Recovery_BothWhenMomentumConflict)
   {
      bool structBear  = (fast1 < slow1);
      bool structBull  = (fast1 > slow1);
      bool momentumUp   = (close > fast1);  // harga di atas EMA50
      bool momentumDown = (close < fast1);  // harga di bawah EMA50
      if((structBear && momentumUp) || (structBull && momentumDown))
         return TREND_BOTH;
   }

   // Zona ADX tanggung (RangeMax < adx < TrendMin): bukan range, bukan trend kuat.
   // Default lama: PAUSE → EA diam berjam-jam di kondisi normal.
   // Dengan Recovery_CloseADXDeadZone: pakai arah EMA bila konsisten dgn guard TF.
   if(Recovery_CloseADXDeadZone)
   {
      if(fast1 < slow1 && !guardBullStrong) return TREND_SELL_ONLY;
      if(fast1 > slow1 && !guardBearStrong) return TREND_BUY_ONLY;
   }

   return TREND_PAUSE;
}

void RecoveryUpdateSideDDBrake()
{
   g_recovery_buy_dd_active  = false;
   g_recovery_sell_dd_active = false;
   if(!Recovery_UseSideDDBrake || Recovery_SideDDSoftLimitMoney <= 0) return;

   double buyNet  = RecoverySideNetProfit(POSITION_TYPE_BUY, true);
   double sellNet = RecoverySideNetProfit(POSITION_TYPE_SELL, true);

   g_recovery_buy_dd_active  = (buyNet  <= -Recovery_SideDDSoftLimitMoney);
   g_recovery_sell_dd_active = (sellNet <= -Recovery_SideDDSoftLimitMoney);

   if(Recovery_DeleteSameSidePendingsOnDD)
   {
      if(g_recovery_buy_dd_active)  RecoveryDeletePendingsSide(ORDER_TYPE_BUY_LIMIT);
      if(g_recovery_sell_dd_active) RecoveryDeletePendingsSide(ORDER_TYPE_SELL_LIMIT);
   }
}

// Set trend mode + lacak kapan EA masuk/keluar PAUSE (untuk HUD durasi pause).
void RecoverySetTrendMode(RecoveryTrendMode mode, datetime now)
{
   if(mode == TREND_PAUSE)
   {
      if(g_recovery_pause_started == 0) g_recovery_pause_started = now;
   }
   else
   {
      g_recovery_pause_started = 0;
   }
   g_recovery_trend_mode = mode;
   g_recovery_last_mode_change = now;
}

void RecoveryUpdateTrendMode()
{
   RecoveryTrendMode raw = RecoveryRawTrendMode();
   datetime now = TimeCurrent();

   bool sideDD = (g_recovery_buy_dd_active || g_recovery_sell_dd_active);

   // DontFlipIfSideDDActive TIDAK lagi mengubah trend mode ke PAUSE.
   // Alasan: jika trend jelas BUY tapi BUY DD aktif, EA harus tetap tahu
   // bahwa trend = BUY. Grid refill BUY akan ditahan oleh RecoveryAllowBuyGrid
   // (karena PauseSameSideGridOnDD). Trend mode tetap akurat untuk counter grid.
   // Tanpa ini, EA sering stuck di PAUSE padahal sisi counter seharusnya jalan.

   if(Recovery_ConvertPauseToCounterOnDD && sideDD && raw == TREND_PAUSE)
   {
      double buyNet  = RecoverySideNetProfit(POSITION_TYPE_BUY, true);
      double sellNet = RecoverySideNetProfit(POSITION_TYPE_SELL, true);
      double buyLoss  = (buyNet  < 0) ? -buyNet  : 0.0;
      double sellLoss = (sellNet < 0) ? -sellNet : 0.0;

      int buyPos  = CountEAOpenBuyPositions();
      int sellPos = CountEAOpenSellPositions();
      int maxBuy  = EffectiveRecoveryMaxBuyPositions();
      int maxSell = EffectiveRecoveryMaxSellPositions();
      bool buyFull  = (maxBuy  > 0 && buyPos  >= maxBuy);
      bool sellFull = (maxSell > 0 && sellPos >= maxSell);

      // Jangan biarkan EA diam saat basket rusak: stop sisi rusak, buka sisi lawan.
      // Tapi kalau sisi lawan sudah max posisi, tetap PAUSE (tidak bisa buka apa-apa).
      if(g_recovery_buy_dd_active && (!g_recovery_sell_dd_active || buyLoss >= sellLoss))
      {
         if(!sellFull) raw = TREND_SELL_ONLY;
      }
      else if(g_recovery_sell_dd_active)
      {
         if(!buyFull) raw = TREND_BUY_ONLY;
      }
   }

    int cooldown = MathMax(0, Recovery_DirectionCooldownMinutes) * 60;
   if(cooldown > 0 && g_recovery_last_mode_change > 0 && (now - g_recovery_last_mode_change) < cooldown)
      return;

   if(raw != g_recovery_pending_mode)
   {
      g_recovery_pending_mode = raw;
      g_recovery_mode_confirm = 1;
      if(raw != g_recovery_trend_mode && MathMax(1, Recovery_DirectionConfirmBars) <= 1)
         RecoverySetTrendMode(raw, now);
      return;
   }

   g_recovery_mode_confirm++;
   int need = MathMax(1, Recovery_DirectionConfirmBars);
   if(raw != g_recovery_trend_mode && g_recovery_mode_confirm >= need)
      RecoverySetTrendMode(raw, now);
}

bool RecoveryAllowBuyGrid()
{
   if(!Recovery_EnableBuyGrid) return false;
   if(Recovery_PauseSameSideGridOnDD && g_recovery_buy_dd_active) return false;
   return (g_recovery_trend_mode == TREND_BUY_ONLY || g_recovery_trend_mode == TREND_BOTH);
}

bool RecoveryAllowSellGrid()
{
   if(!Recovery_EnableSellGrid) return false;
   if(Recovery_PauseSameSideGridOnDD && g_recovery_sell_dd_active) return false;
   return (g_recovery_trend_mode == TREND_SELL_ONLY || g_recovery_trend_mode == TREND_BOTH);
}

//======================================================================
// RECOVERY COUNTER (Bagian C/D/E)
// Saat satu sisi basket rusak (floating minus besar) DAN market bergerak
// melawan sisi itu, EA membuka counter grid searah trend. Profit counter
// dipakai untuk menutup sebagian loser lama secara NET PROFIT (offset close).
//======================================================================

string RecoveryCounterStateText(RecoveryCounterState s)
{
   if(s == COUNTER_SOFT_BRAKE)   return "SOFT_BRAKE";
   if(s == COUNTER_ACTIVE)       return "ACTIVE";
   if(s == COUNTER_OFFSET_CLOSE) return "OFFSET_CLOSE";
   if(s == COUNTER_RECOVERED)    return "RECOVERED";
   return "IDLE";
}

// Total lot satu sisi (symbol+magic).
double RecoverySideLots(ENUM_POSITION_TYPE ptype)
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

double RecoverySideAvgLot(ENUM_POSITION_TYPE ptype)
{
   double v = RecoverySideLots(ptype);
   int    n = RecoveryCountOpenPositionsByType(ptype);
   return (n > 0) ? (v / n) : 0.0;
}

// Hitung posisi & lot counter berdasarkan comment "RG CNT".
int RecoveryCountCounterPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RG CNT") < 0) continue;
      n++;
   }
   return n;
}

double RecoveryCounterLots()
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RG CNT") < 0) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

int RecoveryCountCounterPositionsByType(ENUM_POSITION_TYPE ptype)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RG CNT") < 0) continue;
      n++;
   }
   return n;
}

double RecoveryCounterLotsByType(ENUM_POSITION_TYPE ptype)
{
   double v = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT), "RG CNT") < 0) continue;
      v += PositionGetDouble(POSITION_VOLUME);
   }
   return v;
}

bool RecoveryMarginLevelOK()
{
   if(Recovery_CounterMinMarginLevel <= 0) return true;
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(ml <= 0) return true; // belum ada margin terpakai → izinkan
   return ml >= Recovery_CounterMinMarginLevel;
}

// Trend filter mendukung arah counter?
//   BUY rusak  → counter SELL → butuh mode SELL_ONLY
//   SELL rusak → counter BUY  → butuh mode BUY_ONLY
// PENTING: counter HANYA jalan saat trend benar-benar searah counter.
// Kalau BUY rusak tapi trend NAIK, EA tidak buka SELL (tidak melawan trend).
// Sisi rusak yang searah trend akan pulih sendiri + dibantu TP exit (side basket
// TP / selective net close), bukan dengan membuka posisi melawan trend.
bool RecoveryCounterTrendOK(int damagedSide)
{
   if(!Recovery_CounterRequireTrend) return true;
   if(damagedSide == POSITION_TYPE_BUY)
      return (g_recovery_trend_mode == TREND_SELL_ONLY);
   return (g_recovery_trend_mode == TREND_BUY_ONLY);
}

// Set counter state + lacak kapan masuk/keluar SOFT_BRAKE (untuk auto-relax ADX).
void RecoverySetCounterState(RecoveryCounterState state)
{
   if(state == COUNTER_SOFT_BRAKE)
   {
      if(g_counter_softbrake_started == 0) g_counter_softbrake_started = TimeCurrent();
   }
   else
   {
      g_counter_softbrake_started = 0;
   }
   g_counter_state = state;
}

// CounterMinADX efektif: dilonggarkan kalau SOFT_BRAKE sudah lama.
double RecoveryEffectiveCounterMinADX()
{
   double minADX = Recovery_CounterMinADX;
   if(Recovery_RelaxCounterADXOnLongSoftBrake &&
      g_counter_state == COUNTER_SOFT_BRAKE && g_counter_softbrake_started > 0 &&
      Recovery_SoftBrakeRelaxMinutes > 0)
   {
      long sbMin = (long)((TimeCurrent() - g_counter_softbrake_started) / 60);
      if(sbMin >= Recovery_SoftBrakeRelaxMinutes)
         minADX = MathMin(Recovery_CounterMinADX, Recovery_RelaxCounterADXMin);
   }
   return minADX;
}

// Tentukan sisi rusak + hard mode + state. Dipanggil tiap cycle.
void RecoveryUpdateCounterState()
{
   if(!Recovery_UseCounterRecovery)
   {
      RecoverySetCounterState(COUNTER_IDLE);
      g_counter_damaged_side = -1;
      g_counter_hard_mode    = false;
      return;
   }

   double buyNet  = RecoverySideNetProfit(POSITION_TYPE_BUY,  true);
   double sellNet = RecoverySideNetProfit(POSITION_TYPE_SELL, true);
   double buyLoss  = (buyNet  < 0) ? -buyNet  : 0.0;
   double sellLoss = (sellNet < 0) ? -sellNet : 0.0;

   int    damaged = -1;
   double dmgLoss = 0.0;
   if(buyLoss >= Recovery_CounterStartLossMoney || sellLoss >= Recovery_CounterStartLossMoney)
   {
      if(buyLoss >= sellLoss) { damaged = POSITION_TYPE_BUY;  dmgLoss = buyLoss;  }
      else                    { damaged = POSITION_TYPE_SELL; dmgLoss = sellLoss; }
   }

   if(damaged < 0)
   {
      // Tidak ada sisi rusak besar. Tandai SOFT_BRAKE bila side DD aktif.
      g_counter_damaged_side = -1;
      g_counter_hard_mode    = false;
      RecoverySetCounterState((g_recovery_buy_dd_active || g_recovery_sell_dd_active)
                              ? COUNTER_SOFT_BRAKE : COUNTER_IDLE);
      return;
   }

   // Cek apakah sisi counter masih punya kapasitas.
   // BUY rusak → counter SELL; SELL rusak → counter BUY.
   // Kalau sisi counter sudah max, counter tidak bisa buka apa-apa → SOFT_BRAKE.
   // Kalau KEDUA sisi sudah max, SOFT_BRAKE juga (EA stuck sampai ada posisi close).
   ENUM_POSITION_TYPE counterSide = (damaged == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   int counterPos = (counterSide == POSITION_TYPE_BUY) ? CountEAOpenBuyPositions() : CountEAOpenSellPositions();
   int counterMax = (counterSide == POSITION_TYPE_BUY) ? EffectiveRecoveryMaxBuyPositions() : EffectiveRecoveryMaxSellPositions();
   bool counterFull = (counterMax > 0 && counterPos >= counterMax);

   if(counterFull)
   {
      // Sisi counter penuh. Coba counter sisi ALTERNATIF.
      // Jika BUY rusak → counter SELL (penuh) → switch: damaged = SELL, counter = BUY
      ENUM_POSITION_TYPE altDamaged = (damaged == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      ENUM_POSITION_TYPE altCounter = (altDamaged == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      int altCounterPos = (altCounter == POSITION_TYPE_BUY) ? CountEAOpenBuyPositions() : CountEAOpenSellPositions();
      int altCounterMax = (altCounter == POSITION_TYPE_BUY) ? EffectiveRecoveryMaxBuyPositions() : EffectiveRecoveryMaxSellPositions();
      bool altFull = (altCounterMax > 0 && altCounterPos >= altCounterMax);

      if(!altFull)
      {
         // Sisi counter alternatif masih ada ruang → switch damaged
         damaged = altDamaged;
         dmgLoss = (damaged == POSITION_TYPE_BUY) ? buyLoss : sellLoss;
      }
      else
      {
         // Kedua sisi counter sudah max → SOFT_BRAKE, EA tunggu ada posisi close
         g_counter_damaged_side = damaged;
         g_counter_hard_mode    = (dmgLoss >= Recovery_CounterHardLossMoney);
         RecoverySetCounterState(COUNTER_SOFT_BRAKE);
         return;
      }
   }

   g_counter_damaged_side = damaged;
   g_counter_hard_mode    = (dmgLoss >= Recovery_CounterHardLossMoney);
   RecoverySetCounterState(RecoveryCounterActiveReady(damaged) ? COUNTER_ACTIVE : COUNTER_SOFT_BRAKE);
}

// Syarat counter boleh menambah grid sekarang.
bool RecoveryCounterActiveReady(int damagedSide)
{
   if(!Recovery_UseCounterRecovery)              return false;
   if(damagedSide < 0)                           return false;
   if(!RecoveryCounterTrendOK(damagedSide))      return false;
   double adx = GetInd(h_recovery_adx_trend, 0, 1);
   double minADX = RecoveryEffectiveCounterMinADX();
   if(adx != EMPTY_VALUE && adx < minADX) return false;
   if(!RecoveryMarginLevelOK())                  return false;
   return true;
}

bool RecoveryCounterIsActive()
{
   return (g_counter_damaged_side >= 0 && RecoveryCounterActiveReady(g_counter_damaged_side));
}

// Sisi order yang dikelola counter (untuk supresi normal grid sisi itu).
//   BUY rusak → counter SELL_LIMIT ; SELL rusak → counter BUY_LIMIT
bool RecoveryCounterOwnsSide(ENUM_ORDER_TYPE side)
{
   if(!RecoveryCounterIsActive()) return false;
   if(g_counter_damaged_side == POSITION_TYPE_BUY)  return (side == ORDER_TYPE_SELL_LIMIT);
   if(g_counter_damaged_side == POSITION_TYPE_SELL) return (side == ORDER_TYPE_BUY_LIMIT);
   return false;
}

double RecoveryClampCounterLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(Recovery_CounterMinLot > 0 && lot < Recovery_CounterMinLot) lot = Recovery_CounterMinLot;
   if(Recovery_CounterMaxLot > 0 && lot > Recovery_CounterMaxLot) lot = Recovery_CounterMaxLot;
   if(step > 0) lot = MathRound(lot / step) * step;
   if(minLot > 0 && lot < minLot) lot = minLot;
   if(maxLot > 0 && lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

// Pasang counter grid (pending) di sisi berlawanan dari sisi rusak.
void RecoveryEnsureCounterGrid()
{
   if(!EnableRecoveryGridMode) return;
   if(!RecoveryCounterIsActive()) return;
   if(!TradingAllowed()) return;
   if(Recovery_CounterGridStep <= 0) return;

   // Cooldown antar refill counter.
   int cooldown = MathMax(0, Recovery_CounterCooldownMinutes) * 60;
   if(cooldown > 0 && g_counter_last_refill > 0 &&
      (TimeCurrent() - g_counter_last_refill) < cooldown) return;

   int damaged = g_counter_damaged_side;
   ENUM_ORDER_TYPE cside = (damaged == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;

   // Cek apakah sisi target counter sudah max total (termasuk grid normal + counter)
   int targetPos  = (cside == ORDER_TYPE_SELL_LIMIT) ? CountEAOpenSellPositions() : CountEAOpenBuyPositions();
   int targetMax  = (cside == ORDER_TYPE_SELL_LIMIT) ? EffectiveRecoveryMaxSellPositions() : EffectiveRecoveryMaxBuyPositions();
   if(targetMax > 0 && targetPos >= targetMax) return;

   ENUM_POSITION_TYPE counterType = (cside == ORDER_TYPE_SELL_LIMIT)
                                    ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   int curCnt = RecoveryCountCounterPositionsByType(counterType);
   if(Recovery_CounterMaxPositions > 0 && curCnt >= Recovery_CounterMaxPositions) return;

   // Batas exposure counter relatif terhadap total lot sisi rusak.
   double dmgLots        = RecoverySideLots((ENUM_POSITION_TYPE)damaged);
   double maxCounterLots = (Recovery_CounterMaxExposureRatio > 0) ? dmgLots * Recovery_CounterMaxExposureRatio : 0.0;
   double curCounterLots = RecoveryCounterLotsByType(counterType);
   if(maxCounterLots > 0 && curCounterLots >= maxCounterLots) return;

   double clot = RecoveryClampCounterLot(RecoverySideAvgLot((ENUM_POSITION_TYPE)damaged) * Recovery_CounterLotMultiplier);
   if(clot <= 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   double md = StopsMinDistance();
   double fz = FreezeMinDistance();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   if(cside == ORDER_TYPE_SELL_LIMIT)
   {
      double baseUp = MathCeil(ask / Recovery_CounterGridStep) * Recovery_CounterGridStep;
      for(int i = 0; i < Recovery_CounterMaxPositions; i++)
      {
         if(Recovery_CounterMaxPositions > 0 && curCnt >= Recovery_CounterMaxPositions) break;
         if(maxCounterLots > 0 && (curCounterLots + clot) > maxCounterLots + Eps()) break;

         double level = NormPrice(baseUp + i * Recovery_CounterGridStep);
         if(level <= 0) break;
         if(level < (ask + md)) continue;
         if(fz > 0 && level < (ask + fz)) continue;
         if(RecoveryLevelOccupied(level, ORDER_TYPE_SELL_LIMIT)) continue;

         if(trade.SellLimit(clot, level, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "RG CNT SL"))
         { curCnt++; curCounterLots += clot; }
      }
   }
   else // ORDER_TYPE_BUY_LIMIT
   {
      double baseDown = MathFloor(bid / Recovery_CounterGridStep) * Recovery_CounterGridStep;
      for(int i = 0; i < Recovery_CounterMaxPositions; i++)
      {
         if(Recovery_CounterMaxPositions > 0 && curCnt >= Recovery_CounterMaxPositions) break;
         if(maxCounterLots > 0 && (curCounterLots + clot) > maxCounterLots + Eps()) break;

         double level = NormPrice(baseDown - i * Recovery_CounterGridStep);
         if(level <= 0) break;
         if(level > (bid - md)) continue;
         if(fz > 0 && level > (bid - fz)) continue;
         if(RecoveryLevelOccupied(level, ORDER_TYPE_BUY_LIMIT)) continue;

         if(trade.BuyLimit(clot, level, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "RG CNT BL"))
         { curCnt++; curCounterLots += clot; }
      }
   }

   g_counter_last_refill = TimeCurrent();
}

// Hapus pending counter satu sisi.
void RecoveryDeleteCounterPendings(ENUM_ORDER_TYPE side)
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
      if(StringFind(OrderGetString(ORDER_COMMENT), "RG CNT") < 0) continue;
      trade.OrderDelete(t);
   }
}

// Counter offset close: tutup counter winner + damaged loser sehingga net profit.
//   counterWinnerProfit - selectedLoss - buffer >= target
void RecoveryManageCounterOffsetClose()
{
   if(!EnableRecoveryGridMode)                       return;
   if(!Recovery_UseCounterRecovery)                  return;
   if(!Recovery_CounterUseOffsetClose)               return;
   if(g_recovery_close_in_progress)                  return;
   if(TimeCurrent() < g_recovery_pause_until)        return;
   if(!TradingAllowed())                             return;
   if(g_counter_damaged_side < 0)                    return;

   int damaged = g_counter_damaged_side;
   ENUM_POSITION_TYPE dmgType = (ENUM_POSITION_TYPE)damaged;
   ENUM_POSITION_TYPE cntType = (damaged == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   double profitTarget = (g_counter_hard_mode && Recovery_HardUseTighterTargets)
                         ? Recovery_HardCounterProfitTarget : Recovery_CounterProfitTarget;
   double buffer       = (g_counter_hard_mode && Recovery_HardUseTighterTargets)
                         ? Recovery_HardCounterCloseBuffer  : Recovery_CounterCloseBuffer;

   // Kumpulkan counter winners (sisi counter, pl>0) dan damaged losers (sisi rusak, pl<0).
   ulong  winTickets[];  double winPL[];
   ulong  lossTickets[]; double lossAmt[]; double lossOpen[];
   double totalWinner = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE ty = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(ty == cntType && pl > 0)
      {
         int sz = ArraySize(winTickets);
         ArrayResize(winTickets, sz + 1); ArrayResize(winPL, sz + 1);
         winTickets[sz] = pt; winPL[sz] = pl;
         totalWinner += pl;
      }
      else if(ty == dmgType && pl < 0)
      {
         double amt = -pl;
         if(amt < Recovery_CounterMinDamagedLossToClose) continue;
         int sz = ArraySize(lossTickets);
         ArrayResize(lossTickets, sz + 1); ArrayResize(lossAmt, sz + 1); ArrayResize(lossOpen, sz + 1);
         lossTickets[sz] = pt; lossAmt[sz] = amt;
         lossOpen[sz] = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   if(ArraySize(winTickets) == 0 || ArraySize(lossTickets) == 0) return;

   double lossBudget = totalWinner - profitTarget - buffer;
   if(lossBudget <= 0) return;
   if(Recovery_CounterMaxLossClosePerPass > 0 && lossBudget > Recovery_CounterMaxLossClosePerPass)
      lossBudget = Recovery_CounterMaxLossClosePerPass;

   // Pilih loser paling jauh dari harga dulu:
   //   BUY rusak  → entry tertinggi dulu (open desc)
   //   SELL rusak → entry terendah dulu (open asc)
   int lcount = ArraySize(lossTickets);
   int lidx[]; ArrayResize(lidx, lcount);
   for(int i = 0; i < lcount; i++) lidx[i] = i;
   for(int a = 0; a < lcount - 1; a++)
      for(int b = a + 1; b < lcount; b++)
      {
         bool swap = (dmgType == POSITION_TYPE_BUY)
                     ? (lossOpen[lidx[b]] > lossOpen[lidx[a]])
                     : (lossOpen[lidx[b]] < lossOpen[lidx[a]]);
         if(swap) { int tmp = lidx[a]; lidx[a] = lidx[b]; lidx[b] = tmp; }
      }

   ulong  selLoss[];
   double selectedLoss = 0.0;
   double remaining = lossBudget;
   for(int i = 0; i < lcount; i++)
   {
      int idx = lidx[i];
      if(lossAmt[idx] <= remaining)
      {
         int sz = ArraySize(selLoss);
         ArrayResize(selLoss, sz + 1);
         selLoss[sz] = lossTickets[idx];
         selectedLoss += lossAmt[idx];
         remaining    -= lossAmt[idx];
      }
   }
   if(ArraySize(selLoss) == 0 || selectedLoss <= 0) return;

   // Pilih counter winners (profit desc) secukupnya menutupi loss + target + buffer.
   double needWin = selectedLoss + profitTarget + buffer;
   int wcount = ArraySize(winTickets);
   int widx[]; ArrayResize(widx, wcount);
   for(int i = 0; i < wcount; i++) widx[i] = i;
   for(int a = 0; a < wcount - 1; a++)
      for(int b = a + 1; b < wcount; b++)
         if(winPL[widx[b]] > winPL[widx[a]])
         { int tmp = widx[a]; widx[a] = widx[b]; widx[b] = tmp; }

   ulong  selWin[];
   double selectedWin = 0.0;
   for(int i = 0; i < wcount; i++)
   {
      if(selectedWin >= needWin) break;
      int idx = widx[i];
      int sz  = ArraySize(selWin);
      ArrayResize(selWin, sz + 1);
      selWin[sz] = winTickets[idx];
      selectedWin += winPL[idx];
   }

   double netResult = selectedWin - selectedLoss - buffer;
   if(netResult < profitTarget) return;

   if(!RecoveryPrecloseTwoTicketSetsOK(selWin, selLoss, profitTarget, buffer, "counter-offset-close"))
      return;

   PrintFormat("[RG COUNTER OFFSET] damaged=%s win=%.2f loss=%.2f net=%.2f target=%.2f buffer=%.2f hard=%d",
               (dmgType == POSITION_TYPE_BUY ? "BUY" : "SELL"),
               selectedWin, selectedLoss, netResult, profitTarget, buffer, (int)g_counter_hard_mode);

   g_recovery_close_in_progress = true;
   g_recovery_close_scope       = 0; // partial cross-side: jangan pernah jadi CloseAll
   RecoverySetCounterState(COUNTER_OFFSET_CLOSE);

   // Realisasikan profit counter dulu, baru tutup loser lama.
   bool okWin  = RecoveryCloseTickets(selWin,  "counter-winner");
   bool okLoss = RecoveryCloseTickets(selLoss, "counter-loser");

   g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

   if(!okWin || !okLoss)
      Print("[RG COUNTER OFFSET] partial close/failure; no CloseAll retry (ticket-scoped only)");

   g_recovery_close_in_progress = false;
   g_recovery_close_scope       = 0;
}

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
    if(!EnableRecoveryGridMode || !RecoveryAllowBuyGrid()) return;
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

      if(!trade.BuyLimit(lot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RG BL"))
      {
         int rc = (int)trade.ResultRetcode();
         NoteTradeResult(rc);
         if(rc == 10026) return; // server blocked → stop placing this pass
      }
   }
}

// Refill SELL LIMIT grid above price (recovery-only pending grid).
void RecoveryEnsureSellGrid()
{
    if(!EnableRecoveryGridMode || !RecoveryAllowSellGrid()) return;
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

      if(!trade.SellLimit(lot, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "RG SL"))
      {
         int rc = (int)trade.ResultRetcode();
         NoteTradeResult(rc);
         if(rc == 10026) return; // server blocked → stop placing this pass
      }
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

//======================================================================
// TOTAL LOSS TREND RECOVERY (TLR)
// Membuka posisi tambahan searah trend saat total floating basket minus besar.
// Exit tetap memakai side/global/selective basket close existing.
//======================================================================

bool RecoveryTLRIsPosition()
{
   return (StringFind(PositionGetString(POSITION_COMMENT), "RG TLR") >= 0);
}

int RecoveryTLRCountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!RecoveryTLRIsPosition()) continue;
      n++;
   }
   return n;
}

double RecoveryTLRLots()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!RecoveryTLRIsPosition()) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double RecoveryTLRClampLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(Recovery_TL_MaxLot > 0 && lot > Recovery_TL_MaxLot) lot = Recovery_TL_MaxLot;
   if(step > 0) lot = MathFloor(lot / step) * step;
   if(minLot > 0 && lot < minLot) lot = minLot;
   if(maxLot > 0 && lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

double RecoveryTLRLotByLoss(double totalLoss)
{
   double lot = Recovery_TL_BaseLot;
   if(Recovery_TL_LossStepMoney > 0 && Recovery_TL_LotAddPerStep > 0)
   {
      double extra = MathMax(0.0, totalLoss - Recovery_TotalLossTrendStartMoney);
      int steps = (int)MathFloor(extra / Recovery_TL_LossStepMoney);
      lot += steps * Recovery_TL_LotAddPerStep;
   }
   return RecoveryTLRClampLot(lot);
}

bool RecoveryTLRMarginOK()
{
   if(Recovery_TL_MinMarginLevel <= 0) return true;
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   if(ml <= 0) return true;
   return ml >= Recovery_TL_MinMarginLevel;
}

int RecoveryTLRDirection()
{
   // Jika satu sisi sudah rusak, TLR harus menjadi recovery searah trend,
   // bukan averaging tambahan ke sisi rusak. Laporan aktual menunjukkan TLR
   // yang menambah damaged side menjadi penyumbang floating terbesar kedua.
   if(Recovery_TL_BlockDamagedSide)
   {
      if(g_recovery_buy_dd_active && !g_recovery_sell_dd_active)
         return (g_recovery_trend_mode == TREND_SELL_ONLY) ? POSITION_TYPE_SELL : -1;
      if(g_recovery_sell_dd_active && !g_recovery_buy_dd_active)
         return (g_recovery_trend_mode == TREND_BUY_ONLY) ? POSITION_TYPE_BUY : -1;
      if(g_recovery_buy_dd_active && g_recovery_sell_dd_active)
         return -1;
   }

   if(g_recovery_trend_mode == TREND_BUY_ONLY)  return POSITION_TYPE_BUY;
   if(g_recovery_trend_mode == TREND_SELL_ONLY) return POSITION_TYPE_SELL;
   if(g_recovery_trend_mode != TREND_BOTH)      return -1;

   if(g_recovery_sell_dd_active && !g_recovery_buy_dd_active) return POSITION_TYPE_BUY;
   if(g_recovery_buy_dd_active  && !g_recovery_sell_dd_active) return POSITION_TYPE_SELL;

   int buys  = CountEAOpenBuyPositions();
   int sells = CountEAOpenSellPositions();
   return (buys <= sells) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
}

void RecoveryEnsureTotalLossTrendRecovery()
{
   if(!EnableRecoveryGridMode) return;
   if(!Recovery_UseTotalLossTrendRecovery) return;
   if(!TradingAllowed()) return;
   if(!RecoveryTLRMarginOK()) return;

   double net = RecoveryOpenNetProfit();
   if(net >= 0) return;
   double totalLoss = -net;
   if(totalLoss < Recovery_TotalLossTrendStartMoney) return;

   int cooldown = MathMax(0, Recovery_TL_CooldownMinutes) * 60;
   if(cooldown > 0 && g_tlr_last_entry > 0 && (TimeCurrent() - g_tlr_last_entry) < cooldown) return;

   if(Recovery_TL_MaxPositions > 0 && RecoveryTLRCountPositions() >= Recovery_TL_MaxPositions) return;
   if(Recovery_TL_MaxTotalLot > 0 && RecoveryTLRLots() >= Recovery_TL_MaxTotalLot) return;

   int dir = RecoveryTLRDirection();
   if(dir < 0) return;

   int buyCnt  = CountEAOpenBuyPositions();
   int sellCnt = CountEAOpenSellPositions();
   if(Recovery_MaxTotalPositions > 0 && (buyCnt + sellCnt) >= Recovery_MaxTotalPositions) return;
   if(dir == POSITION_TYPE_BUY)
   {
      int maxBuy = EffectiveRecoveryMaxBuyPositions();
      if(maxBuy > 0 && buyCnt >= maxBuy) return;
   }
   else
   {
      int maxSell = EffectiveRecoveryMaxSellPositions();
      if(maxSell > 0 && sellCnt >= maxSell) return;
   }

   double lot = RecoveryTLRLotByLoss(totalLoss);
   if(lot <= 0) return;
   if(Recovery_TL_MaxTotalLot > 0 && (RecoveryTLRLots() + lot) > Recovery_TL_MaxTotalLot + Eps()) return;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   bool ok = false;
   if(dir == POSITION_TYPE_BUY)
      ok = trade.Buy(lot, _Symbol, 0, 0, 0, "RG TLR BUY");
   else
      ok = trade.Sell(lot, _Symbol, 0, 0, 0, "RG TLR SELL");

   NoteTradeResult((int)trade.ResultRetcode());
   if(ok)
   {
      g_tlr_last_entry = TimeCurrent();
      PrintFormat("[RG TLR] %s lot=%.2f totalLoss=%.2f trend=%s",
                  (dir == POSITION_TYPE_BUY ? "BUY" : "SELL"), lot, totalLoss,
                  RecoveryTrendModeText(g_recovery_trend_mode));
   }
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

// Count of open EA positions on symbol+magic for one side only.
int RecoveryCountOpenPositionsByType(ENUM_POSITION_TYPE ptype)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;
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
         int rc = (int)trade.ResultRetcode();
         NoteTradeResult(rc);
         PrintFormat("[RG CLOSE] failed ticket=%I64u reason=%s retcode=%d desc=%s",
                     tickets[i], reason, rc, trade.ResultRetcodeDescription());
         // Server disabled autotrading: stop hammering the rest of the list this pass.
         if(rc == 10026) return false;
      }
      else
      {
         NoteTradeResult((int)trade.ResultRetcode());
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

// Collect one side of EA positions (BUY or SELL) and close the whole side basket.
bool RecoveryClosePositionsByType(ENUM_POSITION_TYPE ptype, string reason)
{
   ulong tickets[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;
      int sz = ArraySize(tickets);
      ArrayResize(tickets, sz + 1);
      tickets[sz] = pt;
   }
   if(ArraySize(tickets) == 0) return true;
   return RecoveryCloseTickets(tickets, reason);
}

double RecoveryTicketsLiveNet(ulong &tickets[])
{
   double net = 0.0;
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(tickets[i] == 0) continue;
      if(!PositionSelectByTicket(tickets[i])) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      net += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return net;
}

double RecoveryTicketsLots(ulong &tickets[])
{
   double lots = 0.0;
   for(int i = 0; i < ArraySize(tickets); i++)
   {
      if(tickets[i] == 0) continue;
      if(!PositionSelectByTicket(tickets[i])) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double RecoveryOpenLotsByMagic()
{
   double lots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pt = PositionGetTicket(i);
      if(pt == 0) continue;
      if(!PositionSelectByTicket(pt)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

double RecoveryAdaptiveCloseBuffer(double baseBuffer, double lots)
{
   double extra = 0.0;
   if(Recovery_CloseSlipBufferPerLot > 0 && lots > 0)
      extra = lots * Recovery_CloseSlipBufferPerLot;
   return MathMax(0.0, baseBuffer) + extra;
}

bool RecoveryPrecloseTicketsOK(ulong &tickets[], double target, double baseBuffer, string reason)
{
   if(!Recovery_PrecloseRecheckNet) return true;
   double liveNet = RecoveryTicketsLiveNet(tickets);
   double lots    = RecoveryTicketsLots(tickets);
   double buffer  = RecoveryAdaptiveCloseBuffer(baseBuffer, lots);
   double need    = target + buffer;
   if(liveNet < need)
   {
      PrintFormat("[RG PRECLOSE BLOCK] %s liveNet=%.2f need=%.2f target=%.2f buffer=%.2f lots=%.2f",
                  reason, liveNet, need, target, buffer, lots);
      return false;
   }
   return true;
}

bool RecoveryPrecloseTwoTicketSetsOK(ulong &ticketsA[], ulong &ticketsB[], double target, double baseBuffer, string reason)
{
   if(!Recovery_PrecloseRecheckNet) return true;
   double liveNet = RecoveryTicketsLiveNet(ticketsA) + RecoveryTicketsLiveNet(ticketsB);
   double lots    = RecoveryTicketsLots(ticketsA) + RecoveryTicketsLots(ticketsB);
   double buffer  = RecoveryAdaptiveCloseBuffer(baseBuffer, lots);
   double need    = target + buffer;
   if(liveNet < need)
   {
      PrintFormat("[RG PRECLOSE BLOCK] %s liveNet=%.2f need=%.2f target=%.2f buffer=%.2f lots=%.2f",
                  reason, liveNet, need, target, buffer, lots);
      return false;
   }
   return true;
}

bool RecoveryPrecloseAllByMagicOK(double target, double baseBuffer, string reason)
{
   if(!Recovery_PrecloseRecheckNet) return true;
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
   return RecoveryPrecloseTicketsOK(tickets, target, baseBuffer, reason);
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

   if(!RecoveryPrecloseTwoTicketSetsOK(selWin, selLoss, Recovery_SelectiveNetTarget, Recovery_SelectiveCloseBuffer, "selective-net-close"))
      return;

   // 16) Execute.
   PrintFormat("[RG SELECTIVE CLOSE] win=%.2f loss=%.2f net=%.2f target=%.2f buffer=%.2f",
               selectedWinnerProfit, selectedLossAmount, netResult,
               Recovery_SelectiveNetTarget, Recovery_SelectiveCloseBuffer);

   g_recovery_close_in_progress = true;
   g_recovery_close_scope       = 0; // selective has no safe whole-basket retry scope
   Print("[RG CLOSE] delete pendings before close");
   RecoveryDeletePendings(); // stop new orders entering mid-close

   bool okWin  = RecoveryCloseTickets(selWin,  "selective-winner");
   bool okLoss = RecoveryCloseTickets(selLoss, "selective-loser");

   Print("[RG CLOSE] delete pendings after close");
   RecoveryDeletePendings();

   g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

   // Selective close is a partial basket operation. Do not let the generic
   // retry handler convert a failed selective close into CloseAll.
   if(!okWin || !okLoss)
      Print("[RG SELECTIVE CLOSE] partial close/failure; no CloseAll retry will be used");
   g_recovery_close_in_progress = false;
   g_recovery_close_scope       = 0;
}

// ── Part 4B: side basket money TP ─────────────────────────────────────
// Close the whole BUY side or SELL side when that side's NET floating profit
// reaches target. This closes winners AND current floating losers together.
void RecoveryManageSideBasketMoneyTP()
{
   if(!EnableRecoveryGridMode)               return;
   if(!Recovery_UseSideBasketMoneyTP)        return;
   if(g_recovery_close_in_progress)          return;
   if(TimeCurrent() < g_recovery_pause_until) return;
   if(!TradingAllowed())                     return;

   for(int pass = 0; pass < 2; pass++)
   {
      ENUM_POSITION_TYPE ptype = (pass == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      ENUM_ORDER_TYPE    oside = (pass == 0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
      string             name  = (pass == 0 ? "BUY" : "SELL");
      double             target = (pass == 0 ? Recovery_BuyBasketTPMoney : Recovery_SellBasketTPMoney);
      if(target <= 0) continue;

      ulong  tickets[];
      double netProfit = 0.0;
      double winProfit = 0.0;
      double grossLoss = 0.0;
      int    n = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong pt = PositionGetTicket(i);
         if(pt == 0) continue;
         if(!PositionSelectByTicket(pt)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != ptype) continue;

         double pl = PositionGetDouble(POSITION_PROFIT);
         if(Recovery_SideBasketMoneyTP_InclSwap)
            pl += PositionGetDouble(POSITION_SWAP);

         netProfit += pl;
         if(pl > 0) winProfit += pl;
         if(pl < 0) grossLoss += -pl;

         int sz = ArraySize(tickets);
         ArrayResize(tickets, sz + 1);
         tickets[sz] = pt;
         n++;
      }

      if(n == 0) continue;
      if(netProfit < target) continue;
      if(!RecoveryPrecloseTicketsOK(tickets, target, 0.0, (ptype == POSITION_TYPE_BUY ? "side-buy-basket" : "side-sell-basket")))
         continue;

      PrintFormat("[RG SIDE BASKET TP] %s net=%.2f winners=%.2f losses=%.2f target=%.2f positions=%d",
                  name, netProfit, winProfit, grossLoss, target, n);

      g_recovery_close_in_progress = true;
      g_recovery_close_scope       = (ptype == POSITION_TYPE_BUY ? 2 : 3);

      PrintFormat("[RG SIDE BASKET TP] delete %s pendings before close", name);
      RecoveryDeletePendingsSide(oside);

      bool ok = RecoveryCloseTickets(tickets, (ptype == POSITION_TYPE_BUY ? "side-buy-basket" : "side-sell-basket"));

      PrintFormat("[RG SIDE BASKET TP] delete %s pendings after close", name);
      RecoveryDeletePendingsSide(oside);

      g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

      if(ok && RecoveryCountOpenPositionsByType(ptype) == 0)
      {
         g_recovery_close_in_progress = false;
         g_recovery_close_scope       = 0;
      }

      // Handle one side per pass/tick. This avoids mixing BUY and SELL closes
      // while prices/position list are changing.
      return;
   }
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

   // Saat hard recovery, turunkan target global agar EA bisa keluar dari kondisi rusak.
   double globalTP = (g_counter_hard_mode && Recovery_HardUseTighterTargets)
                     ? Recovery_HardGlobalBasketMoneyTP : Recovery_GlobalBasketMoneyTP;

   double netProfit = RecoveryOpenNetProfit();
   if(netProfit < (globalTP + Recovery_GlobalBasketCloseBuffer)) return;
   if(!RecoveryPrecloseAllByMagicOK(globalTP, Recovery_GlobalBasketCloseBuffer, "global-basket")) return;

   PrintFormat("[RG GLOBAL CLOSE] openNet=%.2f target=%.2f buffer=%.2f hard=%d",
               netProfit, globalTP, Recovery_GlobalBasketCloseBuffer, (int)g_counter_hard_mode);

   g_recovery_close_in_progress = true;
   g_recovery_close_scope       = 1; // retry handler may retry CloseAll only for global scope
   Print("[RG CLOSE] delete pendings before close");
   RecoveryDeletePendings();

   bool ok = RecoveryCloseAllPositionsByMagic("global-basket");

   Print("[RG CLOSE] delete pendings after close");
   RecoveryDeletePendings();

   g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;

   // Only release the flag if the whole basket is gone; otherwise retry.
   if(ok && RecoveryCountOpenPositionsByMagic() == 0)
   {
      g_recovery_close_in_progress = false;
      g_recovery_close_scope       = 0;
   }
}

// ── Part 7: close-in-progress handler ─────────────────────────────────
// While a close is in progress, never refill the grid. Keep retrying the
// close until the basket is empty, then arm the cooldown.
void RecoveryHandleCloseInProgress()
{
   if(!g_recovery_close_in_progress) return;

   RecoveryDeletePendings();

   if(g_recovery_close_scope == 1)
   {
      if(RecoveryCountOpenPositionsByMagic() > 0)
      {
         RecoveryCloseAllPositionsByMagic("retry-global-close");
         if(RecoveryCountOpenPositionsByMagic() > 0)
            return; // still failing → wait for next tick, no refill
      }
   }
   else if(g_recovery_close_scope == 2)
   {
      RecoveryDeletePendingsSide(ORDER_TYPE_BUY_LIMIT);
      if(RecoveryCountOpenPositionsByType(POSITION_TYPE_BUY) > 0)
      {
         RecoveryClosePositionsByType(POSITION_TYPE_BUY, "retry-side-buy-close");
         if(RecoveryCountOpenPositionsByType(POSITION_TYPE_BUY) > 0)
            return;
      }
   }
   else if(g_recovery_close_scope == 3)
   {
      RecoveryDeletePendingsSide(ORDER_TYPE_SELL_LIMIT);
      if(RecoveryCountOpenPositionsByType(POSITION_TYPE_SELL) > 0)
      {
         RecoveryClosePositionsByType(POSITION_TYPE_SELL, "retry-side-sell-close");
         if(RecoveryCountOpenPositionsByType(POSITION_TYPE_SELL) > 0)
            return;
      }
   }
   else
   {
      // Unknown/partial scope: never convert to CloseAll.
      Print("[RG CLOSE] unknown close scope; clearing close-in-progress without CloseAll retry");
   }

   // Requested basket/side is cleared.
   RecoveryDeletePendings();
   g_recovery_close_in_progress = false;
   g_recovery_close_scope       = 0;
   g_recovery_pause_until       = TimeCurrent() + Recovery_CloseCooldownSeconds;
}

// Floating-profit basket take-profit. When the net profit of all positions
// on symbol+magic reaches the target, close the whole basket together.
void RecoveryManageBasketMoneyTP()
{
    if(!EnableRecoveryGridMode)       return;
    if(!Recovery_UseBasketMoneyTP)    return;
    if(g_recovery_close_in_progress)  return;
    if(TimeCurrent() < g_recovery_pause_until) return;
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
    double required = Recovery_BasketMoneyTP + MathMax(0.0, Recovery_GlobalBasketCloseBuffer);
    if(netProfit < required) return;
    if(!RecoveryPrecloseTicketsOK(tickets, Recovery_BasketMoneyTP, MathMax(0.0, Recovery_GlobalBasketCloseBuffer), "basket-money-tp")) return;

    // Target reached → close the collected positions.
    g_recovery_close_in_progress = true;
    g_recovery_close_scope       = 1;

    Print("[RG BASKET TP] delete pendings before close");
    RecoveryDeletePendings();

    bool ok = RecoveryCloseTickets(tickets, "basket-money-tp");

    // Remove stale recovery pendings; the next cycle rebuilds the grid around current price.
    RecoveryDeletePendings();

    g_recovery_pause_until = TimeCurrent() + Recovery_CloseCooldownSeconds;
    if(ok && RecoveryCountOpenPositionsByMagic() == 0)
    {
       g_recovery_close_in_progress = false;
       g_recovery_close_scope       = 0;
    }

    PrintFormat("[RG BASKET TP] net=%.2f winners=%.2f target=%.2f buffer=%.2f positions=%d",
                netProfit, winProfit, Recovery_BasketMoneyTP, Recovery_GlobalBasketCloseBuffer, n);
}

// Emergency exception: equity-based basket stop-loss can realize a net loss.
// Keep Recovery_UseBasketEquitySL=false for strict "never close net loss" mode.
// When enabled by the user, this is a hard tail-risk guard. When the floating loss
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
      {
         closed++;
         NoteTradeResult((int)trade.ResultRetcode());
      }
      else
      {
         int rc = (int)trade.ResultRetcode();
         NoteTradeResult(rc);
         PrintFormat("[RG BASKET SL] close failed ticket=%I64u ret=%d %s",
                     tickets[i], rc, trade.ResultRetcodeDescription());
         if(rc == 10026) break; // server blocked; stop this pass
      }
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

    RecoveryUpdateSideDDBrake();
    RecoveryUpdateTrendMode();
    RecoveryUpdateCounterState();
    if(!RecoveryAllowBuyGrid())  RecoveryDeletePendingsSide(ORDER_TYPE_BUY_LIMIT);
    if(!RecoveryAllowSellGrid()) RecoveryDeletePendingsSide(ORDER_TYPE_SELL_LIMIT);

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

   RecoveryManageSideBasketMoneyTP();
   if(g_recovery_close_in_progress)
   {
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

   // ── Counter offset close: pakai profit counter untuk tutup loser lama ──
   RecoveryManageCounterOffsetClose();
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
      RecoveryEnsureTotalLossTrendRecovery();
      RecoveryEnsureBuyGrid();
      RecoveryEnsureSellGrid();
      // Counter grid searah trend di sisi berlawanan dari sisi rusak.
      RecoveryEnsureCounterGrid();
   }
   else
   {
      // Keep recovery pendings cleared while protection/news is active.
      RecoveryDeletePendings();
   }

   // ── Basket equity stop-loss (hard tail-risk guard, every tick) ────
   RecoveryManageBasketEquitySL();

   // ── Basket / common trailing (also runs on every tick) ────────────
   RecoveryManageSideBasketMoneyTP();
   RecoveryManageBasketMoneyTP();
   RecoveryManageBasketTrailing();

   // ── HUD ───────────────────────────────────────────────────────────
   double lp    = CurrentLossPercent();
   int    obuy  = CountEAOpenBuyPositions();
   int    osell = CountEAOpenSellPositions();
   string stP   = g_in_protection ? "⚠ PROTECTION ON" : "OK";
   string stN   = news_active      ? "⚠ NEWS BLOCK ON" : "OK";
   string stSrv = "OK";
   if(g_server_blocked && TimeCurrent() < g_server_blocked_until)
   {
      long blockedSec = (g_server_blocked_since > 0) ? (long)(TimeCurrent() - g_server_blocked_since) : 0;
      stSrv = StringFormat("⚠ SERVER BLOCKED TRADING (10026) — %lds, retry tiap %ds", blockedSec, g_server_block_retry_sec);
   }
   string ninfo = "";
   if(news_active && ntime > 0)
      ninfo = StringFormat("  → %s (%s) @ %s", nname, ncur, TimeToString(ntime, TIME_DATE|TIME_MINUTES));

   // Durasi EA di TREND_PAUSE (info HUD, bukan trigger aksi). Acuan: Recovery_PauseHudReferenceMinutes.
   string pauseInfo = "";
   if(g_recovery_trend_mode == TREND_PAUSE && g_recovery_pause_started > 0)
   {
      long pausedSec = (long)(TimeCurrent() - g_recovery_pause_started);
      long pausedMin = pausedSec / 60;
      long refMin    = (long)MathMax(0, Recovery_PauseHudReferenceMinutes);
      string flag    = (refMin > 0 && pausedMin >= refMin) ? " ⚠ lama (tunggu sinyal arah)" : "";
      bool   relaxOn = (Recovery_RelaxGuardOnLongPause && refMin > 0 && pausedMin >= refMin);
      string relax   = relaxOn ? StringFormat(" [relax guard ADX>=%.0f]", MathMin(Recovery_IgnoreGuardADXMin, Recovery_RelaxGuardADXMin)) : "";
      pauseInfo = StringFormat("  | PAUSE %ldm%lds / ref %ldm%s%s", pausedMin, pausedSec % 60, refMin, flag, relax);
   }

   // Durasi counter di SOFT_BRAKE. Jika lama dan trend sudah searah counter,
   // CounterMinADX bisa dilonggarkan; syarat arah trend tetap wajib.
   string softBrakeInfo = "";
   if(g_counter_state == COUNTER_SOFT_BRAKE && g_counter_softbrake_started > 0)
   {
      long sbSec = (long)(TimeCurrent() - g_counter_softbrake_started);
      long sbMin = sbSec / 60;
      long refMin = (long)MathMax(0, Recovery_SoftBrakeRelaxMinutes);
      bool relaxOn = (Recovery_RelaxCounterADXOnLongSoftBrake && refMin > 0 && sbMin >= refMin);
      string relax = relaxOn ? StringFormat(" [relax counter ADX>=%.0f]", RecoveryEffectiveCounterMinADX()) : "";
      softBrakeInfo = StringFormat("  | SB %ldm%lds / ref %ldm%s", sbMin, sbSec % 60, refMin, relax);
   }

   double openNet = RecoveryOpenNetProfit();
   double tlrLoss = (openNet < 0.0 ? -openNet : 0.0);
   string tlrInfo = Recovery_UseTotalLossTrendRecovery
      ? StringFormat("ON cnt:%d lot:%.2f next:%.2f trigger:%.2f",
                     RecoveryTLRCountPositions(), RecoveryTLRLots(), RecoveryTLRLotByLoss(tlrLoss), Recovery_TotalLossTrendStartMoney)
      : "OFF";

   string hud =
      "══ RECOVERY GRID MODE (XAUUSD bidirectional) ══\n" +
      "News   : " + stN + ninfo + "\n" +
      "Protect: " + stP + "\n" +
      "Server : " + stSrv + "\n" +
      "Dashboard: " + (g_dashboard_ea_enabled ? "ON" : "OFF") + "\n" +
      "BUY pos: " + IntegerToString(obuy) + " / " + (effMaxBuy > 0 ? IntegerToString(effMaxBuy) : "∞") +
      "  |  SELL pos: " + IntegerToString(osell) + " / " + (effMaxSell > 0 ? IntegerToString(effMaxSell) : "∞") + "\n" +
      "Total pos: " + IntegerToString(obuy + osell) + " / " + (Recovery_MaxTotalPositions > 0 ? IntegerToString(Recovery_MaxTotalPositions) : "∞") + "\n" +
      "Trend mode: " + RecoveryTrendModeText(g_recovery_trend_mode) +
      "  | DD brake BUY:" + (g_recovery_buy_dd_active ? "ON" : "off") +
      " SELL:" + (g_recovery_sell_dd_active ? "ON" : "off") + pauseInfo + "\n" +
      "Counter: " + (Recovery_UseCounterRecovery ? RecoveryCounterStateText(g_counter_state) : "OFF") +
      (g_counter_damaged_side == POSITION_TYPE_BUY  ? " (BUY rusak→SELL counter)" :
       g_counter_damaged_side == POSITION_TYPE_SELL ? " (SELL rusak→BUY counter)" : "") +
      (g_counter_hard_mode ? " [HARD]" : "") +
      "  cnt pos:" + IntegerToString(RecoveryCountCounterPositions()) + softBrakeInfo + "\n" +
      "TLR: " + tlrInfo + "\n" +
      "Floating loss: " + DoubleToString(lp, 2) + "% (limit " + DoubleToString(MaxFloatingLossPercent, 1) + "%)\n" +
      "Grid step: " + DoubleToString(Recovery_GridStep, 2) +
      "  BL levels: " + IntegerToString(Recovery_BuyLimitCount) +
      "  SL levels: " + IntegerToString(Recovery_SellLimitCount) + "\n" +
      "Basket  → BE:" + DoubleToString(Recovery_BasketBETrigger, 2) +
      " lock+" + DoubleToString(Recovery_BasketLockProfit, 2) +
      "  trail:" + DoubleToString(Recovery_BasketTrailDistance, 2) + "\n" +
      "TP:" + (Recovery_UseTP ? DoubleToString(Recovery_TPDistance,2) : "OFF") +
      "  InitSL:" + (Recovery_UseInitialSL ? DoubleToString(Recovery_InitialSLDistance,2) : "OFF") + "\n" +
      "Basket MoneyTP: " + (Recovery_UseBasketMoneyTP ? DoubleToString(Recovery_BasketMoneyTP,2) : "OFF") +
      (Recovery_UseBasketMoneyTP ? (Recovery_BasketMoneyTP_ProfitOnly ? " (legacy ignored: net basket)" : " (net basket)") : "") + "\n" +
      "Side Basket TP: " + (Recovery_UseSideBasketMoneyTP ? ("BUY " + DoubleToString(Recovery_BuyBasketTPMoney,2) + " / SELL " + DoubleToString(Recovery_SellBasketTPMoney,2)) : "OFF") + "\n" +
      "Basket EquitySL: " + (Recovery_UseBasketEquitySL ? (DoubleToString(Recovery_BasketEquitySL_Percent,1) + "% equity") : "OFF");
   Comment(hud);
}

//======================================================================
// MAIN LOGIC CYCLE
//======================================================================
void RunLogic()
{
   RunRecoveryLogic();
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_scan_interval = (ScanInterval < 1) ? 60 : ScanInterval;

   // Init recovery indicator handles
   if(!InitIndicators()) return INIT_FAILED;

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
   // Fast recovery exit management on every tick.
   RecoveryHandleCloseInProgress();

   if(!g_recovery_close_in_progress && TimeCurrent() >= g_recovery_pause_until)
   {
      RecoveryManageSideBasketMoneyTP();
      if(!g_recovery_close_in_progress)
         RecoveryManageSelectiveNetClose();
      if(!g_recovery_close_in_progress)
         RecoveryManageGlobalBasketClose();
      if(!g_recovery_close_in_progress)
      {
         RecoveryUpdateSideDDBrake();
         RecoveryUpdateTrendMode();
         RecoveryUpdateCounterState();
         RecoveryManageCounterOffsetClose();
      }
   }

   if(g_recovery_close_in_progress)
      return;

   RecoveryManageBasketEquitySL();
   RecoveryManageSideBasketMoneyTP();
   RecoveryManageBasketMoneyTP();
   RecoveryManageBasketTrailing();
}

void OnTradeTransaction(const MqlTradeTransaction &,
                        const MqlTradeRequest &,
                        const MqlTradeResult &)
{
   RunLogic(); // refresh recovery state after any trade event
}
//+------------------------------------------------------------------+

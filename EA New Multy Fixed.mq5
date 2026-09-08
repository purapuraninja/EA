//+------------------------------------------------------------------+
//|                     EA_New_Multy_Fixed.mq5                        |
//|      A/B/C/D + SLTP + TP1 + BE + Trailing + DD + Compounding      |
//|      London-NY Session 14-05 GMT+7 (TimeGMT based)                |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "EA lengkap A/B/C/D. Strategi D default. Ada compounding + session London-NY 14-05 GMT+7 + stop safety + DD guards (peak reset daily)."

#include <Trade/Trade.mqh>
CTrade trade;

//============================= INPUTS ==============================//
enum ENUM_STRATEGY_MODE
{
   STRAT_A_MA_CROSS          = 0,
   STRAT_B_RSI_REV           = 1,
   STRAT_C_DONCHIAN_BREAKOUT = 2,
   STRAT_D_MACD_TREND_ATR    = 3
};

enum ENUM_SL_MODE   { SL_FIXED_POINTS=0, SL_ATR_MULT=1 };
enum ENUM_TP_MODE   { TP_FIXED_POINTS=0, TP_RR_MULT=1, TP_ATR_MULT=2 };
enum ENUM_TRAIL_MODE{ TRAIL_OFF=0, TRAIL_POINTS=1, TRAIL_ATR_MULT=2 };

enum ENUM_TIME_MODE
{
   TIME_USE_SERVER = 0,      // TimeCurrent()
   TIME_USE_GMT_OFFSET = 1   // TimeGMT() + offset
};

enum ENUM_COMP_MODE
{
   COMP_OFF = 0,
   COMP_FIXED_LOT_ONLY = 1,  // compounding hanya saat InpUseFixedLot=true
   COMP_ALL_LOT = 2          // compounding untuk semua lot hasil kalkulasi
};

input string              InpEAName              = "EA_New_Multy_Fixed";
input ENUM_STRATEGY_MODE  InpStrategy            = STRAT_D_MACD_TREND_ATR;
input ENUM_TIMEFRAMES     InpTF                  = PERIOD_CURRENT;

input ulong               InpMagic               = 24012026;
input bool                InpOnePositionOnly     = true;
input bool                InpEntryOnNewBar       = true;
input bool                InpManageEveryTick     = true;
input int                 InpDeviationPoints     = 40;

//--- Risk & Lot
input bool                InpUseFixedLot         = false;
input double              InpFixedLot            = 0.10;
input double              InpRiskPercent         = 1.0;     // % balance per trade (untuk risk-based)

//--- Compounding
input ENUM_COMP_MODE      InpCompoundingMode     = COMP_FIXED_LOT_ONLY;
input bool                InpCompoundUseEquity   = false;   // false=balance, true=equity
input double              InpCompoundingMaxFactor= 10.0;    // batas maksimal pengali lot (anti kebablasan)

//--- Filters
input int                 InpMaxSpreadPoints     = 300;     // XAU spread 160 pts -> kasih buffer
input bool                InpUseSessionFilter    = true;    // London-NY 14-05 GMT+7
input ENUM_TIME_MODE      InpSessionTimeMode     = TIME_USE_GMT_OFFSET;
input int                 InpSessionGMTOffset    = 7;       // GMT+7
input int                 InpStartHour           = 14;      // 14:00
input int                 InpEndHour             = 5;       // 05:00 (wrap midnight)

//--- SL/TP
input ENUM_SL_MODE        InpSLMode              = SL_ATR_MULT;
input int                 InpSLPoints            = 280;     // fallback fixed SL points
input int                 InpATRPeriod           = 14;
input double              InpSL_ATR_Mult         = 2.2;

input ENUM_TP_MODE        InpTPMode              = TP_RR_MULT;
input int                 InpTPPoints            = 420;
input double              InpTP_RR               = 2.0;
input double              InpTP_ATR_Mult         = 3.0;

//--- Trailing
input ENUM_TRAIL_MODE     InpTrailMode           = TRAIL_ATR_MULT;
input int                 InpTrailPoints         = 260;
input double              InpTrail_ATR_Mult      = 1.6;

//--- TP1 Partial Close
input bool                InpEnableTP1           = true;
input int                 InpTP1Points           = 650;     // M15 style runner, untuk M5 bisa 450
input double              InpTP1_RR              = 0.8;     // dipakai kalau TP1Points=0
input double              InpTP1_ClosePercent    = 40.0;    // close % at TP1

//--- Breakeven
input bool                InpEnableBE            = true;
input int                 InpBE_TriggerPoints    = 650;
input int                 InpBE_OffsetPoints     = 60;

//--- Behavior
input bool                InpCloseOnOppSignal    = true;

//--- DD Guards
input bool                InpDisableTradingOnDD  = true;
input bool                InpDD_ClosePositions   = false;
input double              InpMaxDailyDDPercent   = 4.0;     // equity vs start-of-day
input double              InpMaxEquityDDPercent  = 8.0;     // equity vs peak-of-day (reset daily)

//================= Strategy Parameters =================//
// A: MA Cross
input int                 InpA_FastMAPeriod      = 12;
input int                 InpA_SlowMAPeriod      = 26;
input ENUM_MA_METHOD      InpA_MAMethod          = MODE_EMA;
input ENUM_APPLIED_PRICE  InpA_Price             = PRICE_CLOSE;

// B: RSI reversal + MA filter
input int                 InpB_RSIPeriod         = 14;
input double              InpB_RSI_BuyLevel      = 30.0;
input double              InpB_RSI_SellLevel     = 70.0;
input int                 InpB_FilterMAPeriod    = 200;
input ENUM_MA_METHOD      InpB_FilterMAMethod    = MODE_EMA;

// C: Donchian breakout
input int                 InpC_ChannelPeriod     = 20;

// D: MACD trend + ATR min filter
input int                 InpD_MACD_Fast         = 12;
input int                 InpD_MACD_Slow         = 26;
input int                 InpD_MACD_Signal       = 9;
input int                 InpD_TrendMAPeriod     = 200;
input ENUM_MA_METHOD      InpD_TrendMAMethod     = MODE_EMA;
input int                 InpD_MinATRPoints      = 220;

//============================= GLOBALS =============================//
int hMA_fast   = INVALID_HANDLE;
int hMA_slow   = INVALID_HANDLE;
int hRSI       = INVALID_HANDLE;
int hMA_filter = INVALID_HANDLE;
int hATR       = INVALID_HANDLE;
int hMACD      = INVALID_HANDLE;
int hMA_trend  = INVALID_HANDLE;

datetime g_lastBarTime = 0;

// per-position state (1 posisi only)
ulong   g_posIdentifier = 0;
bool    g_tp1Done       = false;
bool    g_beDone        = false;
double  g_tp1Price      = 0.0;

// DD tracking
int     g_dayOfYear      = -1;
double  g_dayStartEquity = 0.0;
double  g_peakEquity     = 0.0;
bool    g_ddTriggered    = false;

// Compounding base
double  g_compBase       = 0.0;

//=========================== BASIC UTILS ===========================//
double Pnt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int Dig()     { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

bool IsTradeAllowedNow()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

bool SpreadAllowed()
{
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

datetime SessionTimeNow()
{
   if(InpSessionTimeMode == TIME_USE_GMT_OFFSET)
      return (datetime)(TimeGMT() + (InpSessionGMTOffset * 3600));
   return TimeCurrent();
}

bool SessionAllowed()
{
   if(!InpUseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(SessionTimeNow(), dt);
   int h = dt.hour;

   if(InpStartHour < InpEndHour)
      return (h >= InpStartHour && h < InpEndHour);

   // wrap midnight (contoh 14 -> 5)
   return (h >= InpStartHour || h < InpEndHour);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t == 0) return false;
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

//================== SAFE CopyBuffer (NO STATIC ARRAY) ==============//
bool GetBufferLast2(const int handle, const int bufferIndex, double &v0, double &v1)
{
   if(handle == INVALID_HANDLE) return false;

   double arr[];
   ArrayResize(arr, 2);
   ArraySetAsSeries(arr, true);

   int copied = CopyBuffer(handle, bufferIndex, 0, 2, arr);
   if(copied != 2) return false;

   v0 = arr[0];
   v1 = arr[1];
   return true;
}

bool GetATR(double &atr0)
{
   if(hATR == INVALID_HANDLE) return false;

   double a[];
   ArrayResize(a, 1);
   ArraySetAsSeries(a, true);

   if(CopyBuffer(hATR, 0, 0, 1, a) != 1) return false;
   atr0 = a[0];
   return true;
}

//===================== POSITION HELPERS (NO SelectByIndex) =========//
int PositionsCountByMagic()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      cnt++;
   }
   return cnt;
}

bool GetCurrentPosition(bool &isBuy, ulong &identifier, double &openPrice, double &sl, double &tp, double &volume)
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      isBuy = (type == POSITION_TYPE_BUY);

      identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      sl         = PositionGetDouble(POSITION_SL);
      tp         = PositionGetDouble(POSITION_TP);
      volume     = PositionGetDouble(POSITION_VOLUME);
      return true;
   }
   return false;
}

double NormalizeVolume(double volIn)
{
   double v = volIn;
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0) vstep = vmin;

   if(v < vmin) v = vmin;
   if(v > vmax) v = vmax;

   double steps = MathFloor((v - vmin) / vstep + 0.5);
   v = vmin + steps * vstep;
   if(v > vmax) v = vmax;

   return NormalizeDouble(v, 2);
}

//===================== STOP SAFETY (STOPS + FREEZE) ================//
int StopsLevelPoints()  { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
int FreezeLevelPoints() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); }

bool StopsAreValid(bool isBuy, double refPrice, double sl, double tp)
{
   double p = Pnt();
   int stops = StopsLevelPoints();
   if(stops < 0) stops = 0;
   double minDist = stops * p;

   if(sl > 0.0)
   {
      if(isBuy  && (refPrice - sl) < minDist) return false;
      if(!isBuy && (sl - refPrice) < minDist) return false;
   }
   if(tp > 0.0)
   {
      if(isBuy  && (tp - refPrice) < minDist) return false;
      if(!isBuy && (refPrice - tp) < minDist) return false;
   }
   return true;
}

bool ModifyAllowedByFreeze(bool isBuy, double newSL, double newTP)
{
   int fr = FreezeLevelPoints();
   if(fr <= 0) return true;

   double p = Pnt();
   double dist = fr * p;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(newSL > 0.0)
   {
      if(isBuy  && (bid - newSL) < dist) return false;
      if(!isBuy && (newSL - ask) < dist) return false;
   }
   if(newTP > 0.0)
   {
      if(isBuy  && (newTP - bid) < dist) return false;
      if(!isBuy && (ask - newTP) < dist) return false;
   }
   return true;
}

bool PositionModifySafe(bool isBuy, double newSL, double newTP)
{
   if(!ModifyAllowedByFreeze(isBuy, newSL, newTP))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double ref = isBuy ? bid : ask;

   if(!StopsAreValid(isBuy, ref, newSL, newTP))
      return false;

   trade.SetExpertMagicNumber(InpMagic);
   return trade.PositionModify(_Symbol, newSL, newTP);
}

//============================== DD GUARDS ===========================//
// PATCH: peak equity di-reset HARIAN -> anti EA mati permanen
void UpdateDDState()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(g_dayOfYear != dt.day_of_year)
   {
      g_dayOfYear = dt.day_of_year;

      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(g_dayStartEquity <= 0.0)
         g_dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE);

      g_peakEquity = g_dayStartEquity;   // <-- reset peak harian
      g_ddTriggered = false;             // allow trade again
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return;

   if(g_peakEquity <= 0.0) g_peakEquity = equity;
   if(equity > g_peakEquity) g_peakEquity = equity;

   double dailyDD = 0.0;
   if(g_dayStartEquity > 0.0)
      dailyDD = (g_dayStartEquity - equity) / g_dayStartEquity * 100.0;

   double peakDD = 0.0;
   if(g_peakEquity > 0.0)
      peakDD = (g_peakEquity - equity) / g_peakEquity * 100.0;

   bool hitDaily = (InpMaxDailyDDPercent  > 0.0 && dailyDD >= InpMaxDailyDDPercent);
   bool hitPeak  = (InpMaxEquityDDPercent > 0.0 && peakDD  >= InpMaxEquityDDPercent);

   if((hitDaily || hitPeak) && InpDisableTradingOnDD)
      g_ddTriggered = true;
}

void EnforceDDAction()
{
   if(!g_ddTriggered) return;
   if(!InpDD_ClosePositions) return;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.PositionClose(_Symbol);
}

//=========================== COMPOUNDING ===========================//
double CurrentForComp()
{
   return (InpCompoundUseEquity ? AccountInfoDouble(ACCOUNT_EQUITY) : AccountInfoDouble(ACCOUNT_BALANCE));
}

double ApplyCompoundingIfNeeded(double lot)
{
   if(InpCompoundingMode == COMP_OFF) return lot;

   bool apply = (InpCompoundingMode == COMP_ALL_LOT) || (InpCompoundingMode == COMP_FIXED_LOT_ONLY && InpUseFixedLot);
   if(!apply) return lot;

   if(g_compBase <= 0.0) return lot;

   double cur = CurrentForComp();
   if(cur <= 0.0) return lot;

   double factor = cur / g_compBase;
   if(factor < 0.1) factor = 0.1;
   if(InpCompoundingMaxFactor > 0.0 && factor > InpCompoundingMaxFactor)
      factor = InpCompoundingMaxFactor;

   return NormalizeVolume(lot * factor);
}

//=========================== LOT / SLTP ============================//
double CalcLotByRisk(bool isBuy, double entryPrice, double slPrice)
{
   double lot = InpFixedLot;

   if(!InpUseFixedLot)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = bal * (InpRiskPercent / 100.0);
      if(riskMoney <= 0.0) lot = InpFixedLot;
      else
      {
         double profit = 0.0;
         bool ok = false;

         if(isBuy)
            ok = OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entryPrice, slPrice, profit);
         else
            ok = OrderCalcProfit(ORDER_TYPE_SELL, _Symbol, 1.0, entryPrice, slPrice, profit);

         if(!ok) lot = InpFixedLot;
         else
         {
            double loss1lot = MathAbs(profit);
            if(loss1lot <= 0.0) lot = InpFixedLot;
            else lot = riskMoney / loss1lot;
         }
      }
   }

   lot = NormalizeVolume(lot);
   lot = ApplyCompoundingIfNeeded(lot);
   return lot;
}

void CalcSLTP(bool isBuy, double &slPrice, double &tpPrice)
{
   double p = Pnt();
   int digits = Dig();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = isBuy ? ask : bid;

   double slPts = (double)InpSLPoints;
   if(InpSLMode == SL_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr))
         slPts = (atr / p) * InpSL_ATR_Mult;
   }
   if(slPts < 40.0) slPts = 40.0;

   double slDist = slPts * p;
   slPrice = isBuy ? (entry - slDist) : (entry + slDist);

   if(InpTPMode == TP_FIXED_POINTS)
   {
      double tpDist = (double)InpTPPoints * p;
      if(tpDist < 40.0 * p) tpDist = 40.0 * p;
      tpPrice = isBuy ? (entry + tpDist) : (entry - tpDist);
   }
   else if(InpTPMode == TP_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr))
      {
         double tpDist = atr * InpTP_ATR_Mult;
         tpPrice = isBuy ? (entry + tpDist) : (entry - tpDist);
      }
      else
      {
         double rr = (InpTP_RR > 0.0 ? InpTP_RR : 1.0);
         tpPrice = isBuy ? (entry + slDist * rr) : (entry - slDist * rr);
      }
   }
   else // TP_RR_MULT
   {
      double rr = (InpTP_RR > 0.0 ? InpTP_RR : 1.0);
      tpPrice = isBuy ? (entry + slDist * rr) : (entry - slDist * rr);
   }

   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);
}

//============================= STRATEGIES ==========================//
bool SignalA(bool &buy, bool &sell)
{
   buy = false; sell = false;
   double f0,f1,s0,s1;
   if(!GetBufferLast2(hMA_fast, 0, f0, f1)) return false;
   if(!GetBufferLast2(hMA_slow, 0, s0, s1)) return false;

   if(f1 <= s1 && f0 > s0) buy = true;
   if(f1 >= s1 && f0 < s0) sell = true;
   return true;
}

bool SignalB(bool &buy, bool &sell)
{
   buy = false; sell = false;
   double r0,r1, ma0,ma1;
   if(!GetBufferLast2(hRSI, 0, r0, r1)) return false;
   if(!GetBufferLast2(hMA_filter, 0, ma0, ma1)) return false;

   double c0 = iClose(_Symbol, InpTF, 0);

   if(r0 < InpB_RSI_BuyLevel  && c0 > ma0) buy = true;
   if(r0 > InpB_RSI_SellLevel && c0 < ma0) sell = true;
   return true;
}

bool SignalC(bool &buy, bool &sell)
{
   buy = false; sell = false;
   int n = InpC_ChannelPeriod;
   if(n < 2) n = 2;

   int highestIdx = iHighest(_Symbol, InpTF, MODE_HIGH, n, 1);
   int lowestIdx  = iLowest(_Symbol, InpTF, MODE_LOW,  n, 1);
   if(highestIdx < 0 || lowestIdx < 0) return false;

   double hh = iHigh(_Symbol, InpTF, highestIdx);
   double ll = iLow(_Symbol, InpTF, lowestIdx);
   double c0 = iClose(_Symbol, InpTF, 0);

   if(c0 > hh) buy = true;
   if(c0 < ll) sell = true;
   return true;
}

bool SignalD(bool &buy, bool &sell)
{
   buy = false; sell = false;

   double macd0,macd1, sig0,sig1;
   if(!GetBufferLast2(hMACD, 0, macd0, macd1)) return false;
   if(!GetBufferLast2(hMACD, 1, sig0,  sig1))  return false;

   double t0,t1;
   if(!GetBufferLast2(hMA_trend, 0, t0, t1)) return false;

   double atr=0.0;
   if(!GetATR(atr)) return false;

   double atrPts = atr / Pnt();
   if(atrPts < (double)InpD_MinATRPoints) return true; // no signal, filter low vol

   double c0 = iClose(_Symbol, InpTF, 0);

   bool crossUp   = (macd1 <= sig1 && macd0 > sig0);
   bool crossDown = (macd1 >= sig1 && macd0 < sig0);

   if(crossUp   && c0 > t0) buy = true;
   if(crossDown && c0 < t0) sell = true;

   return true;
}

bool GetSignal(bool &buy, bool &sell)
{
   switch(InpStrategy)
   {
      case STRAT_A_MA_CROSS:          return SignalA(buy, sell);
      case STRAT_B_RSI_REV:           return SignalB(buy, sell);
      case STRAT_C_DONCHIAN_BREAKOUT: return SignalC(buy, sell);
      case STRAT_D_MACD_TREND_ATR:    return SignalD(buy, sell);
      default: buy=false; sell=false; return false;
   }
}

//==================== TP1/BE/TRAIL MANAGEMENT ======================//
void RefreshPositionState()
{
   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol))
   {
      g_posIdentifier = 0;
      g_tp1Done = false;
      g_beDone  = false;
      g_tp1Price = 0.0;
      return;
   }

   if(g_posIdentifier != id)
   {
      g_posIdentifier = id;
      g_tp1Done = false;
      g_beDone  = false;

      if(InpEnableTP1)
      {
         double p = Pnt();
         int digits = Dig();

         if(InpTP1Points > 0)
         {
            double dist = (double)InpTP1Points * p;
            g_tp1Price = isBuy ? (op + dist) : (op - dist);
         }
         else
         {
            double slDist = (sl > 0.0 ? MathAbs(op - sl) : (double)InpSLPoints * p);
            double rr = (InpTP1_RR > 0.0 ? InpTP1_RR : 0.8);
            double dist = slDist * rr;
            g_tp1Price = isBuy ? (op + dist) : (op - dist);
         }
         g_tp1Price = NormalizeDouble(g_tp1Price, digits);
      }
   }
}

void ApplyTP1PartialClose()
{
   if(!InpEnableTP1 || g_tp1Done) return;
   if(g_tp1Price <= 0.0) return;

   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol)) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool hit = isBuy ? (bid >= g_tp1Price) : (ask <= g_tp1Price);
   if(!hit) return;

   double pct = InpTP1_ClosePercent;
   if(pct <= 0.0) { g_tp1Done = true; return; }
   if(pct > 100.0) pct = 100.0;

   double volToClose = NormalizeVolume(vol * (pct / 100.0));
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double remaining = vol - volToClose;

   if(remaining < vmin)
   {
      if(pct >= 99.9)
      {
         trade.SetExpertMagicNumber(InpMagic);
         trade.SetDeviationInPoints(InpDeviationPoints);
         trade.PositionClose(_Symbol);
      }
      g_tp1Done = true;
      return;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   bool ok = trade.PositionClosePartial(_Symbol, volToClose);
   if(ok) g_tp1Done = true;
}

void ApplyBreakeven()
{
   if(!InpEnableBE || g_beDone) return;

   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol)) return;

   double p = Pnt();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPts = isBuy ? ((bid - op)/p) : ((op - ask)/p);
   if(profitPts < (double)InpBE_TriggerPoints) return;

   int digits = Dig();
   double offset = (double)InpBE_OffsetPoints * p;

   double newSL = isBuy ? (op + offset) : (op - offset);
   newSL = NormalizeDouble(newSL, digits);

   if(sl > 0.0)
   {
      if(isBuy  && newSL <= sl) return;
      if(!isBuy && newSL >= sl) return;
   }

   if(PositionModifySafe(isBuy, newSL, tp))
      g_beDone = true;
}

void ApplyTrailing()
{
   if(InpTrailMode == TRAIL_OFF) return;

   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol)) return;

   double p = Pnt();
   int digits = Dig();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double trailPts = (double)InpTrailPoints;

   if(InpTrailMode == TRAIL_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr))
         trailPts = (atr / p) * InpTrail_ATR_Mult;
   }
   if(trailPts < 60.0) trailPts = 60.0;

   double dist = trailPts * p;

   double newSL = sl;
   if(isBuy)
   {
      double desired = bid - dist;
      if(sl <= 0.0 || desired > sl) newSL = desired;
   }
   else
   {
      double desired = ask + dist;
      if(sl <= 0.0 || desired < sl) newSL = desired;
   }

   newSL = NormalizeDouble(newSL, digits);

   if(sl > 0.0)
   {
      if(isBuy  && newSL <= sl) return;
      if(!isBuy && newSL >= sl) return;
   }

   PositionModifySafe(isBuy, newSL, tp);
}

//============================= TRADE OPS ===========================//
bool OpenTrade(bool isBuy)
{
   if(!IsTradeAllowedNow()) return false;

   double sl=0.0, tp=0.0;
   CalcSLTP(isBuy, sl, tp);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = isBuy ? ask : bid;

   if(!StopsAreValid(isBuy, entry, sl, tp))
      return false;

   double lot = CalcLotByRisk(isBuy, entry, sl);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   if(isBuy)
      return trade.Buy(lot, _Symbol, 0.0, sl, tp, InpEAName);
   else
      return trade.Sell(lot, _Symbol, 0.0, sl, tp, InpEAName);
}

bool ClosePosition()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   return trade.PositionClose(_Symbol);
}

//============================= LIFECYCLE ===========================//
int OnInit()
{
   // indicators
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);

   // A
   hMA_fast = iMA(_Symbol, InpTF, InpA_FastMAPeriod, 0, InpA_MAMethod, InpA_Price);
   hMA_slow = iMA(_Symbol, InpTF, InpA_SlowMAPeriod, 0, InpA_MAMethod, InpA_Price);

   // B
   hRSI = iRSI(_Symbol, InpTF, InpB_RSIPeriod, PRICE_CLOSE);
   hMA_filter = iMA(_Symbol, InpTF, InpB_FilterMAPeriod, 0, InpB_FilterMAMethod, PRICE_CLOSE);

   // D
   hMACD = iMACD(_Symbol, InpTF, InpD_MACD_Fast, InpD_MACD_Slow, InpD_MACD_Signal, PRICE_CLOSE);
   hMA_trend = iMA(_Symbol, InpTF, InpD_TrendMAPeriod, 0, InpD_TrendMAMethod, PRICE_CLOSE);

   if(hATR == INVALID_HANDLE ||
      hMA_fast == INVALID_HANDLE || hMA_slow == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hMA_filter == INVALID_HANDLE ||
      hMACD == INVALID_HANDLE || hMA_trend == INVALID_HANDLE)
   {
      return INIT_FAILED;
   }

   g_lastBarTime = iTime(_Symbol, InpTF, 0);

   // DD init
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) g_dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity = g_dayStartEquity;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayOfYear = dt.day_of_year;

   // Compounding base
   g_compBase = CurrentForComp();
   if(g_compBase <= 0.0) g_compBase = AccountInfoDouble(ACCOUNT_BALANCE);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hMA_fast   != INVALID_HANDLE) IndicatorRelease(hMA_fast);
   if(hMA_slow   != INVALID_HANDLE) IndicatorRelease(hMA_slow);
   if(hRSI       != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hMA_filter != INVALID_HANDLE) IndicatorRelease(hMA_filter);
   if(hATR       != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hMACD      != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hMA_trend  != INVALID_HANDLE) IndicatorRelease(hMA_trend);
}

void OnTick()
{
   // DD
   UpdateDDState();
   EnforceDDAction();

   // state + manage
   RefreshPositionState();

   if(InpManageEveryTick)
   {
      ApplyTP1PartialClose();
      ApplyBreakeven();
      ApplyTrailing();
   }

   // block new trades on DD
   if(g_ddTriggered) return;

   // entry filters
   if(!SpreadAllowed()) return;
   if(!SessionAllowed()) return;
   if(!IsTradeAllowedNow()) return;

   if(InpEntryOnNewBar)
   {
      if(!IsNewBar()) return;
   }

   bool buySig=false, sellSig=false;
   if(!GetSignal(buySig, sellSig)) return;
   if(!buySig && !sellSig) return;

   bool hasPos=false, posBuy=false;
   ulong id=0; double op=0.0, sl=0.0, tp=0.0, vol=0.0;
   hasPos = GetCurrentPosition(posBuy, id, op, sl, tp, vol);

   if(InpOnePositionOnly && PositionsCountByMagic() > 0 && !hasPos)
      return;

   if(hasPos && InpCloseOnOppSignal)
   {
      if((posBuy && sellSig) || (!posBuy && buySig))
      {
         ClosePosition();
         if(buySig)  OpenTrade(true);
         if(sellSig) OpenTrade(false);
      }
      return;
   }

   if(hasPos) return;

   if(buySig)  OpenTrade(true);
   if(sellSig) OpenTrade(false);
}
//+------------------------------------------------------------------+

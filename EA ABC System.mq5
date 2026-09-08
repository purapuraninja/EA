//+------------------------------------------------------------------+
//|  XAUUSDm_MultiSystem_HWR_MR_RANGE_LNY_Full.mq5                    |
//|  Multi-System Portfolio:                                          |
//|   - System A: HWR Trend Pullback (M5 entry + M15 confirm)         |
//|   - System B: Mean Reversion (EMA200 deviation + RSI extreme)     |
//|   - System C: Range Scalper (BBands + RSI, only when ranging)     |
//|  Extras: London-NY WIB filter, Max 2 positions total, DD Guards,  |
//|          ATR/FIX SLTP, Partial TP1, BE, Trailing, StopSafety      |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//============================== INPUT ==============================
input string          InpSymbol              = "";          // empty = current chart symbol
input ENUM_TIMEFRAMES InpTF_Entry            = PERIOD_M5;
input ENUM_TIMEFRAMES InpTF_Filter           = PERIOD_M15;

// --- Time filter (WIB = GMT+7 via TimeGMT)
input bool   InpUseTimeFilterWIB   = true;
input int    InpStartHourWIB       = 14;
input int    InpStartMinuteWIB     = 0;
input int    InpEndHourWIB         = 5;
input int    InpEndMinuteWIB       = 0;
input bool   InpTradeMonToFriOnly  = true;

// --- Execution
input int    InpMaxSpreadPoints    = 260;      // spread kamu ~160 (OK)
input int    InpDeviationPoints    = 80;
input int    InpMaxPositionsTotal  = 2;        // keep max 2 positions total
input bool   InpOnePosPerSystem    = true;     // 1 position per system

// --- Money management
input bool   InpUseCompoundStep    = true;
input double InpBaseBalance        = 100.0;
input double InpBaseLot            = 0.01;
input double InpStepBalance        = 50.0;
input double InpLotStep            = 0.01;
input double InpMinLot             = 0.01;
input double InpMaxLot             = 0.30;

// --- Risk Guards (Prop style)
input bool   InpUseDailyDDGuard    = true;
input double InpDailyDDPercent     = 4.0;      // % drop from WIB day-start equity
input bool   InpUseOverallDDGuard  = true;
input double InpOverallDDPercent   = 12.0;     // % drop from peak equity since EA start

// --- Stops (shared)
input bool   InpUseATRStops        = true;
input int    InpATRPeriod          = 14;

// System A (HWR) SL/TP
input double InpA_ATR_SL_Mult      = 1.25;
input double InpA_ATR_TP_Mult      = 1.30;
input int    InpA_SL_Points        = 1300;
input int    InpA_TP_Points        = 1600;

// System B (MR) SL/TP (wider SL, smaller TP)
input double InpB_ATR_SL_Mult      = 1.55;
input double InpB_ATR_TP_Mult      = 0.95;
input int    InpB_SL_Points        = 1600;
input int    InpB_TP_Points        = 900;

// System C (Range Scalper) SL/TP (small TP, controlled SL)
input double InpC_ATR_SL_Mult      = 1.10;
input double InpC_ATR_TP_Mult      = 0.65;
input int    InpC_SL_Points        = 900;
input int    InpC_TP_Points        = 550;

// --- Partial TP1 + BE + Trailing (shared)
input bool   InpUsePartialTP1       = true;
input double InpTP1_ClosePercent    = 50.0;
input bool   InpTP1_UseATR          = true;
input double InpTP1_ATR_Mult        = 0.70;
input int    InpTP1_Points          = 800;
input bool   InpTP1_MoveSLToBE      = true;
input int    InpTP1_BE_OffsetPoints = 40;

input bool   InpUseBreakEven       = true;
input int    InpBE_StartPoints     = 900;
input int    InpBE_OffsetPoints    = 70;

input bool   InpUseTrailing        = true;
input int    InpTrailStartPoints   = 1400;
input int    InpTrailDistance      = 850;
input int    InpTrailStep          = 90;

// --- System A: HWR settings
input bool   InpEnableSystemA      = true;
input int    InpA_MagicOffset      = 10;
input int    InpA_EmaFast          = 20;
input int    InpA_EmaSlow          = 50;
input int    InpA_RsiPeriod        = 14;
input double InpA_RSI_BuyMin       = 52.0;
input double InpA_RSI_SellMax      = 48.0;
input int    InpA_PullbackMaxPts   = 650;
input int    InpA_MinTrendPts      = 150;
input double InpA_ImpulseATRMult   = 2.2;
input int    InpA_CooldownBars     = 1;

// --- System B: Mean Reversion settings
input bool   InpEnableSystemB      = true;
input int    InpB_MagicOffset      = 20;
input int    InpB_EmaMean          = 200;
input int    InpB_RsiPeriod        = 14;
input double InpB_RSI_Oversold     = 30.0;
input double InpB_RSI_Overbought   = 70.0;
input int    InpB_DevFromMeanPts   = 1800;
input int    InpB_TrendMaxPtsHTF   = 450;      // avoid fading strong M15 trends
input int    InpB_CooldownBars     = 2;

// --- System C: Range Scalper settings (only when market ranging)
input bool   InpEnableSystemC      = true;
input int    InpC_MagicOffset      = 30;

// Range regime detection (M15)
input int    InpC_RangeMaxTrendPts = 280;      // if abs(EMA20-EMA50) <= this => ranging

// BBands on M5
input int    InpC_BB_Period        = 20;
input double InpC_BB_Dev           = 1.8;

// RSI confirm on M5
input int    InpC_RsiPeriod        = 14;
input double InpC_RSI_BuyMax       = 45.0;     // buy when oversold-ish in range
input double InpC_RSI_SellMin      = 55.0;     // sell when overbought-ish in range

input int    InpC_CooldownBars     = 1;

// --- Base magic
input int    InpBaseMagic          = 2026012406;

//============================== GLOBAL =============================
string   SYM;

int hATR = INVALID_HANDLE;

// System A handles
int hA_EmaFast = INVALID_HANDLE, hA_EmaSlow = INVALID_HANDLE, hA_RSI = INVALID_HANDLE;
int hA_EmaFastHTF = INVALID_HANDLE, hA_EmaSlowHTF = INVALID_HANDLE;

// System B handles
int hB_EmaMean = INVALID_HANDLE, hB_RSI = INVALID_HANDLE;
int hB_EmaFastHTF2 = INVALID_HANDLE, hB_EmaSlowHTF2 = INVALID_HANDLE; // strength filter

// System C handles
int hC_EmaFastHTF = INVALID_HANDLE, hC_EmaSlowHTF = INVALID_HANDLE;   // range regime check
int hC_Bands = INVALID_HANDLE;                                        // iBands on M5
int hC_RSI = INVALID_HANDLE;                                          // RSI on M5

datetime lastBarTime = 0;
int cooldownA = 0, cooldownB = 0, cooldownC = 0;

// DD guard tracking
int     lastWibKey = -1;
double  dayStartEquity = 0.0;
double  peakEquity = 0.0;
bool    pausedToday = false;
bool    stoppedOverall = false;

//============================== UTILS ==============================
double Clamp(double v, double lo, double hi){ if(v<lo) return lo; if(v>hi) return hi; return v; }

int SpreadPoints()
{
   double ask=SymbolInfoDouble(SYM,SYMBOL_ASK), bid=SymbolInfoDouble(SYM,SYMBOL_BID);
   if(ask<=0||bid<=0) return 999999;
   return (int)MathRound((ask-bid)/_Point);
}

bool IsNewBar()
{
   datetime t=iTime(SYM,InpTF_Entry,0);
   if(t!=lastBarTime){ lastBarTime=t; return true; }
   return false;
}

double NormalizeLot(double lot)
{
   double step=SymbolInfoDouble(SYM,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(SYM,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(SYM,SYMBOL_VOLUME_MAX);

   lot=Clamp(lot,vmin,vmax);
   if(step>0) lot=MathFloor(lot/step)*step;

   int prec=2;
   if(step<0.1)  prec=3;
   if(step<0.01) prec=4;
   return NormalizeDouble(lot,prec);
}

double CalcCompoundLot()
{
   if(!InpUseCompoundStep) return NormalizeLot(InpBaseLot);

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double steps=0;
   if(InpStepBalance>0) steps=MathFloor((bal-InpBaseBalance)/InpStepBalance);
   if(steps<0) steps=0;

   double lot=InpBaseLot + steps*InpLotStep;
   lot=Clamp(lot,InpMinLot,InpMaxLot);
   return NormalizeLot(lot);
}

int CountOurPositionsAll()
{
   int total=PositionsTotal(), count=0;
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==SYM)
      {
         int m=(int)PositionGetInteger(POSITION_MAGIC);
         if(m>=InpBaseMagic && m<InpBaseMagic+1000) count++;
      }
   }
   return count;
}

int CountOurPositionsByMagic(int magic)
{
   int total=PositionsTotal(), count=0;
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)==SYM && (int)PositionGetInteger(POSITION_MAGIC)==magic)
         count++;
   }
   return count;
}

//---------------------- WIB time filter ----------------------------
bool InTradingWindowWIB()
{
   if(!InpUseTimeFilterWIB) return true;

   datetime wib = TimeGMT() + 7*3600;
   MqlDateTime dt; TimeToStruct(wib, dt);

   if(InpTradeMonToFriOnly)
   {
      if(dt.day_of_week==0 || dt.day_of_week==6) return false;
   }

   int curMin   = dt.hour*60 + dt.min;
   int startMin = InpStartHourWIB*60 + InpStartMinuteWIB;
   int endMin   = InpEndHourWIB*60 + InpEndMinuteWIB;

   if(startMin < endMin) return (curMin >= startMin && curMin < endMin);
   return (curMin >= startMin || curMin < endMin);
}

int WibDayKey()
{
   datetime wib = TimeGMT() + 7*3600;
   MqlDateTime dt; TimeToStruct(wib, dt);
   return dt.year*1000 + dt.day_of_year; // unique enough
}

//---------------------- Stop safety --------------------------------
bool ApplyStopSafety(bool buy, double entryPrice, double &sl, double &tp)
{
   int stopsLevel =(int)SymbolInfoInteger(SYM, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel=(int)SymbolInfoInteger(SYM, SYMBOL_TRADE_FREEZE_LEVEL);

   int minPts = MathMax(stopsLevel, freezeLevel) + 8;
   if(minPts < 0) minPts = 0;

   double minDist = minPts * _Point;

   if(buy)
   {
      if(entryPrice - sl < minDist) sl = entryPrice - minDist;
      if(tp - entryPrice < minDist) tp = entryPrice + minDist;
   }
   else
   {
      if(sl - entryPrice < minDist) sl = entryPrice + minDist;
      if(entryPrice - tp < minDist) tp = entryPrice - minDist;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   return true;
}

bool GetATR(double &atrOut)
{
   double a[1];
   if(CopyBuffer(hATR,0,0,1,a)<1) return false;
   if(a[0]<=0) return false;
   atrOut = a[0];
   return true;
}

bool ComputeStops(bool buy, double slMult, double tpMult, int slPtsFixed, int tpPtsFixed, double &sl, double &tp)
{
   double ask=SymbolInfoDouble(SYM,SYMBOL_ASK), bid=SymbolInfoDouble(SYM,SYMBOL_BID);
   if(ask<=0||bid<=0) return false;

   double entry = buy ? ask : bid;

   double slPts = (double)slPtsFixed;
   double tpPts = (double)tpPtsFixed;

   if(InpUseATRStops)
   {
      double atr;
      if(!GetATR(atr)) return false;
      slPts = (atr*slMult)/_Point;
      tpPts = (atr*tpMult)/_Point;
   }

   if(slPts < 80) slPts = 80;
   if(tpPts < 80) tpPts = 80;

   if(buy){ sl = entry - slPts*_Point; tp = entry + tpPts*_Point; }
   else   { sl = entry + slPts*_Point; tp = entry - tpPts*_Point; }

   sl = NormalizeDouble(sl,_Digits);
   tp = NormalizeDouble(tp,_Digits);

   return ApplyStopSafety(buy, entry, sl, tp);
}

//====================== DD GUARDS ==================================
void UpdateDDGuards()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0) return;

   if(peakEquity<=0) peakEquity = eq;
   if(eq > peakEquity) peakEquity = eq;

   int key = WibDayKey();
   if(key != lastWibKey)
   {
      lastWibKey = key;
      dayStartEquity = eq;
      pausedToday = false;
   }

   if(InpUseOverallDDGuard && !stoppedOverall && peakEquity>0)
   {
      double dd = (peakEquity - eq)/peakEquity*100.0;
      if(dd >= InpOverallDDPercent)
      {
         stoppedOverall = true;
         Print("OVERALL DD GUARD TRIGGERED dd=", DoubleToString(dd,2), "% -> STOP trading");
      }
   }

   if(InpUseDailyDDGuard && !pausedToday && dayStartEquity>0)
   {
      double ddDay = (dayStartEquity - eq)/dayStartEquity*100.0;
      if(ddDay >= InpDailyDDPercent)
      {
         pausedToday = true;
         Print("DAILY DD GUARD TRIGGERED ddDay=", DoubleToString(ddDay,2), "% -> PAUSE today");
      }
   }
}

void CloseAllOurPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)!=SYM) continue;

      int m=(int)PositionGetInteger(POSITION_MAGIC);
      if(m<InpBaseMagic || m>=InpBaseMagic+1000) continue;

      trade.PositionClose(ticket);
   }
}

//====================== PARTIAL / BE / TRAIL =======================
string TP1FlagName(ulong ticket, int magic)
{
   return "TP1_DONE_" + SYM + "_" + IntegerToString(magic) + "_" + (string)ticket;
}

double NormalizeVolume(double vol)
{
   double step = SymbolInfoDouble(SYM, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(SYM, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(SYM, SYMBOL_VOLUME_MAX);

   vol = Clamp(vol, vmin, vmax);
   if(step > 0) vol = MathFloor(vol / step) * step;

   int prec=2;
   if(step < 0.1)  prec=3;
   if(step < 0.01) prec=4;
   return NormalizeDouble(vol, prec);
}

bool CanPartialClose(double curVol, double closeVol)
{
   double vmin = SymbolInfoDouble(SYM, SYMBOL_VOLUME_MIN);

   closeVol = NormalizeVolume(closeVol);
   double remaining = NormalizeVolume(curVol - closeVol);

   if(closeVol < vmin) return false;
   if(remaining < vmin) return false;
   return true;
}

int CalcTP1Points()
{
   if(!InpUsePartialTP1) return 0;

   if(InpTP1_UseATR)
   {
      double atr;
      if(!GetATR(atr)) return 0;
      return (int)MathRound((atr * InpTP1_ATR_Mult) / _Point);
   }
   return InpTP1_Points;
}

void ManagePositions()
{
   int tp1Pts = CalcTP1Points();

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)!=SYM) continue;

      int magic=(int)PositionGetInteger(POSITION_MAGIC);
      if(magic<InpBaseMagic || magic>=InpBaseMagic+1000) continue;

      bool buy = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double bid=SymbolInfoDouble(SYM,SYMBOL_BID), ask=SymbolInfoDouble(SYM,SYMBOL_ASK);
      if(bid<=0||ask<=0) continue;

      double cur = buy ? bid : ask;
      double profitPts = (buy ? (cur-open) : (open-cur))/_Point;

      // Partial TP1
      if(InpUsePartialTP1 && tp1Pts>0)
      {
         string flag = TP1FlagName(ticket, magic);
         bool tp1Done = GlobalVariableCheck(flag);

         if(!tp1Done && profitPts >= tp1Pts)
         {
            double curVol = PositionGetDouble(POSITION_VOLUME);
            double closeVol = NormalizeVolume(curVol * (InpTP1_ClosePercent/100.0));

            if(CanPartialClose(curVol, closeVol))
            {
               if(trade.PositionClosePartial(ticket, closeVol))
               {
                  GlobalVariableSet(flag, TimeCurrent());
                  if(InpTP1_MoveSLToBE)
                  {
                     double newSL = buy ? (open + InpTP1_BE_OffsetPoints*_Point)
                                        : (open - InpTP1_BE_OffsetPoints*_Point);
                     trade.PositionModify(SYM, NormalizeDouble(newSL,_Digits), tp);
                  }
               }
            }
            else
            {
               GlobalVariableSet(flag, TimeCurrent());
            }
         }
      }

      // Break-even
      if(InpUseBreakEven && profitPts >= InpBE_StartPoints)
      {
         double newSL = buy ? (open + InpBE_OffsetPoints*_Point) : (open - InpBE_OffsetPoints*_Point);
         bool improve = (sl==0) || (buy && newSL>sl) || (!buy && newSL<sl);

         if(improve) trade.PositionModify(SYM, NormalizeDouble(newSL,_Digits), tp);
      }

      // Trailing
      if(InpUseTrailing && profitPts >= InpTrailStartPoints)
      {
         double newSL = buy ? (cur - InpTrailDistance*_Point) : (cur + InpTrailDistance*_Point);
         bool improve = (sl==0) ||
                        (buy && newSL > sl + InpTrailStep*_Point) ||
                        (!buy && newSL < sl - InpTrailStep*_Point);

         if(improve) trade.PositionModify(SYM, NormalizeDouble(newSL,_Digits), tp);
      }
   }
}

//====================== SYSTEM A: HWR SIGNAL =======================
bool A_HTFTrendOK(bool buy)
{
   double f[1], s[1];
   if(CopyBuffer(hA_EmaFastHTF,0,1,1,f)<1) return false;
   if(CopyBuffer(hA_EmaSlowHTF,0,1,1,s)<1) return false;
   return buy ? (f[0]>s[0]) : (f[0]<s[0]);
}

bool A_NotRanging(double ef, double es)
{
   double distPts=MathAbs(ef-es)/_Point;
   return distPts >= InpA_MinTrendPts;
}

bool A_NoImpulse()
{
   double atr;
   if(!GetATR(atr)) return false;

   double hi=iHigh(SYM,InpTF_Entry,1), lo=iLow(SYM,InpTF_Entry,1);
   if(hi<=0||lo<=0) return false;

   return ((hi-lo) <= atr*InpA_ImpulseATRMult);
}

int Signal_SystemA()
{
   double ef[1], es[1], r[1];
   if(CopyBuffer(hA_EmaFast,0,1,1,ef)<1) return 0;
   if(CopyBuffer(hA_EmaSlow,0,1,1,es)<1) return 0;
   if(CopyBuffer(hA_RSI,0,1,1,r)<1) return 0;

   double close1=iClose(SYM,InpTF_Entry,1);
   if(close1<=0) return 0;

   bool up = (ef[0]>es[0]);
   bool dn = (ef[0]<es[0]);

   double distPts=MathAbs(close1-ef[0])/_Point;
   if(distPts > InpA_PullbackMaxPts) return 0;

   if(!A_NotRanging(ef[0],es[0])) return 0;
   if(!A_NoImpulse()) return 0;

   if(up && r[0]>=InpA_RSI_BuyMin && A_HTFTrendOK(true))   return 1;
   if(dn && r[0]<=InpA_RSI_SellMax && A_HTFTrendOK(false)) return -1;

   return 0;
}

//====================== SYSTEM B: MR SIGNAL ========================
bool B_TooStrongTrendHTF()
{
   double f[1], s[1];
   if(CopyBuffer(hB_EmaFastHTF2,0,1,1,f)<1) return true;
   if(CopyBuffer(hB_EmaSlowHTF2,0,1,1,s)<1) return true;

   double distPts = MathAbs(f[0]-s[0])/_Point;
   return distPts > InpB_TrendMaxPtsHTF;
}

int Signal_SystemB()
{
   double mean[1], r[1];
   if(CopyBuffer(hB_EmaMean,0,1,1,mean)<1) return 0;
   if(CopyBuffer(hB_RSI,0,1,1,r)<1) return 0;

   double close1=iClose(SYM,InpTF_Entry,1);
   if(close1<=0) return 0;

   double devPts = (close1 - mean[0])/_Point;

   if(B_TooStrongTrendHTF()) return 0;

   if(r[0] >= InpB_RSI_Overbought && devPts >= InpB_DevFromMeanPts) return -1;
   if(r[0] <= InpB_RSI_Oversold   && devPts <= -InpB_DevFromMeanPts) return 1;

   return 0;
}

//====================== SYSTEM C: RANGE SCALPER SIGNAL ==============
// Range regime: M15 EMA20-EMA50 distance small
bool C_IsRanging()
{
   double f[1], s[1];
   if(CopyBuffer(hC_EmaFastHTF,0,1,1,f)<1) return false;
   if(CopyBuffer(hC_EmaSlowHTF,0,1,1,s)<1) return false;

   double distPts = MathAbs(f[0]-s[0])/_Point;
   return (distPts <= InpC_RangeMaxTrendPts);
}

// Bands: iBands buffers: 0=upper,1=middle,2=lower
int Signal_SystemC()
{
   if(!C_IsRanging()) return 0;

   double upper[1], mid[1], lower[1], rsi[1];
   if(CopyBuffer(hC_Bands,0,1,1,upper)<1) return 0;
   if(CopyBuffer(hC_Bands,2,1,1,lower)<1) return 0;
   if(CopyBuffer(hC_RSI,  0,1,1,rsi)  <1) return 0;

   double close1=iClose(SYM,InpTF_Entry,1);
   if(close1<=0) return 0;

   // Buy near/below lower band + RSI low
   if(close1 <= lower[0] && rsi[0] <= InpC_RSI_BuyMax) return 1;

   // Sell near/above upper band + RSI high
   if(close1 >= upper[0] && rsi[0] >= InpC_RSI_SellMin) return -1;

   return 0;
}

//====================== TRADING ====================================
void TryOpenTrade(int signal, int magic, double slMult, double tpMult, int slFixed, int tpFixed, const string comment)
{
   if(signal==0) return;

   if(CountOurPositionsAll() >= InpMaxPositionsTotal) return;
   if(InpOnePosPerSystem && CountOurPositionsByMagic(magic) > 0) return;

   double sl,tp;
   if(!ComputeStops(signal==1, slMult, tpMult, slFixed, tpFixed, sl, tp)) return;

   double lot = CalcCompoundLot();

   trade.SetExpertMagicNumber(magic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   bool ok=false;
   if(signal==1) ok = trade.Buy(lot, SYM, 0.0, sl, tp, comment);
   else          ok = trade.Sell(lot, SYM, 0.0, sl, tp, comment);

   if(!ok)
      Print("Order failed magic=", magic, " ret=", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}

//====================== EVENTS =====================================
int OnInit()
{
   SYM = (InpSymbol=="" ? _Symbol : InpSymbol);

   // shared ATR (Entry TF)
   hATR = iATR(SYM, InpTF_Entry, InpATRPeriod);
   if(hATR==INVALID_HANDLE)
   {
      Print("Init failed: ATR handle invalid.");
      return INIT_FAILED;
   }

   // System A handles
   if(InpEnableSystemA)
   {
      hA_EmaFast    = iMA(SYM, InpTF_Entry, InpA_EmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hA_EmaSlow    = iMA(SYM, InpTF_Entry, InpA_EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      hA_RSI        = iRSI(SYM, InpTF_Entry, InpA_RsiPeriod, PRICE_CLOSE);
      hA_EmaFastHTF = iMA(SYM, InpTF_Filter, InpA_EmaFast, 0, MODE_EMA, PRICE_CLOSE);
      hA_EmaSlowHTF = iMA(SYM, InpTF_Filter, InpA_EmaSlow, 0, MODE_EMA, PRICE_CLOSE);

      if(hA_EmaFast==INVALID_HANDLE||hA_EmaSlow==INVALID_HANDLE||hA_RSI==INVALID_HANDLE||
         hA_EmaFastHTF==INVALID_HANDLE||hA_EmaSlowHTF==INVALID_HANDLE)
      {
         Print("Init failed: System A indicator handle invalid.");
         return INIT_FAILED;
      }
   }

   // System B handles
   if(InpEnableSystemB)
   {
      hB_EmaMean = iMA(SYM, InpTF_Entry, InpB_EmaMean, 0, MODE_EMA, PRICE_CLOSE);
      hB_RSI     = iRSI(SYM, InpTF_Entry, InpB_RsiPeriod, PRICE_CLOSE);

      hB_EmaFastHTF2 = iMA(SYM, InpTF_Filter, 20, 0, MODE_EMA, PRICE_CLOSE);
      hB_EmaSlowHTF2 = iMA(SYM, InpTF_Filter, 50, 0, MODE_EMA, PRICE_CLOSE);

      if(hB_EmaMean==INVALID_HANDLE||hB_RSI==INVALID_HANDLE||hB_EmaFastHTF2==INVALID_HANDLE||hB_EmaSlowHTF2==INVALID_HANDLE)
      {
         Print("Init failed: System B indicator handle invalid.");
         return INIT_FAILED;
      }
   }

   // System C handles
   if(InpEnableSystemC)
   {
      hC_EmaFastHTF = iMA(SYM, InpTF_Filter, 20, 0, MODE_EMA, PRICE_CLOSE);
      hC_EmaSlowHTF = iMA(SYM, InpTF_Filter, 50, 0, MODE_EMA, PRICE_CLOSE);

      hC_Bands = iBands(SYM, InpTF_Entry, InpC_BB_Period, 0, InpC_BB_Dev, PRICE_CLOSE);
      hC_RSI   = iRSI(SYM, InpTF_Entry, InpC_RsiPeriod, PRICE_CLOSE);

      if(hC_EmaFastHTF==INVALID_HANDLE||hC_EmaSlowHTF==INVALID_HANDLE||hC_Bands==INVALID_HANDLE||hC_RSI==INVALID_HANDLE)
      {
         Print("Init failed: System C indicator handle invalid.");
         return INIT_FAILED;
      }
   }

   // init state
   lastBarTime = iTime(SYM, InpTF_Entry, 0);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartEquity = peakEquity;
   lastWibKey = WibDayKey();

   Print("Multi-System (A=HWR, B=MR, C=RANGE) READY on ", SYM,
         " | Window WIB ", InpStartHourWIB,":",InpStartMinuteWIB," - ",InpEndHourWIB,":",InpEndMinuteWIB,
         " | MaxPos=", InpMaxPositionsTotal,
         " | SpreadMax=", InpMaxSpreadPoints);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);

   if(hA_EmaFast!=INVALID_HANDLE) IndicatorRelease(hA_EmaFast);
   if(hA_EmaSlow!=INVALID_HANDLE) IndicatorRelease(hA_EmaSlow);
   if(hA_RSI!=INVALID_HANDLE) IndicatorRelease(hA_RSI);
   if(hA_EmaFastHTF!=INVALID_HANDLE) IndicatorRelease(hA_EmaFastHTF);
   if(hA_EmaSlowHTF!=INVALID_HANDLE) IndicatorRelease(hA_EmaSlowHTF);

   if(hB_EmaMean!=INVALID_HANDLE) IndicatorRelease(hB_EmaMean);
   if(hB_RSI!=INVALID_HANDLE) IndicatorRelease(hB_RSI);
   if(hB_EmaFastHTF2!=INVALID_HANDLE) IndicatorRelease(hB_EmaFastHTF2);
   if(hB_EmaSlowHTF2!=INVALID_HANDLE) IndicatorRelease(hB_EmaSlowHTF2);

   if(hC_EmaFastHTF!=INVALID_HANDLE) IndicatorRelease(hC_EmaFastHTF);
   if(hC_EmaSlowHTF!=INVALID_HANDLE) IndicatorRelease(hC_EmaSlowHTF);
   if(hC_Bands!=INVALID_HANDLE) IndicatorRelease(hC_Bands);
   if(hC_RSI!=INVALID_HANDLE) IndicatorRelease(hC_RSI);
}

void OnTick()
{
   // manage open trades always
   ManagePositions();

   // update DD guards
   UpdateDDGuards();

   // if DD guard triggered -> close & stop
   if(stoppedOverall)
   {
      CloseAllOurPositions();
      return;
   }
   if(pausedToday)
   {
      CloseAllOurPositions();
      return;
   }

   // constraints
   if(!IsNewBar()) return;
   if(InpUseTimeFilterWIB && !InTradingWindowWIB()) return;
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   // cooldown decrement
   if(cooldownA>0) cooldownA--;
   if(cooldownB>0) cooldownB--;
   if(cooldownC>0) cooldownC--;

   // magic per system
   int magicA = InpBaseMagic + InpA_MagicOffset;
   int magicB = InpBaseMagic + InpB_MagicOffset;
   int magicC = InpBaseMagic + InpC_MagicOffset;

   // System A: HWR
   if(InpEnableSystemA && cooldownA<=0)
   {
      int sigA = Signal_SystemA();
      if(sigA!=0)
      {
         TryOpenTrade(sigA, magicA, InpA_ATR_SL_Mult, InpA_ATR_TP_Mult, InpA_SL_Points, InpA_TP_Points, "SYS-A HWR");
         cooldownA = InpA_CooldownBars;
      }
   }

   // System B: MR
   if(InpEnableSystemB && cooldownB<=0)
   {
      int sigB = Signal_SystemB();
      if(sigB!=0)
      {
         TryOpenTrade(sigB, magicB, InpB_ATR_SL_Mult, InpB_ATR_TP_Mult, InpB_SL_Points, InpB_TP_Points, "SYS-B MR");
         cooldownB = InpB_CooldownBars;
      }
   }

   // System C: RANGE scalper (only if ranging)
   if(InpEnableSystemC && cooldownC<=0)
   {
      int sigC = Signal_SystemC();
      if(sigC!=0)
      {
         TryOpenTrade(sigC, magicC, InpC_ATR_SL_Mult, InpC_ATR_TP_Mult, InpC_SL_Points, InpC_TP_Points, "SYS-C RANGE");
         cooldownC = InpC_CooldownBars;
      }
   }
}
//+------------------------------------------------------------------+

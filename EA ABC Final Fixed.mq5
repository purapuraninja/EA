//+------------------------------------------------------------------+
//| EA_ABC_Final_Fixed_NoWarning.mq5                                  |
//| XAUUSDm Multi-System (Scalping + Session)                         |
//|  A) HWR Trend Pullback   : M5 entry + M15 trend confirm            |
//|  B) Mean Reversion (MR)  : EMA200 deviation + RSI extreme          |
//|  C) Range Scalper        : BBands touch (wick+buffer) + RSI        |
//| Guards: London-NY WIB, Spread filter, Max 2 positions, DD guards   |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//============================== INPUT ==============================
input string          InpSymbol              = "";          // empty = chart symbol
input ENUM_TIMEFRAMES InpTF_Entry            = PERIOD_M5;   // entry TF
input ENUM_TIMEFRAMES InpTF_Filter           = PERIOD_M15;  // filter TF (HTF)

// --- Time filter (WIB = GMT+7)
input bool   InpUseTimeFilterWIB   = true;
input int    InpStartHourWIB       = 14;
input int    InpStartMinuteWIB     = 0;
input int    InpEndHourWIB         = 5;
input int    InpEndMinuteWIB       = 0;
input bool   InpTradeMonToFriOnly  = true;

// --- Execution / constraints
input int    InpMaxSpreadPoints    = 260;    // your avg spread ~160
input int    InpDeviationPoints    = 80;
input int    InpMaxPositionsTotal  = 2;      // portfolio cap
input bool   InpOnePosPerSystem    = true;   // max 1 per system

// --- Money Management (step compounding)
input bool   InpUseCompoundStep    = true;
input double InpBaseBalance        = 100.0;
input double InpBaseLot            = 0.01;
input double InpStepBalance        = 50.0;
input double InpLotStep            = 0.01;
input double InpMinLot             = 0.01;
input double InpMaxLot             = 0.30;

// --- Drawdown guards
input bool   InpUseDailyDDGuard    = true;
input double InpDailyDDPercent     = 4.0;    // pause & close positions for the day
input bool   InpUseOverallDDGuard  = true;
input double InpOverallDDPercent   = 12.0;   // stop & close positions permanently

// --- ATR (shared)
input bool   InpUseATRStops        = true;
input int    InpATRPeriod          = 14;

// --- System A SL/TP
input double InpA_ATR_SL_Mult      = 1.25;
input double InpA_ATR_TP_Mult      = 1.30;
input int    InpA_SL_Points        = 1300;
input int    InpA_TP_Points        = 1600;

// --- System B SL/TP
input double InpB_ATR_SL_Mult      = 1.55;
input double InpB_ATR_TP_Mult      = 0.95;
input int    InpB_SL_Points        = 1600;
input int    InpB_TP_Points        = 900;

// --- System C SL/TP (scalper)
input double InpC_ATR_SL_Mult      = 1.10;
input double InpC_ATR_TP_Mult      = 0.65;
input int    InpC_SL_Points        = 900;
input int    InpC_TP_Points        = 550;

// --- Partial TP1 + BE + Trailing
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

// --- System B: MR settings
input bool   InpEnableSystemB      = true;
input int    InpB_MagicOffset      = 20;
input int    InpB_EmaMean          = 200;
input int    InpB_RsiPeriod        = 14;
input double InpB_RSI_Oversold     = 30.0;
input double InpB_RSI_Overbought   = 70.0;
input int    InpB_DevFromMeanPts   = 1800;
input int    InpB_TrendMaxPtsHTF   = 450;    // avoid fading strong trend
input int    InpB_CooldownBars     = 2;

// --- System C: Range scalper settings
input bool   InpEnableSystemC      = true;
input int    InpC_MagicOffset      = 30;
input int    InpC_RangeMaxTrendPts = 450;    // EMA20-EMA50 (M15) <= this => ranging
input int    InpC_BB_Period        = 20;
input double InpC_BB_Dev           = 2.0;
input int    InpC_RsiPeriod        = 14;
input double InpC_RSI_BuyMax       = 45.0;
input double InpC_RSI_SellMin      = 55.0;
input int    InpC_BandTouchBufferPts = 120;  // wick touch tolerance
input int    InpC_CooldownBars     = 1;

// --- Base magic
input int    InpBaseMagic          = 2026012406;

//============================== GLOBAL =============================
string   SYM;
datetime lastBarTime = 0;

int hATR = INVALID_HANDLE;

// A handles
int hA_EmaFast=INVALID_HANDLE, hA_EmaSlow=INVALID_HANDLE, hA_RSI=INVALID_HANDLE;
int hA_EmaFastHTF=INVALID_HANDLE, hA_EmaSlowHTF=INVALID_HANDLE;

// B handles
int hB_EmaMean=INVALID_HANDLE, hB_RSI=INVALID_HANDLE;
int hB_EmaFastHTF2=INVALID_HANDLE, hB_EmaSlowHTF2=INVALID_HANDLE;

// C handles
int hC_EmaFastHTF=INVALID_HANDLE, hC_EmaSlowHTF=INVALID_HANDLE;
int hC_Bands=INVALID_HANDLE, hC_RSI=INVALID_HANDLE;

// cooldowns
int cooldownA=0, cooldownB=0, cooldownC=0;

// DD guard state
int    lastWibKey=-1;
double dayStartEquity=0.0;
double peakEquity=0.0;
bool   pausedToday=false;
bool   stoppedOverall=false;

//============================== HELPERS =============================
double Clamp(double v,double lo,double hi){ if(v<lo) return lo; if(v>hi) return hi; return v; }

int PriceToPoints(const double priceDiff)
{
   // ✅ explicit conversion => NO warning
   return (int)MathRound(priceDiff/_Point);
}

int SpreadPoints()
{
   double ask=SymbolInfoDouble(SYM,SYMBOL_ASK), bid=SymbolInfoDouble(SYM,SYMBOL_BID);
   if(ask<=0||bid<=0) return 999999;
   return PriceToPoints(ask-bid);
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

      if(PositionGetString(POSITION_SYMBOL)!=SYM) continue;

      int m=(int)PositionGetInteger(POSITION_MAGIC);
      if(m>=InpBaseMagic && m<InpBaseMagic+1000) count++;
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

      if(PositionGetString(POSITION_SYMBOL)==SYM &&
         (int)PositionGetInteger(POSITION_MAGIC)==magic)
         count++;
   }
   return count;
}

//---------------- WIB time window ----------------
bool InTradingWindowWIB()
{
   if(!InpUseTimeFilterWIB) return true;

   datetime wib = TimeGMT() + 7*3600;
   MqlDateTime dt; TimeToStruct(wib, dt);

   if(InpTradeMonToFriOnly)
   {
      if(dt.day_of_week==0 || dt.day_of_week==6) return false;
   }

   int cur = dt.hour*60 + dt.min;
   int st  = InpStartHourWIB*60 + InpStartMinuteWIB;
   int en  = InpEndHourWIB*60 + InpEndMinuteWIB;

   if(st<en) return (cur>=st && cur<en);
   return (cur>=st || cur<en);
}

int WibDayKey()
{
   datetime wib = TimeGMT() + 7*3600;
   MqlDateTime dt; TimeToStruct(wib, dt);
   return dt.year*1000 + dt.day_of_year;
}

bool GetATR(double &atrOut)
{
   double a[1];
   if(CopyBuffer(hATR,0,0,1,a)<1) return false;
   if(a[0]<=0) return false;
   atrOut=a[0];
   return true;
}

bool ApplyStopSafety(bool buy,double entry,double &sl,double &tp)
{
   int stops =(int)SymbolInfoInteger(SYM,SYMBOL_TRADE_STOPS_LEVEL);
   int freeze=(int)SymbolInfoInteger(SYM,SYMBOL_TRADE_FREEZE_LEVEL);

   int minPts = MathMax(stops,freeze) + 8;
   if(minPts<0) minPts=0;
   double minDist = (double)minPts * _Point;

   if(buy)
   {
      if(entry-sl<minDist) sl=entry-minDist;
      if(tp-entry<minDist) tp=entry+minDist;
   }
   else
   {
      if(sl-entry<minDist) sl=entry+minDist;
      if(entry-tp<minDist) tp=entry-minDist;
   }

   sl=NormalizeDouble(sl,_Digits);
   tp=NormalizeDouble(tp,_Digits);
   return true;
}

bool ComputeStops(bool buy,double slMult,double tpMult,int slFixed,int tpFixed,double &sl,double &tp)
{
   double ask=SymbolInfoDouble(SYM,SYMBOL_ASK), bid=SymbolInfoDouble(SYM,SYMBOL_BID);
   if(ask<=0||bid<=0) return false;

   double entry = buy ? ask : bid;

   double slPts = (double)slFixed;
   double tpPts = (double)tpFixed;

   if(InpUseATRStops)
   {
      double atr; if(!GetATR(atr)) return false;
      slPts = (atr*slMult)/_Point;
      tpPts = (atr*tpMult)/_Point;
   }

   if(slPts<80) slPts=80;
   if(tpPts<80) tpPts=80;

   if(buy){ sl=entry-slPts*_Point; tp=entry+tpPts*_Point; }
   else   { sl=entry+slPts*_Point; tp=entry-tpPts*_Point; }

   sl=NormalizeDouble(sl,_Digits);
   tp=NormalizeDouble(tp,_Digits);
   return ApplyStopSafety(buy,entry,sl,tp);
}

//====================== DD GUARDS ==================================
void UpdateDDGuards()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<=0) return;

   if(peakEquity<=0) peakEquity=eq;
   if(eq>peakEquity) peakEquity=eq;

   int key=WibDayKey();
   if(key!=lastWibKey)
   {
      lastWibKey=key;
      dayStartEquity=eq;
      pausedToday=false;
   }

   if(InpUseOverallDDGuard && !stoppedOverall && peakEquity>0)
   {
      double dd = (peakEquity-eq)/peakEquity*100.0;
      if(dd>=InpOverallDDPercent)
      {
         stoppedOverall=true;
         Print("OVERALL DD GUARD TRIGGERED dd=",DoubleToString(dd,2),"%");
      }
   }

   if(InpUseDailyDDGuard && !pausedToday && dayStartEquity>0)
   {
      double ddDay = (dayStartEquity-eq)/dayStartEquity*100.0;
      if(ddDay>=InpDailyDDPercent)
      {
         pausedToday=true;
         Print("DAILY DD GUARD TRIGGERED ddDay=",DoubleToString(ddDay,2),"%");
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

//====================== SYSTEM A: HWR ===============================
bool A_HTFTrendOK(bool buy)
{
   double f[1], s[1];
   if(CopyBuffer(hA_EmaFastHTF,0,1,1,f)<1) return false;
   if(CopyBuffer(hA_EmaSlowHTF,0,1,1,s)<1) return false;
   return buy ? (f[0]>s[0]) : (f[0]<s[0]);
}

bool A_NotRanging(double ef,double es)
{
   return PriceToPoints(MathAbs(ef-es)) >= InpA_MinTrendPts;
}

bool A_NoImpulse()
{
   double atr; if(!GetATR(atr)) return false;
   double hi=iHigh(SYM,InpTF_Entry,1), lo=iLow(SYM,InpTF_Entry,1);
   if(hi<=0||lo<=0) return false;
   return ((hi-lo) <= atr*InpA_ImpulseATRMult);
}

int SignalA()
{
   double ef[1], es[1], r[1];
   if(CopyBuffer(hA_EmaFast,0,1,1,ef)<1) return 0;
   if(CopyBuffer(hA_EmaSlow,0,1,1,es)<1) return 0;
   if(CopyBuffer(hA_RSI,0,1,1,r)<1) return 0;

   double c=iClose(SYM,InpTF_Entry,1);
   if(c<=0) return 0;

   bool up=(ef[0]>es[0]);
   bool dn=(ef[0]<es[0]);

   int pullPts = PriceToPoints(MathAbs(c-ef[0]));
   if(pullPts > InpA_PullbackMaxPts) return 0;

   if(!A_NotRanging(ef[0],es[0])) return 0;
   if(!A_NoImpulse()) return 0;

   if(up && r[0]>=InpA_RSI_BuyMin && A_HTFTrendOK(true))  return 1;
   if(dn && r[0]<=InpA_RSI_SellMax && A_HTFTrendOK(false))return -1;

   return 0;
}

//====================== SYSTEM B: MR ===============================
bool B_TooStrongTrendHTF()
{
   double f[1], s[1];
   if(CopyBuffer(hB_EmaFastHTF2,0,1,1,f)<1) return true;
   if(CopyBuffer(hB_EmaSlowHTF2,0,1,1,s)<1) return true;

   // ✅ FIX WARNING: convert to points as int explicitly
   int trendPts = PriceToPoints(MathAbs(f[0]-s[0]));
   return (trendPts > InpB_TrendMaxPtsHTF);
}

int SignalB()
{
   double mean[1], r[1];
   if(CopyBuffer(hB_EmaMean,0,1,1,mean)<1) return 0;
   if(CopyBuffer(hB_RSI,0,1,1,r)<1) return 0;

   double c=iClose(SYM,InpTF_Entry,1);
   if(c<=0) return 0;

   if(B_TooStrongTrendHTF()) return 0;

   int devPts = PriceToPoints(c - mean[0]); // signed
   if(r[0]>=InpB_RSI_Overbought && devPts>= InpB_DevFromMeanPts) return -1;
   if(r[0]<=InpB_RSI_Oversold   && devPts<=-InpB_DevFromMeanPts) return 1;

   return 0;
}

//====================== SYSTEM C: RANGE SCALPER =====================
bool C_IsRanging()
{
   double f[1], s[1];
   if(CopyBuffer(hC_EmaFastHTF,0,1,1,f)<1) return false;
   if(CopyBuffer(hC_EmaSlowHTF,0,1,1,s)<1) return false;

   int distPts = PriceToPoints(MathAbs(f[0]-s[0]));
   return (distPts <= InpC_RangeMaxTrendPts);
}

int SignalC()
{
   if(!C_IsRanging()) return 0;

   // iBands buffers: 0=upper,1=middle,2=lower
   double upper[1], lower[1], rsi[1];
   if(CopyBuffer(hC_Bands,0,1,1,upper)<1) return 0;
   if(CopyBuffer(hC_Bands,2,1,1,lower)<1) return 0;
   if(CopyBuffer(hC_RSI,  0,1,1,rsi)  <1) return 0;

   double low1=iLow(SYM,InpTF_Entry,1);
   double high1=iHigh(SYM,InpTF_Entry,1);
   if(low1<=0||high1<=0) return 0;

   double buf = (double)InpC_BandTouchBufferPts * _Point;

   if(low1  <= (lower[0] + buf) && rsi[0] <= InpC_RSI_BuyMax)  return 1;
   if(high1 >= (upper[0] - buf) && rsi[0] >= InpC_RSI_SellMin) return -1;

   return 0;
}

//====================== OPEN TRADE ================================
void TryOpen(int sig,int magic,double slMult,double tpMult,int slFix,int tpFix,const string cmt)
{
   if(sig==0) return;

   if(CountOurPositionsAll() >= InpMaxPositionsTotal) return;
   if(InpOnePosPerSystem && CountOurPositionsByMagic(magic)>0) return;

   double sl,tp;
   if(!ComputeStops(sig==1, slMult,tpMult, slFix,tpFix, sl,tp)) return;

   double lot = CalcCompoundLot();

   trade.SetExpertMagicNumber(magic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   bool ok=false;
   if(sig==1) ok=trade.Buy(lot,SYM,0.0,sl,tp,cmt);
   else       ok=trade.Sell(lot,SYM,0.0,sl,tp,cmt);

   if(!ok)
      Print("Order failed magic=",magic," ret=",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
}

//============================== INIT ===============================
int OnInit()
{
   SYM = (InpSymbol=="" ? _Symbol : InpSymbol);

   hATR=iATR(SYM,InpTF_Entry,InpATRPeriod);
   if(hATR==INVALID_HANDLE){ Print("ATR handle invalid"); return INIT_FAILED; }

   if(InpEnableSystemA)
   {
      hA_EmaFast=iMA(SYM,InpTF_Entry,InpA_EmaFast,0,MODE_EMA,PRICE_CLOSE);
      hA_EmaSlow=iMA(SYM,InpTF_Entry,InpA_EmaSlow,0,MODE_EMA,PRICE_CLOSE);
      hA_RSI=iRSI(SYM,InpTF_Entry,InpA_RsiPeriod,PRICE_CLOSE);
      hA_EmaFastHTF=iMA(SYM,InpTF_Filter,InpA_EmaFast,0,MODE_EMA,PRICE_CLOSE);
      hA_EmaSlowHTF=iMA(SYM,InpTF_Filter,InpA_EmaSlow,0,MODE_EMA,PRICE_CLOSE);

      if(hA_EmaFast==INVALID_HANDLE||hA_EmaSlow==INVALID_HANDLE||hA_RSI==INVALID_HANDLE||
         hA_EmaFastHTF==INVALID_HANDLE||hA_EmaSlowHTF==INVALID_HANDLE)
      { Print("Init fail: System A handle invalid"); return INIT_FAILED; }
   }

   if(InpEnableSystemB)
   {
      hB_EmaMean=iMA(SYM,InpTF_Entry,InpB_EmaMean,0,MODE_EMA,PRICE_CLOSE);
      hB_RSI=iRSI(SYM,InpTF_Entry,InpB_RsiPeriod,PRICE_CLOSE);
      hB_EmaFastHTF2=iMA(SYM,InpTF_Filter,20,0,MODE_EMA,PRICE_CLOSE);
      hB_EmaSlowHTF2=iMA(SYM,InpTF_Filter,50,0,MODE_EMA,PRICE_CLOSE);

      if(hB_EmaMean==INVALID_HANDLE||hB_RSI==INVALID_HANDLE||
         hB_EmaFastHTF2==INVALID_HANDLE||hB_EmaSlowHTF2==INVALID_HANDLE)
      { Print("Init fail: System B handle invalid"); return INIT_FAILED; }
   }

   if(InpEnableSystemC)
   {
      hC_EmaFastHTF=iMA(SYM,InpTF_Filter,20,0,MODE_EMA,PRICE_CLOSE);
      hC_EmaSlowHTF=iMA(SYM,InpTF_Filter,50,0,MODE_EMA,PRICE_CLOSE);

      // Correct order: period, deviation, bands_shift
      hC_Bands=iBands(SYM,InpTF_Entry,InpC_BB_Period,InpC_BB_Dev,0,PRICE_CLOSE);
      hC_RSI=iRSI(SYM,InpTF_Entry,InpC_RsiPeriod,PRICE_CLOSE);

      if(hC_EmaFastHTF==INVALID_HANDLE||hC_EmaSlowHTF==INVALID_HANDLE||
         hC_Bands==INVALID_HANDLE||hC_RSI==INVALID_HANDLE)
      { Print("Init fail: System C handle invalid"); return INIT_FAILED; }
   }

   lastBarTime=iTime(SYM,InpTF_Entry,0);
   peakEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   dayStartEquity=peakEquity;
   lastWibKey=WibDayKey();

   Print("EA ABC FINAL FIXED READY on ",SYM,
         " | TF=",EnumToString(InpTF_Entry)," HTF=",EnumToString(InpTF_Filter),
         " | Window WIB ",InpStartHourWIB,":",InpStartMinuteWIB," - ",InpEndHourWIB,":",InpEndMinuteWIB,
         " | SpreadMax=",InpMaxSpreadPoints," | MaxPos=",InpMaxPositionsTotal);

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

//============================== TICK ===============================
void OnTick()
{
   UpdateDDGuards();
   if(stoppedOverall || pausedToday){ CloseAllOurPositions(); return; }

   if(!IsNewBar()) return;
   if(InpUseTimeFilterWIB && !InTradingWindowWIB()) return;
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   if(cooldownA>0) cooldownA--;
   if(cooldownB>0) cooldownB--;
   if(cooldownC>0) cooldownC--;

   int magicA=InpBaseMagic+InpA_MagicOffset;
   int magicB=InpBaseMagic+InpB_MagicOffset;
   int magicC=InpBaseMagic+InpC_MagicOffset;

   if(InpEnableSystemA && cooldownA<=0)
   {
      int s=SignalA();
      if(s!=0){ TryOpen(s,magicA,InpA_ATR_SL_Mult,InpA_ATR_TP_Mult,InpA_SL_Points,InpA_TP_Points,"SYS-A HWR"); cooldownA=InpA_CooldownBars; }
   }

   if(InpEnableSystemB && cooldownB<=0)
   {
      int s=SignalB();
      if(s!=0){ TryOpen(s,magicB,InpB_ATR_SL_Mult,InpB_ATR_TP_Mult,InpB_SL_Points,InpB_TP_Points,"SYS-B MR"); cooldownB=InpB_CooldownBars; }
   }

   if(InpEnableSystemC && cooldownC<=0)
   {
      int s=SignalC();
      if(s!=0){ TryOpen(s,magicC,InpC_ATR_SL_Mult,InpC_ATR_TP_Mult,InpC_SL_Points,InpC_TP_Points,"SYS-C RANGE"); cooldownC=InpC_CooldownBars; }
   }
}
//+------------------------------------------------------------------+

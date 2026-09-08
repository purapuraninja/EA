//+------------------------------------------------------------------+
//|         XAUUSD_Scalp_HighWinrate_MT5.mq5                          |
//|  HIGHER WINRATE: HTF confirm + Range + Impulse + StopSafety       |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUT ======================================
input int             InpMagic              = 20260124;
input ENUM_TIMEFRAMES InpTF                 = PERIOD_M5;
input ENUM_TIMEFRAMES InpHTF                = PERIOD_M15;

// --- Strategy (stricter)
input int    InpEmaFast            = 20;
input int    InpEmaSlow            = 50;
input int    InpRSIPeriod          = 14;
input double InpRSI_BuyMin         = 55.0;   // stricter => higher quality
input double InpRSI_SellMax        = 45.0;

input int    InpPullbackMaxPoints  = 250;    // tighter pullback
input int    InpCooldownBars       = 4;

// --- Filter 2: Range (stricter)
input int    InpMinTrendPoints     = 300;

// --- Filter 3: Impulse (stricter)
input double InpImpulseATRMult     = 1.3;

// --- SL/TP
input bool   InpUseATRStops        = true;
input int    InpATRPeriod          = 14;
input double InpATR_SL_Mult        = 1.3;
input double InpATR_TP_Mult        = 1.2;

input int    InpSL_Points          = 1300;
input int    InpTP_Points          = 1600;

// --- Compounding step
input bool   InpUseCompoundStep    = true;
input double InpBaseBalance        = 100.0;
input double InpBaseLot            = 0.01;
input double InpStepBalance        = 50.0;
input double InpLotStep            = 0.01;
input double InpMinLot             = 0.01;
input double InpMaxLot             = 0.30;

// --- Protection / execution
input int    InpMaxSpreadPoints    = 250;   // stricter spread for winrate
input int    InpDeviationPoints    = 80;
input bool   InpOnePositionOnly    = true;

// --- Break-even
input bool   InpUseBreakEven       = true;
input int    InpBE_StartPoints     = 1000;
input int    InpBE_OffsetPoints    = 100;

// --- Trailing
input bool   InpUseTrailing        = true;
input int    InpTrailStartPoints   = 1500;
input int    InpTrailDistance      = 900;
input int    InpTrailStep          = 100;

//====================== GLOBAL =====================================
int      hFast = INVALID_HANDLE, hSlow = INVALID_HANDLE, hRSI = INVALID_HANDLE, hATR = INVALID_HANDLE;
int      hFastHTF = INVALID_HANDLE, hSlowHTF = INVALID_HANDLE;

datetime lastBarTime = 0;
int      cooldownLeft = 0;

//====================== UTIL =======================================
double Clamp(double v, double lo, double hi){ if(v<lo) return lo; if(v>hi) return hi; return v; }

int SpreadPoints()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0||bid<=0) return 999999;
   return (int)MathRound((ask-bid)/_Point);
}

bool IsNewBar()
{
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=lastBarTime){ lastBarTime=t; return true; }
   return false;
}

double NormalizeLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   lot=Clamp(lot,vmin,vmax);
   if(step>0) lot=MathFloor(lot/step)*step;

   int prec=2;
   if(step<0.1) prec=3;
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

int CountMyPositions()
{
   int total=PositionsTotal(), count=0;
   for(int i=0;i<total;i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic) count++;
   }
   return count;
}

//====================== FILTERS (1..3) =============================
bool HTFTrendOK(bool buy)
{
   double f[1], s[1];
   if(CopyBuffer(hFastHTF,0,1,1,f)<1) return false;
   if(CopyBuffer(hSlowHTF,0,1,1,s)<1) return false;
   return buy ? (f[0]>s[0]) : (f[0]<s[0]);
}

bool NotRanging(double emaFast, double emaSlow)
{
   double distPts=MathAbs(emaFast-emaSlow)/_Point;
   return (distPts >= InpMinTrendPoints);
}

bool NoImpulse()
{
   double atr[1];
   if(CopyBuffer(hATR,0,1,1,atr)<1) return false;
   double hi=iHigh(_Symbol,InpTF,1), lo=iLow(_Symbol,InpTF,1);
   if(hi<=0||lo<=0) return false;
   return ((hi-lo) <= atr[0]*InpImpulseATRMult);
}

//====================== (4) STOP SAFETY ============================
bool ApplyStopSafety(bool buy, double entryPrice, double &sl, double &tp)
{
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel= (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

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

   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   return true;
}

//====================== STOPS ======================================
bool ComputeStops(bool buy, double &sl, double &tp)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK), bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0||bid<=0) return false;

   double entry = buy ? ask : bid;

   double sl_points = (double)InpSL_Points;
   double tp_points = (double)InpTP_Points;

   if(InpUseATRStops)
   {
      double atr[1];
      if(CopyBuffer(hATR,0,0,1,atr)<1) return false;
      if(atr[0]<=0) return false;
      sl_points = (atr[0]*InpATR_SL_Mult)/_Point;
      tp_points = (atr[0]*InpATR_TP_Mult)/_Point;
   }

   if(sl_points < 50) sl_points = 50;
   if(tp_points < 50) tp_points = 50;

   if(buy){ sl = entry - sl_points*_Point; tp = entry + tp_points*_Point; }
   else   { sl = entry + sl_points*_Point; tp = entry - tp_points*_Point; }

   sl = NormalizeDouble(sl,_Digits);
   tp = NormalizeDouble(tp,_Digits);

   return ApplyStopSafety(buy, entry, sl, tp);
}

//====================== SIGNAL (HIGH WINRATE) =======================
int GetSignal()
{
   double f[1], s[1], r[1];
   if(CopyBuffer(hFast,0,1,1,f)<1) return 0;
   if(CopyBuffer(hSlow,0,1,1,s)<1) return 0;
   if(CopyBuffer(hRSI ,0,1,1,r)<1) return 0;

   double close1=iClose(_Symbol,InpTF,1);
   if(close1<=0) return 0;

   bool upTrend   = (f[0] > s[0]);
   bool downTrend = (f[0] < s[0]);

   double distPts = MathAbs(close1 - f[0])/_Point;
   bool pullbackOK = (distPts <= InpPullbackMaxPoints);

   if(!NotRanging(f[0], s[0])) return 0;  // (2)
   if(!NoImpulse())            return 0;  // (3)

   if(upTrend && pullbackOK && r[0] >= InpRSI_BuyMin && HTFTrendOK(true))    return 1;  // (1)
   if(downTrend && pullbackOK && r[0] <= InpRSI_SellMax && HTFTrendOK(false)) return -1;

   return 0;
}

//====================== MANAGE (BE + TRAIL) ========================
void ManagePositions()
{
   int total=PositionsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;

      bool buy = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double open=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl  =PositionGetDouble(POSITION_SL);
      double tp  =PositionGetDouble(POSITION_TP);

      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      if(bid<=0||ask<=0) continue;
      double cur = buy ? bid : ask;

      double profitPts = (buy ? (cur-open) : (open-cur))/_Point;

      if(InpUseBreakEven && profitPts >= InpBE_StartPoints)
      {
         double newSL = buy ? (open + InpBE_OffsetPoints*_Point) : (open - InpBE_OffsetPoints*_Point);
         bool improve = (sl==0) || (buy && newSL>sl) || (!buy && newSL<sl);
         if(improve)
         {
            newSL = NormalizeDouble(newSL,_Digits);
            trade.PositionModify(_Symbol,newSL,tp);
         }
      }

      if(InpUseTrailing && profitPts >= InpTrailStartPoints)
      {
         double newSL = buy ? (cur - InpTrailDistance*_Point) : (cur + InpTrailDistance*_Point);
         bool improve = (sl==0) ||
                        (buy && newSL > sl + InpTrailStep*_Point) ||
                        (!buy && newSL < sl - InpTrailStep*_Point);
         if(improve)
         {
            newSL = NormalizeDouble(newSL,_Digits);
            trade.PositionModify(_Symbol,newSL,tp);
         }
      }
   }
}

//====================== EVENTS =====================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   hFast = iMA(_Symbol,InpTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hSlow = iMA(_Symbol,InpTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);
   hRSI  = iRSI(_Symbol,InpTF,InpRSIPeriod,PRICE_CLOSE);
   hATR  = iATR(_Symbol,InpTF,InpATRPeriod);

   hFastHTF = iMA(_Symbol,InpHTF,InpEmaFast,0,MODE_EMA,PRICE_CLOSE);
   hSlowHTF = iMA(_Symbol,InpHTF,InpEmaSlow,0,MODE_EMA,PRICE_CLOSE);

   if(hFast==INVALID_HANDLE||hSlow==INVALID_HANDLE||hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE||
      hFastHTF==INVALID_HANDLE||hSlowHTF==INVALID_HANDLE)
      return INIT_FAILED;

   lastBarTime = iTime(_Symbol,InpTF,0);
   cooldownLeft = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast!=INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow!=INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI !=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR !=INVALID_HANDLE) IndicatorRelease(hATR);
   if(hFastHTF!=INVALID_HANDLE) IndicatorRelease(hFastHTF);
   if(hSlowHTF!=INVALID_HANDLE) IndicatorRelease(hSlowHTF);
}

void OnTick()
{
   ManagePositions();

   if(!IsNewBar()) return;

   if(cooldownLeft>0){ cooldownLeft--; return; }

   if(SpreadPoints() > InpMaxSpreadPoints) return;

   if(InpOnePositionOnly && CountMyPositions()>0) return;

   int sig = GetSignal();
   if(sig==0) return;

   double sl,tp;
   if(!ComputeStops(sig==1, sl, tp)) return;

   double lot = CalcCompoundLot();

   bool ok=false;
   if(sig==1) ok=trade.Buy(lot,_Symbol,0.0,sl,tp,"HW Buy");
   else       ok=trade.Sell(lot,_Symbol,0.0,sl,tp,"HW Sell");

   if(ok) cooldownLeft = InpCooldownBars;
}
//+------------------------------------------------------------------+

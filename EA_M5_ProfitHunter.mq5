//+------------------------------------------------------------------+
//| EA_M5_ProfitHunter.mq5                                           |
//| Strategy D (MACD + Trend MA + ATR) with Profit-Hunter Exits      |
//| Step 1-5 Patch: RR>1, TP1+TP2, BE after TP1, Trail after 1.5R,   |
//| Volatility+Trend filters, DD guards, Session London-NY option    |
//| Designed for XAUUSDm (2 digits, point=0.01) - Exness compatible  |
//+------------------------------------------------------------------+
#property strict
#property version "6.00"

#include <Trade/Trade.mqh>
CTrade trade;

//============================= INPUTS ==============================//
enum ENUM_SL_MODE    { SL_FIXED_POINTS=0, SL_ATR_MULT=1 };
enum ENUM_TP_MODE    { TP_FIXED_POINTS=0, TP_RR_MULT=1, TP_ATR_MULT=2 };
enum ENUM_TRAIL_MODE { TRAIL_OFF=0, TRAIL_POINTS=1, TRAIL_ATR_MULT=2 };

input string          InpEAName            = "EA_M5_ProfitHunter";
input ENUM_TIMEFRAMES InpTF                = PERIOD_M5;
input ulong           InpMagic             = 25012026;

input bool            InpOnePositionOnly   = true;
input bool            InpEntryOnNewBar     = false;
input bool            InpManageEveryTick   = true;
input int             InpDeviationPoints   = 60;

//--- Lot (risk-based). Compounding comes naturally when balance grows.
input bool            InpUseFixedLot       = false;
input double          InpFixedLot          = 0.10;
input double          InpRiskPercent       = 0.8;   // Step 5: 0.5–1.0%

//--- Spread
input int             InpMaxSpreadPoints   = 260;

//--- Session London-NY 14-05 GMT+7 (TimeGMT + offset)
input bool            InpUseSessionFilter  = false;
input int             InpSessionGMTOffset  = 7;
input int             InpStartHour         = 14;
input int             InpEndHour           = 5;

//--- SL/TP (Step 1)
input ENUM_SL_MODE    InpSLMode            = SL_ATR_MULT;
input int             InpATRPeriod         = 14;
input double          InpSL_ATR_Mult       = 1.3;
input int             InpSLPoints          = 260;

input ENUM_TP_MODE    InpTPMode            = TP_RR_MULT;
input double          InpTP_RR             = 3.0;     // TP2 target
input int             InpTPPoints          = 600;
input double          InpTP_ATR_Mult       = 2.8;

//--- TP1 Partial Close (Step 2)
input bool            InpEnableTP1         = true;
input double          InpTP1_RR            = 1.0;     // TP1 at 1R
input int             InpTP1Points         = 300;     // used if TP1_RR<=0
input double          InpTP1_ClosePercent  = 35.0;    // 30–40%

//--- Breakeven after TP1 (Step 3)
input bool            InpEnableBE          = true;
input bool            InpBE_OnlyAfterTP1   = true;
input double          InpBE_Trigger_RR     = 1.15;    // activate after ~TP1
input int             InpBE_TriggerPoints  = 350;
input int             InpBE_OffsetPoints   = 10;

//--- Trailing after TP1 (Step 3)
input ENUM_TRAIL_MODE InpTrailMode         = TRAIL_ATR_MULT;
input bool            InpTrailOnlyAfterTP1 = true;
input double          InpTrailStart_RR     = 1.8;     // start trailing after 1.5–2R
input int             InpTrailStartPoints  = 500;
input double          InpTrail_ATR_Mult    = 1.15;
input int             InpTrailPoints       = 260;

//--- Filters (Step 4)
input bool            InpUseATRFilter      = true;
input int             InpMinATRPoints      = 70;
input int             InpMaxATRPoints      = 320;

input bool            InpUseTrendStrength  = false;
input int             InpTrendMAPeriod     = 200;
input ENUM_MA_METHOD  InpTrendMAMethod     = MODE_EMA;
input double          InpTrendDistATRMult  = 0.5;     // |Close-MA| >= ATR*mult

//--- Strategy D params
input int             InpMACD_Fast         = 12;
input int             InpMACD_Slow         = 26;
input int             InpMACD_Signal       = 9;

//--- Behavior
input bool            InpCloseOnOppSignal  = true;

//--- DD Guards (Step 5)
input bool            InpDisableTradingOnDD= true;
input bool            InpDD_ClosePositions = true;
input double          InpMaxDailyDDPercent = 4.0;
input double          InpMaxEquityDDPercent= 12.0;

//============================= GLOBALS =============================//
int hATR      = INVALID_HANDLE;
int hMACD     = INVALID_HANDLE;
int hMAtrend  = INVALID_HANDLE;

datetime g_lastBarTime = 0;

// per-position state
ulong   g_posIdentifier = 0;
bool    g_tp1Done       = false;
bool    g_beDone        = false;
double  g_tp1Price      = 0.0;
double  g_slDistPoints  = 0.0;   // R in points for this position

// DD tracking
int     g_dayOfYear      = -1;
double  g_dayStartEquity = 0.0;
double  g_peakEquity     = 0.0;
bool    g_ddTriggered    = false;

//=========================== UTILS ===========================//
double Pnt() { return SymbolInfoDouble(_Symbol, SYMBOL_POINT); }
int Dig()     { return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS); }

bool SpreadAllowed()
{
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

datetime SessionTimeNow()
{
   return (datetime)(TimeGMT() + (InpSessionGMTOffset * 3600));
}

bool SessionAllowed()
{
   if(!InpUseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(SessionTimeNow(), dt);
   int h = dt.hour;

   if(InpStartHour < InpEndHour)
      return (h >= InpStartHour && h < InpEndHour);

   // wrap midnight (14 -> 5)
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

bool GetBufferLast2(const int handle, const int bufferIndex, double &v0, double &v1)
{
   if(handle == INVALID_HANDLE) return false;
   double arr[];
   ArrayResize(arr, 2);
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, bufferIndex, 0, 2, arr) != 2) return false;
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

//===================== POSITION HELPERS (no SelectByIndex) =========//
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

//===================== Stop Safety =================//
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

      g_peakEquity = g_dayStartEquity;
      g_ddTriggered = false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0.0) return;

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
   return NormalizeVolume(lot);
}

double CalcSLDistancePoints()
{
   double p = Pnt();
   double slPts = (InpSLMode == SL_ATR_MULT ? 0.0 : (double)InpSLPoints);

   if(InpSLMode == SL_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr)) slPts = (atr / p) * InpSL_ATR_Mult;
      else slPts = (double)InpSLPoints;
   }
   if(slPts < 80.0) slPts = 80.0;
   return slPts;
}

void CalcSLTP(bool isBuy, double &slPrice, double &tp2Price, double &slDistPts)
{
   double p = Pnt();
   int digits = Dig();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = isBuy ? ask : bid;

   slDistPts = CalcSLDistancePoints();
   double slDist = slDistPts * p;

   slPrice = isBuy ? (entry - slDist) : (entry + slDist);

   // TP2
   if(InpTPMode == TP_FIXED_POINTS)
   {
      double tpDist = (double)InpTPPoints * p;
      if(tpDist < 120.0*p) tpDist = 120.0*p;
      tp2Price = isBuy ? (entry + tpDist) : (entry - tpDist);
   }
   else if(InpTPMode == TP_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr))
      {
         double tpDist = atr * InpTP_ATR_Mult;
         tp2Price = isBuy ? (entry + tpDist) : (entry - tpDist);
      }
      else
      {
         double rr = (InpTP_RR > 0.0 ? InpTP_RR : 2.0);
         tp2Price = isBuy ? (entry + slDist * rr) : (entry - slDist * rr);
      }
   }
   else // RR
   {
      double rr = (InpTP_RR > 0.0 ? InpTP_RR : 2.0);
      tp2Price = isBuy ? (entry + slDist * rr) : (entry - slDist * rr);
   }

   slPrice  = NormalizeDouble(slPrice, digits);
   tp2Price = NormalizeDouble(tp2Price, digits);
}

//============================= FILTERS =============================//
bool FiltersOK()
{
   double atr=0.0;
   if(!GetATR(atr)) return false;

   double atrPts = atr / Pnt();

   if(InpUseATRFilter)
   {
      if(atrPts < (double)InpMinATRPoints) return false;
      if(atrPts > (double)InpMaxATRPoints) return false;
   }

   if(InpUseTrendStrength)
   {
      double ma0, ma1;
      if(!GetBufferLast2(hMAtrend, 0, ma0, ma1)) return false;

      double c0 = iClose(_Symbol, InpTF, 0);
      double dist = MathAbs(c0 - ma0);
      if(dist < atr * InpTrendDistATRMult) return false;
   }

   return true;
}

//============================= STRATEGY D ==========================//
bool SignalD(bool &buy, bool &sell)
{
   buy=false; sell=false;

   double macd0,macd1,sig0,sig1;
   if(!GetBufferLast2(hMACD,0,macd0,macd1)) return false;
   if(!GetBufferLast2(hMACD,1,sig0,sig1))   return false;

   double ma0, ma1;
   if(!GetBufferLast2(hMAtrend,0,ma0,ma1)) return false;

   double c0 = iClose(_Symbol, InpTF, 0);

   bool crossUp   = (macd1 <= sig1 && macd0 > sig0);
   bool crossDown = (macd1 >= sig1 && macd0 < sig0);

   if(crossUp   && c0 > ma0) buy=true;
   if(crossDown && c0 < ma0) sell=true;

   return true;
}

//==================== STATE / TP1 / BE / TRAIL ====================//
void ResetState()
{
   g_posIdentifier = 0;
   g_tp1Done = false;
   g_beDone  = false;
   g_tp1Price = 0.0;
   g_slDistPoints = 0.0;
}

void RefreshPositionState()
{
   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol))
   {
      ResetState();
      return;
   }

   if(g_posIdentifier != id)
   {
      g_posIdentifier = id;
      g_tp1Done = false;
      g_beDone  = false;

      double p = Pnt();
      int digits = Dig();

      if(sl > 0.0)
      {
         double dist = isBuy ? (op - sl) : (sl - op);
         g_slDistPoints = dist / p;
      }
      else
      {
         g_slDistPoints = CalcSLDistancePoints();
      }

      if(InpEnableTP1)
      {
         double tp1Pts = (InpTP1_RR > 0.0 ? (g_slDistPoints * InpTP1_RR) : (double)InpTP1Points);
         if(tp1Pts < 120.0) tp1Pts = 120.0;
         double distP = tp1Pts * p;
         g_tp1Price = isBuy ? (op + distP) : (op - distP);
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
   if(pct <= 0.0) { g_tp1Done=true; return; }
   if(pct > 100.0) pct = 100.0;

   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volToClose = NormalizeVolume(vol * (pct/100.0));

   if(vol - volToClose < vmin) volToClose = vol;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   if(volToClose >= vol - 1e-9)
   {
      if(trade.PositionClose(_Symbol)) g_tp1Done = true;
      return;
   }

   if(trade.PositionClosePartial(_Symbol, volToClose))
      g_tp1Done = true;
}

void ApplyBreakeven()
{
   if(!InpEnableBE || g_beDone) return;
   if(InpBE_OnlyAfterTP1 && !g_tp1Done) return;

   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol)) return;

   double p = Pnt();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPts = isBuy ? ((bid - op)/p) : ((op - ask)/p);

   double triggerPts = (InpBE_Trigger_RR > 0.0 && g_slDistPoints > 0.0)
                       ? (g_slDistPoints * InpBE_Trigger_RR)
                       : (double)InpBE_TriggerPoints;

   if(profitPts < triggerPts) return;

   int digits = Dig();
   double offset = (double)InpBE_OffsetPoints * p;
   double newSL = isBuy ? (op + offset) : (op - offset);
   newSL = NormalizeDouble(newSL, digits);

   if(sl > 0.0)
   {
      if(isBuy && newSL <= sl) return;
      if(!isBuy && newSL >= sl) return;
   }

   if(PositionModifySafe(isBuy, newSL, tp))
      g_beDone = true;
}

void ApplyTrailing()
{
   if(InpTrailMode == TRAIL_OFF) return;
   if(InpTrailOnlyAfterTP1 && !g_tp1Done) return;

   bool isBuy; ulong id; double op, sl, tp, vol;
   if(!GetCurrentPosition(isBuy, id, op, sl, tp, vol)) return;

   double p = Pnt();
   int digits = Dig();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitPts = isBuy ? ((bid - op)/p) : ((op - ask)/p);

   double startPts = (InpTrailStart_RR > 0.0 && g_slDistPoints > 0.0)
                     ? (g_slDistPoints * InpTrailStart_RR)
                     : (double)InpTrailStartPoints;

   if(profitPts < startPts) return;

   double trailPts = (double)InpTrailPoints;
   if(InpTrailMode == TRAIL_ATR_MULT)
   {
      double atr=0.0;
      if(GetATR(atr)) trailPts = (atr/p) * InpTrail_ATR_Mult;
   }
   if(trailPts < 120.0) trailPts = 120.0;

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
      if(isBuy && newSL <= sl) return;
      if(!isBuy && newSL >= sl) return;
   }

   PositionModifySafe(isBuy, newSL, tp);
}

//============================= TRADE OPS ===========================//
bool OpenTrade(bool isBuy)
{
   double sl=0.0, tp2=0.0, slDistPts=0.0;
   CalcSLTP(isBuy, sl, tp2, slDistPts);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = isBuy ? ask : bid;

   if(!StopsAreValid(isBuy, entry, sl, tp2)) return false;

   double lot = CalcLotByRisk(isBuy, entry, sl);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   if(isBuy) return trade.Buy(lot, _Symbol, 0.0, sl, tp2, InpEAName);
   else      return trade.Sell(lot, _Symbol, 0.0, sl, tp2, InpEAName);
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
   hATR = iATR(_Symbol, InpTF, InpATRPeriod);
   hMACD = iMACD(_Symbol, InpTF, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
   hMAtrend = iMA(_Symbol, InpTF, InpTrendMAPeriod, 0, InpTrendMAMethod, PRICE_CLOSE);

   if(hATR==INVALID_HANDLE || hMACD==INVALID_HANDLE || hMAtrend==INVALID_HANDLE)
      return INIT_FAILED;

   g_lastBarTime = iTime(_Symbol, InpTF, 0);

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   g_dayOfYear = dt.day_of_year;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(g_dayStartEquity <= 0.0) g_dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity = g_dayStartEquity;

   ResetState();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hATR     != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hMACD    != INVALID_HANDLE) IndicatorRelease(hMACD);
   if(hMAtrend != INVALID_HANDLE) IndicatorRelease(hMAtrend);
}

void OnTick()
{
   UpdateDDState();
   EnforceDDAction();

   RefreshPositionState();

   if(InpManageEveryTick)
   {
      ApplyTP1PartialClose();
      ApplyBreakeven();
      ApplyTrailing();
   }

   if(g_ddTriggered) return;

   if(!SpreadAllowed()) return;
   if(!SessionAllowed()) return;
   if(!FiltersOK()) return;

   if(InpEntryOnNewBar)
      if(!IsNewBar()) return;

   bool buySig=false, sellSig=false;
   if(!SignalD(buySig, sellSig)) return;
   if(!buySig && !sellSig) return;

   bool hasPos=false, posBuy=false;
   ulong id=0; double op=0, sl=0, tp=0, vol=0;
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

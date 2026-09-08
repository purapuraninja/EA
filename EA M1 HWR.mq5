//+------------------------------------------------------------------+
//|           XAUUSD_Scalp_Active_NoSession_MT5.mq5                   |
//|   ACTIVE SCALPING (more frequent entries)                         |
//|   Trend-follow + Pullback filter (near EMA fast)                  |
//|   NO SESSION | ATR/FIXED SLTP | Compounding | BE | Trailing        |
//|   Spread filter | Cooldown | 1 position per symbol+magic          |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//====================== INPUT ======================================
input int             InpMagic              = 20260122;
input ENUM_TIMEFRAMES InpTF                 = PERIOD_M1;

// --- Strategy (SUPER KETAT)
input int    InpEmaFast            = 20;
input int    InpEmaSlow            = 50;
input int    InpRSIPeriod          = 14;
input double InpRSI_BuyMin         = 54.0;   // RSI HARUS kuat
input double InpRSI_SellMax        = 46.0;

// Pullback HARUS dekat EMA (sniper)
input int    InpPullbackMaxPoints  = 250;    // sangat dekat EMA
input int    InpCooldownBars       = 3;      // nahan overtrade

// --- SL / TP (ketat & realistis)
input bool   InpUseATRStops        = true;
input int    InpATRPeriod          = 14;
input double InpATR_SL_Mult        = 0.9;    // SL ketat
input double InpATR_TP_Mult        = 1.4;    // RR > 1
input int    InpSL_Points          = 250;
input int    InpTP_Points          = 400;

// --- Compounding (AMAN)
input bool   InpUseCompoundStep    = true;
input double InpBaseBalance        = 100.0;
input double InpBaseLot            = 0.01;
input double InpStepBalance        = 75.0;   // naik lot lebih lambat
input double InpLotStep            = 0.01;
input double InpMinLot             = 0.01;
input double InpMaxLot             = 0.05;   // dibatasi (risk control)

// --- Protection / Execution (SUPER KETAT)
input int    InpMaxSpreadPoints    = 60;     // WAJIB spread super kecil
input int    InpDeviationPoints    = 30;
input bool   InpOnePositionOnly    = true;

// --- Break Even (cepat amankan posisi)
input bool   InpUseBreakEven       = true;
input int    InpBE_StartPoints     = 250;
input int    InpBE_OffsetPoints    = 50;

// --- Trailing (halus)
input bool   InpUseTrailing        = true;
input int    InpTrailStartPoints   = 400;
input int    InpTrailDistance      = 180;
input int    InpTrailStep          = 50;

//====================== GLOBAL =====================================
int      hFast = INVALID_HANDLE;
int      hSlow = INVALID_HANDLE;
int      hRSI  = INVALID_HANDLE;
int      hATR  = INVALID_HANDLE;

datetime lastBarTime = 0;
int      cooldownLeft = 0;

//====================== UTIL =======================================
double Clamp(double v, double lo, double hi)
{
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
}

int SpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 999999;
   return (int)MathRound((ask - bid) / _Point);
}

bool IsNewBar()
{
   datetime t = iTime(_Symbol, InpTF, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

double NormalizeLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lot = Clamp(lot, vmin, vmax);

   if(step > 0)
      lot = MathFloor(lot / step) * step;

   int prec = 2;
   if(step < 0.1)  prec = 3;
   if(step < 0.01) prec = 4;

   return NormalizeDouble(lot, prec);
}

double CalcCompoundLot()
{
   if(!InpUseCompoundStep)
      return NormalizeLot(InpBaseLot);

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double steps = 0;

   if(InpStepBalance > 0)
      steps = MathFloor((bal - InpBaseBalance) / InpStepBalance);

   if(steps < 0) steps = 0;

   double lot = InpBaseLot + steps * InpLotStep;
   lot = Clamp(lot, InpMinLot, InpMaxLot);
   return NormalizeLot(lot);
}

int CountMyPositions()
{
   int total = PositionsTotal();
   int count = 0;

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mag = PositionGetInteger(POSITION_MAGIC);

      if(sym == _Symbol && mag == InpMagic)
         count++;
   }
   return count;
}

//====================== STOPS ======================================
bool ComputeStops(bool buy, double &sl, double &tp)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return false;

   double price = buy ? ask : bid;

   double slp = (double)InpSL_Points;
   double tpp = (double)InpTP_Points;

   if(InpUseATRStops)
   {
      double atr[1];
      if(CopyBuffer(hATR, 0, 0, 1, atr) < 1) return false;
      if(atr[0] <= 0) return false;

      slp = (atr[0] * InpATR_SL_Mult) / _Point;
      tpp = (atr[0] * InpATR_TP_Mult) / _Point;
   }

   if(slp < 50) slp = 50;
   if(tpp < 50) tpp = 50;

   if(buy)
   {
      sl = price - slp * _Point;
      tp = price + tpp * _Point;
   }
   else
   {
      sl = price + slp * _Point;
      tp = price - tpp * _Point;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   return true;
}

//====================== SIGNAL (ACTIVE) ============================
// Trend-follow (no crossover) + pullback near EMA fast on CLOSED bar
int GetSignal()
{
   double f[2], s[2], r[1];

   // closed bar shift=1
   if(CopyBuffer(hFast, 0, 1, 2, f) < 2) return 0;
   if(CopyBuffer(hSlow, 0, 1, 2, s) < 2) return 0;
   if(CopyBuffer(hRSI,  0, 1, 1, r) < 1) return 0;

   double emaFast = f[0];
   double emaSlow = s[0];
   double rsi     = r[0];

   // use close of closed bar for distance to EMA fast
   double close1 = iClose(_Symbol, InpTF, 1);
   if(close1 <= 0) return 0;

   double distPoints = MathAbs(close1 - emaFast) / _Point;
   bool pullbackOK   = (distPoints <= InpPullbackMaxPoints);

   bool upTrend   = (emaFast > emaSlow);
   bool downTrend = (emaFast < emaSlow);

   if(upTrend && pullbackOK && rsi >= InpRSI_BuyMin)  return 1;
   if(downTrend && pullbackOK && rsi <= InpRSI_SellMax) return -1;

   return 0;
}

//====================== MANAGE (BE + TRAIL) ========================
void ManagePositions()
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(!PositionSelectByTicket(ticket)) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mag = PositionGetInteger(POSITION_MAGIC);
      if(sym != _Symbol || mag != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      bool buy  = (type == POSITION_TYPE_BUY);

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(bid <= 0 || ask <= 0) continue;

      double cur = buy ? bid : ask;
      double profitPoints = (buy ? (cur - open) : (open - cur)) / _Point;

      // Break-even
      if(InpUseBreakEven && profitPoints >= InpBE_StartPoints)
      {
         double newSL = buy ? (open + InpBE_OffsetPoints * _Point)
                            : (open - InpBE_OffsetPoints * _Point);

         bool improve = false;
         if(sl == 0) improve = true;
         else if(buy && newSL > sl) improve = true;
         else if(!buy && newSL < sl) improve = true;

         if(improve)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            if(!trade.PositionModify(_Symbol, newSL, tp))
               Print("BE modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }

      // Trailing stop
      if(InpUseTrailing && profitPoints >= InpTrailStartPoints)
      {
         double newSL = buy ? (cur - InpTrailDistance * _Point)
                            : (cur + InpTrailDistance * _Point);

         bool improve = false;
         if(sl == 0) improve = true;
         else if(buy && newSL > sl + InpTrailStep * _Point) improve = true;
         else if(!buy && newSL < sl - InpTrailStep * _Point) improve = true;

         if(improve)
         {
            newSL = NormalizeDouble(newSL, _Digits);
            if(!trade.PositionModify(_Symbol, newSL, tp))
               Print("Trail modify failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//====================== EVENTS =====================================
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   hFast = iMA(_Symbol, InpTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, InpTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);

   if(InpUseATRStops)
      hATR = iATR(_Symbol, InpTF, InpATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      Print("Indicator handle error (EMA/RSI).");
      return INIT_FAILED;
   }
   if(InpUseATRStops && hATR == INVALID_HANDLE)
   {
      Print("ATR handle error.");
      return INIT_FAILED;
   }

   lastBarTime = iTime(_Symbol, InpTF, 0);
   cooldownLeft = 0;

   Print("EA ACTIVE ready. Symbol=", _Symbol, " TF=", EnumToString(InpTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hFast != INVALID_HANDLE) IndicatorRelease(hFast);
   if(hSlow != INVALID_HANDLE) IndicatorRelease(hSlow);
   if(hRSI  != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR  != INVALID_HANDLE) IndicatorRelease(hATR);
}

void OnTick()
{
   // manage open trades
   ManagePositions();

   // entry only on new bar
   if(!IsNewBar()) return;

   // cooldown
   if(cooldownLeft > 0)
   {
      cooldownLeft--;
      return;
   }

   // spread filter for entry
   if(SpreadPoints() > InpMaxSpreadPoints) return;

   // 1 position only (symbol+magic)
   if(InpOnePositionOnly && CountMyPositions() > 0) return;

   int sig = GetSignal();
   if(sig == 0) return;

   double sl, tp;
   if(!ComputeStops(sig == 1, sl, tp)) return;

   double lot = CalcCompoundLot();

   bool ok = false;
   if(sig == 1)
      ok = trade.Buy(lot, _Symbol, 0.0, sl, tp, "ActiveScalp Buy");
   else
      ok = trade.Sell(lot, _Symbol, 0.0, sl, tp, "ActiveScalp Sell");

   if(ok)
      cooldownLeft = InpCooldownBars; // reset cooldown after entry
   else
      Print("Order failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
}
//+------------------------------------------------------------------+

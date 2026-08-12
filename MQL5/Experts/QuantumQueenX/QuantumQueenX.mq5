//+------------------------------------------------------------------+
//|                                                 QuantumQueenX.mq5|
//|                                                                  |
//|  A reconstruction of the "Quantum Queen X MT5" trading logic,     |
//|  reverse engineered from the 1466 published deals of the vendor's |
//|  IC Markets live signal (account 2234595, 2024-04-30 .. 2026-08-11)|
//|                                                                  |
//|  This is an independent clean-room reconstruction built only from |
//|  the public trade record and the public product description.  No  |
//|  vendor binary was decompiled and no vendor source was used.      |
//|                                                                  |
//|  See docs/REVERSE_ENGINEERING.md for the measurement behind every |
//|  default value in this file.                                      |
//+------------------------------------------------------------------+
#property copyright "Clean-room reconstruction for research use"
#property link      ""
#property version   "4.40"
#property description "Multi-session grid engine for XAUUSD, reconstructed from published live-signal deals."
#property description "12 built-in session strategies, 9 enabled by the default preset."

#include <Trade\Trade.mqh>
#include <QQX\Defs.mqh>
#include <QQX\Sym.mqh>
#include <QQX\Money.mqh>
#include <QQX\Signal.mqh>
#include <QQX\Basket.mqh>
#include <QQX\Strategy.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input ENUM_QQX_PRESET InpPreset             = QQX_PRESET_DEFAULT; // Preset
input ulong           InpMagicBase          = 22345000;           // Magic base (one per slot)
input string          InpTradeSymbol        = "";                 // Symbol ("" = chart symbol)
input ulong           InpSlippagePoints     = 30;                 // Max deviation (points)
input double          InpMaxSpreadPoints    = 60;                 // Max spread (points)
input string          InpComment            = "QQX";              // Order comment prefix

input group "=== Money management ==="
input ENUM_QQX_MM     InpMMMode             = QQX_MM_GRID_BUDGET; // Sizing mode
input double          InpFixedLot           = 0.01;               // Fixed lot (QQX_MM_FIXED)
input double          InpLotsPer1000        = 0.005;              // Lots per 1000 balance
input double          InpMaxLot             = 10.0;               // Hard lot cap
input double          InpGridLotMultiplier  = 1.0;                // Grid volume multiplier
input double          InpMaxBasketDDPercent = 25.0;               // GRID_BUDGET: worst-case float, % of balance (all slots)
input double          InpMaxMarginPercent   = 30.0;               // GRID_BUDGET: margin allowance, % of balance (all slots)

input group "=== Distances ==="
input ENUM_QQX_SCALE  InpTpScale            = QQX_SCALE_PRICE;    // Target scaling
input ENUM_QQX_SCALE  InpStepScale          = QQX_SCALE_PRICE;    // Grid spacing scaling
input double          InpTpAtrMult          = 0.35;               // Target = N x ATR
input double          InpStepAtrMult        = 0.60;               // Spacing = N x ATR
input double          InpTpFixedPoints      = 100;                // Target (points)
input double          InpStepFixedPoints    = 200;                // Spacing (points)
input int             InpAtrPeriod          = 14;                 // ATR period

input group "=== Basket management ==="
input ENUM_TIMEFRAMES InpGridTimeframe      = PERIOD_M1;          // Grid / exit cadence
input int             InpMinSecondsBetween  = 60;                 // Min seconds between entries
input int             InpMaxGridLevels      = 6;                  // Global cap on grid levels (see risk report)
input bool            InpUseProfitTrail     = false;              // Trail the basket profit
input double          InpTrailStartMult     = 1.00;               // Trail arms at N x target
input double          InpTrailGiveback      = 0.30;               // Close after giving back N of peak
input double          InpBasketStopMult     = 0.0;                // Basket stop at N x target (0=off)
input int             InpMaxBasketMinutes   = 0;                  // Basket lifetime cap (0=off)
input bool            InpCloseOnFriday      = false;              // Flatten before the weekend
input int             InpFridayCloseHour    = 22;                 // Friday flatten hour (server)

input group "=== Entry filter (inferred - see docs) ==="
input bool            InpUseTrendFilter     = true;               // EMA trend alignment
input bool            InpUseRsiFilter       = true;               // RSI pullback gate
input bool            InpUsePullbackFilter  = true;               // Retrace-from-swing gate
input int             InpEmaFastPeriod      = 21;                 // EMA fast
input int             InpEmaSlowPeriod      = 89;                 // EMA slow
input int             InpRsiPeriod          = 14;                 // RSI period
input double          InpRsiBuyMax          = 52.0;               // Buy only below this RSI
input double          InpRsiSellMin         = 48.0;               // Sell only above this RSI
input int             InpExtremeLookback    = 24;                 // Swing lookback (bars)
input double          InpPullbackAtr        = 0.50;               // Required retrace (x ATR)

input group "=== Risk engineering (post-backtest) ==="
input double          InpGridStepMult       = 1.35;               // Grid spacing growth per level
input bool            InpGridTrendGuard     = false;              // Freeze grid against a HTF trend (see docs)
input ENUM_TIMEFRAMES InpGuardTimeframe     = PERIOD_H1;          // Trend-guard timeframe
input int             InpGuardPeriod        = 50;                 // Trend-guard EMA period
input double          InpGuardSlopeAtr      = 0.12;               // Opposing slope that blocks adds (ATR/bar)
input bool            InpVolRegimeGate      = true;               // Skip new baskets in a volatility spike
input double          InpMaxAtrRatio        = 2.20;               // ATR / average ATR ceiling

input group "=== Basket recovery (fewer stop-outs) ==="
input int             InpRecoveryLevel      = 5;                  // Reduce target from this depth
input double          InpRecoveryHours      = 4.0;                // Reduce target from this age (h)
input double          InpRecoveryTargetMult = 0.35;               // Target multiplier in recovery
input double          InpBreakEvenHours     = 24.0;               // Accept break-even from this age (h)
input double          InpGiveUpHours        = 0.0;                // Accept bounded loss from this age (h, 0=off)
input double          InpGiveUpLossPct      = 1.0;                // That bound, % of balance
input bool            InpPairDeRisk         = true;               // Shed legs in funded pairs

input group "=== Account protection ==="
input double          InpMinMarginLevel     = 400.0;              // Block NEW baskets below this margin level %
input double          InpAddMarginFloor     = 150.0;              // Block grid ADDS below this margin level %
input double          InpBasketMaxLossPct   = 0.0;                // Hard per-basket stop, % of balance (0=off)
input int             InpMaxTotalPositions  = 40;                 // Max positions across all slots
input double          InpMaxLotsPerSide     = 0.0;                // Max total lots per direction (0=off, see docs)
input double          InpSoftBrakePercent   = 70.0;               // Below N% of balance: no new risk (0=off)
input double          InpEquityStopPercent  = 0.0;                // Flatten below N% of balance (0=off)
input double          InpDailyLossStop      = 0.0;                // Stop for the day after -N money (0=off)

input group "=== Custom mode (used when Preset = Custom) ==="
input bool  InpS01 = true;   // 01 Asia Momentum Buy    03:00-04:59 M15 BUY
input bool  InpS02 = true;   // 02 Asia Fade Sell       08:00-09:59 M12 SELL
input bool  InpS03 = false;  // 03 London Open Buy      08:00-08:59 M30 BUY
input bool  InpS04 = true;   // 04 London Trend Buy     09:00-13:59 M12 BUY
input bool  InpS05 = true;   // 05 Pre-NY Fade Sell     18:00-18:59 M20 SELL
input bool  InpS06 = true;   // 06 NY Trend Buy         19:00-20:59 M15 BUY
input bool  InpS07 = true;   // 07 NY Close Sell        21:00-21:59 M30 SELL
input bool  InpS08 = true;   // 08 Late Buy A           22:00-23:59 M4  BUY
input bool  InpS09 = true;   // 09 Late Buy B           22:00-23:59 M6  BUY
input bool  InpS10 = false;  // 10 Late Sell A          22:00-22:59 M30 SELL
input bool  InpS11 = true;   // 11 Late Sell B          23:00-23:59 M10 SELL
input bool  InpS12 = false;  // 12 Custom spare         (disabled)

input group "=== Display ==="
input bool            InpShowPanel          = true;               // On-chart dashboard

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         g_trade;
CSymbolCtx     g_sym;
CMoneyManager  g_money;
CStrategy      g_strat[QQX_MAX_STRATEGIES];
int            g_count=0;

SEngineCfg     g_eng;
SSignalCfg     g_sig;

datetime       g_dayStamp    =0;
double         g_dayStartEq   =0.0;
bool           g_dayBlocked   =false;
bool           g_panic        =false;
bool           g_braked       =false;

//+------------------------------------------------------------------+
//| The recovered session schedule.                                  |
//|                                                                  |
//| Every row is measured from the live record.  "TP" and "Step" are  |
//| the median take-profit distance and the median grid spacing of    |
//| that session expressed in basis points of the gold price, which   |
//| is the form that stays stable as gold moved from 2300 to 4400.    |
//|                                                                  |
//|  slot  session       tf   dir   baskets  tp bp  step bp  maxlvl   |
//|   01   03:00-04:59  M15  BUY       75     3.03    5.64     10     |
//|   02   08:00-09:59  M12  SELL      27     3.55    6.39      8     |
//|   03   08:00-08:59  M30  BUY        9     4.94    4.80      8     |
//|   04   09:00-13:59  M12  BUY       63     6.21    6.39      9     |
//|   05   18:00-18:59  M20  SELL      33     6.54   12.00      6     |
//|   06   19:00-20:59  M15  BUY       96     2.37    4.87      9     |
//|   07   21:00-21:59  M30  SELL      22     5.95   10.00      9     |
//|   08   22:00-23:59  M4   BUY      225     2.38    4.61      9     |
//|   09   22:00-23:59  M6   BUY      197     2.15    4.90     12     |
//|   10   22:00-22:59  M30  SELL      16     5.40    8.19      9     |
//|   11   23:00-23:59  M10  SELL      34     3.68   12.00      6     |
//|   12   spare, disabled by default                                 |
//|                                                                   |
//| Slots 5, 7 and 11 rarely built a grid (90th percentile = 2        |
//| positions), so their raw spacing estimates were noisy and have    |
//| been clamped to the 10-12 bp range rather than taken literally.   |
//+------------------------------------------------------------------+
void BuildStrategyTable(void)
  {
   SStrategyCfg c[QQX_MAX_STRATEGIES];

   //                  name                    start  end     timeframe    direction          tp    step  lvl  risk
   SetSlot(c[0], "01 Asia Momentum Buy",  3*60,  5*60, PERIOD_M15, QQX_DIR_BUY_ONLY,  3.03, 5.64, 10, 1.0);
   SetSlot(c[1], "02 Asia Fade Sell",     8*60, 10*60, PERIOD_M12, QQX_DIR_SELL_ONLY, 3.55, 6.39,  8, 1.0);
   SetSlot(c[2], "03 London Open Buy",    8*60,  9*60, PERIOD_M30, QQX_DIR_BUY_ONLY,  4.94, 4.80,  8, 1.0);
   SetSlot(c[3], "04 London Trend Buy",   9*60, 14*60, PERIOD_M12, QQX_DIR_BUY_ONLY,  6.21, 6.39,  9, 1.0);
   SetSlot(c[4], "05 Pre-NY Fade Sell",  18*60, 19*60, PERIOD_M20, QQX_DIR_SELL_ONLY, 6.54,12.00,  6, 1.0);
   SetSlot(c[5], "06 NY Trend Buy",      19*60, 21*60, PERIOD_M15, QQX_DIR_BUY_ONLY,  2.37, 4.87,  9, 1.0);
   SetSlot(c[6], "07 NY Close Sell",     21*60, 22*60, PERIOD_M30, QQX_DIR_SELL_ONLY, 5.95,10.00,  9, 1.0);
   SetSlot(c[7], "08 Late Buy A",        22*60, 24*60, PERIOD_M4,  QQX_DIR_BUY_ONLY,  2.38, 4.61,  9, 1.0);
   SetSlot(c[8], "09 Late Buy B",        22*60, 24*60, PERIOD_M6,  QQX_DIR_BUY_ONLY,  2.15, 4.90, 12, 1.0);
   SetSlot(c[9], "10 Late Sell A",       22*60, 23*60, PERIOD_M30, QQX_DIR_SELL_ONLY, 5.40, 8.19,  9, 1.0);
   SetSlot(c[10],"11 Late Sell B",       23*60, 24*60, PERIOD_M10, QQX_DIR_SELL_ONLY, 3.68,12.00,  6, 1.0);
   SetSlot(c[11],"12 Custom Spare",      22*60, 24*60, PERIOD_M5,  QQX_DIR_BOTH,      3.00, 5.00,  8, 1.0);

   //--- preset -> which slots are live
   bool on[QQX_MAX_STRATEGIES];
   for(int i=0;i<QQX_MAX_STRATEGIES;i++) on[i]=false;

   switch(InpPreset)
     {
      case QQX_PRESET_DEFAULT:
         //--- the nine strategies the vendor describes as the default set
         on[0]=on[1]=on[3]=on[4]=on[5]=on[6]=on[7]=on[8]=on[10]=true;
         break;
      case QQX_PRESET_LOW_RISK:
         //--- the five slots with the deepest live sample and the tightest
         //--- basket-loss distribution
         on[0]=on[5]=on[7]=on[8]=on[10]=true;
         break;
      case QQX_PRESET_ALL:
         for(int i=0;i<QQX_MAX_STRATEGIES;i++) on[i]=true;
         break;
      case QQX_PRESET_CUSTOM:
         on[0]=InpS01; on[1]=InpS02; on[2]=InpS03; on[3]=InpS04;
         on[4]=InpS05; on[5]=InpS06; on[6]=InpS07; on[7]=InpS08;
         on[8]=InpS09; on[9]=InpS10; on[10]=InpS11; on[11]=InpS12;
         break;
     }

   //--- Every enabled slot can be live at the same time, so the per-basket
   //--- risk budget has to be divided between them.  Nine slots each risking
   //--- 25% of balance is 225% of balance, which is how an account dies.
   int active=0;
   for(int i=0;i<QQX_MAX_STRATEGIES;i++) if(on[i]) active++;
   g_eng.slotShare=(active>0 ? 1.0/(double)active : 1.0);

   g_count=0;
   for(int i=0;i<QQX_MAX_STRATEGIES;i++)
     {
      if(!on[i]) continue;
      c[i].enabled=true;
      c[i].magic  =InpMagicBase+(ulong)i*QQX_MAGIC_STRIDE;
      if(c[i].maxLevels>InpMaxGridLevels) c[i].maxLevels=InpMaxGridLevels;

      if(!g_strat[g_count].Init(c[i],g_eng,GetPointer(g_sym),GetPointer(g_trade),
                                GetPointer(g_money),g_sig))
        {
         PrintFormat("QQX: slot '%s' failed to initialise and was skipped",c[i].name);
         continue;
        }
      g_count++;
     }
  }

//+------------------------------------------------------------------+
//| Fill one row of the schedule.                                    |
//+------------------------------------------------------------------+
void SetSlot(SStrategyCfg &c,const string name,const int startMin,const int endMin,
             const ENUM_TIMEFRAMES tf,const ENUM_QQX_DIRECTION dir,
             const double tpBp,const double stepBp,const int maxLevels,const double riskShare)
  {
   c.enabled  =false;
   c.name     =name;
   c.startMin =startMin;
   c.endMin   =(endMin>=1440 ? 1440 : endMin);
   c.tf       =tf;
   c.dir      =dir;
   c.tpValue  =tpBp;
   c.stepValue=stepBp;
   c.maxLevels=maxLevels;
   c.riskShare=riskShare;
   c.magic    =0;
  }

//+------------------------------------------------------------------+
//| Choose a filling mode the symbol actually supports.               |
//+------------------------------------------------------------------+
void ConfigureFilling(const string sym)
  {
   int modes=(int)SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   if((modes&SYMBOL_FILLING_FOK)!=0)      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((modes&SYMBOL_FILLING_IOC)!=0) g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   string sym=(StringLen(InpTradeSymbol)>0 ? InpTradeSymbol : _Symbol);

   if(!g_sym.Init(sym))
      return(INIT_FAILED);

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("QQX: algo trading is disabled for this account - the EA will only monitor");

   //--- gold on a 3-digit feed is explicitly out of scope for the original
   if(StringFind(sym,"XAU")>=0 && g_sym.Digits()>2)
      Print("QQX warning: ",sym," quotes with ",g_sym.Digits(),
            " digits.  The reconstructed distances were measured on a 2-digit gold feed.");

   g_trade.SetExpertMagicNumber(InpMagicBase);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetAsyncMode(false);
   ConfigureFilling(sym);

   g_money.Init(GetPointer(g_sym),InpMMMode,InpFixedLot,InpLotsPer1000,
                InpMaxLot,InpGridLotMultiplier);

   //--- engine-wide behaviour
   g_eng.tpScale                 =InpTpScale;
   g_eng.stepScale               =InpStepScale;
   g_eng.tpAtrMult               =InpTpAtrMult;
   g_eng.stepAtrMult             =InpStepAtrMult;
   g_eng.tpFixedPoints           =InpTpFixedPoints;
   g_eng.stepFixedPoints         =InpStepFixedPoints;
   g_eng.gridTf                  =InpGridTimeframe;
   g_eng.minSecondsBetweenEntries=InpMinSecondsBetween;
   g_eng.useProfitTrail          =InpUseProfitTrail;
   g_eng.trailStartMult          =InpTrailStartMult;
   g_eng.trailGiveback           =QQXClamp(InpTrailGiveback,0.01,0.95);
   g_eng.basketStopMult          =InpBasketStopMult;
   g_eng.maxBasketMinutes        =InpMaxBasketMinutes;
   g_eng.maxSpreadPoints         =InpMaxSpreadPoints;
   g_eng.closeOnFriday           =InpCloseOnFriday;
   g_eng.fridayCloseMin          =InpFridayCloseHour*60;
   g_eng.commentPrefix           =InpComment;

   //--- risk engineering, added after diagnosing the 2026 backtest
   g_eng.gridStepMult            =(InpGridStepMult<1.0 ? 1.0 : InpGridStepMult);
   g_eng.gridTrendGuard          =InpGridTrendGuard;
   g_eng.volRegimeGate           =InpVolRegimeGate;
   g_eng.recoveryLevel           =InpRecoveryLevel;
   g_eng.recoveryHours           =InpRecoveryHours;
   g_eng.recoveryTargetMult      =QQXClamp(InpRecoveryTargetMult,0.05,1.0);
   g_eng.breakEvenHours          =InpBreakEvenHours;
   g_eng.giveUpHours             =InpGiveUpHours;
   g_eng.giveUpLossPct           =InpGiveUpLossPct;
   g_eng.pairDeRisk              =InpPairDeRisk;
   g_eng.basketMaxLossPct        =InpBasketMaxLossPct;
   g_eng.minMarginLevel          =InpMinMarginLevel;
   g_eng.addMarginFloor          =InpAddMarginFloor;
   g_eng.mmMode                  =InpMMMode;
   g_eng.basketBudgetPct         =InpMaxBasketDDPercent;
   g_eng.marginBudgetPct         =InpMaxMarginPercent;
   g_eng.slotShare               =1.0;      // replaced in BuildStrategyTable

   //--- entry filter
   g_sig.atrPeriod        =InpAtrPeriod;
   g_sig.emaFastPeriod    =InpEmaFastPeriod;
   g_sig.emaSlowPeriod    =InpEmaSlowPeriod;
   g_sig.rsiPeriod        =InpRsiPeriod;
   g_sig.rsiBuyMax        =InpRsiBuyMax;
   g_sig.rsiSellMin       =InpRsiSellMin;
   g_sig.extremeLookback  =InpExtremeLookback;
   g_sig.pullbackAtr      =InpPullbackAtr;
   g_sig.useTrendFilter   =InpUseTrendFilter;
   g_sig.useRsiFilter     =InpUseRsiFilter;
   g_sig.usePullbackFilter=InpUsePullbackFilter;
   g_sig.guardTf          =InpGuardTimeframe;
   g_sig.guardPeriod      =InpGuardPeriod;
   g_sig.guardSlopeAtr    =InpGuardSlopeAtr;
   g_sig.maxAtrRatio      =InpMaxAtrRatio;

   BuildStrategyTable();
   if(g_count==0)
     {
      Print("QQX: no strategy slot is enabled - check the preset or the custom switches");
      return(INIT_FAILED);
     }

   g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayStamp  =DayStamp(TimeCurrent());

   PrintRiskReport();

   //--- Two settings destroyed the 2026 backtest.  Warn loudly about both.
   if(InpEquityStopPercent>0.0)
      PrintFormat("QQX WARNING: InpEquityStopPercent=%.0f is a LIQUIDATION, not a stop loss. "
                  "In the 2026 test it flattened 4 baskets that still had 202-336%% margin "
                  "level and cost -19,802.  37 of the 42 baskets that dipped that deep "
                  "recovered on their own.  Prefer InpSoftBrakePercent + InpMinMarginLevel.",
                  InpEquityStopPercent);
   if(InpBasketMaxLossPct>0.0)
      PrintFormat("QQX WARNING: InpBasketMaxLossPct=%.1f caps each basket, but a grid earns "
                  "by recovering.  Measured on the 2026 test a 5%% cap would have fired 42 "
                  "times and 37 of those baskets went on to win.",InpBasketMaxLossPct);
   if(InpMMMode!=QQX_MM_FIXED && InpLotsPer1000>0.006)
      PrintFormat("QQX WARNING: %.4f lots per 1000 exceeds the size the 2026 drawdowns "
                  "survive.  At 0.0100 one basket margin-called at -53%% margin level; "
                  "0.0050 survives with 73%%, 0.0035 with 181%%.",InpLotsPer1000);

   PrintFormat("QQX ready on %s - %d strategy slot(s), preset %s, magic base %I64u",
               sym,g_count,EnumToString(InpPreset),InpMagicBase);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Risk report, printed once at init.                                |
//|                                                                   |
//| Both blown backtests were configuration failures that were fully   |
//| computable before the first trade: a fully deployed grid simply    |
//| cost more than the account had.  This prints that number up front  |
//| instead of discovering it afterwards.                              |
//+------------------------------------------------------------------+
void PrintRiskReport(void)
  {
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return;

   double totLoss=0.0,totMargin=0.0,totLots=0.0;
   int    infeasible=0;

   Print("QQX ---------------- projected worst case ----------------");
   PrintFormat("QQX  balance %.2f   leverage 1:%d   %s @ %.2f",
               balance,(int)AccountInfoInteger(ACCOUNT_LEVERAGE),
               g_sym.Symbol(),g_sym.Bid());
   Print("QQX  slot                    lvl   base    total   span     float    margin");

   for(int i=0;i<g_count;i++)
     {
      double baseLot=0.0,lots=0.0,span=0.0,margin=0.0;
      double loss=g_strat[i].ProjectedWorstCase(baseLot,lots,span,margin);
      totLoss+=loss; totMargin+=margin; totLots+=lots;
      if(baseLot<=0.0)
        {
         infeasible++;
         PrintFormat("QQX  %-22s %3d      -        -      - "
                     "   INFEASIBLE: budget implies less than the minimum lot",
                     g_strat[i].Name(),g_strat[i].MaxLevels());
         continue;
        }
      PrintFormat("QQX  %-22s %3d %6.2f %8.2f %6.1f %9.0f %9.0f",
                  g_strat[i].Name(),g_strat[i].MaxLevels(),baseLot,lots,span,loss,margin);
     }

   double ddPct=(balance>0.0 ? -totLoss/balance*100.0 : 0.0);
   double lvlAt =(totMargin>0.0 ? (balance+totLoss)/totMargin*100.0 : 0.0);

   PrintFormat("QQX  ALL SLOTS FULLY DEPLOYED: %.2f lots, floating %.0f "
               "(%.1f%% of balance), margin %.0f",totLots,totLoss,ddPct,totMargin);
   PrintFormat("QQX  margin level in that state: %.0f%%  (broker stop-out is "
               "typically 50%%)",lvlAt);

   if(ddPct>=100.0 || (lvlAt>0.0 && lvlAt<100.0))
      Print("QQX  *** THIS CONFIGURATION CANNOT SURVIVE ITS OWN GRID. ***  "
            "Reduce InpMaxBasketDDPercent / InpLotsPer1000, reduce "
            "InpMaxGridLevels, enable fewer slots, or raise InpGridStepMult.");
   else if(ddPct>=60.0)
      Print("QQX  WARNING: a full deployment would cost most of the account.");

   if(infeasible>0)
      PrintFormat("QQX  %d slot(s) will NOT TRADE: their risk budget is smaller than the "
                  "broker's minimum lot.  Enable fewer slots, lower InpMaxGridLevels, "
                  "raise InpMaxBasketDDPercent, or fund the account further.  "
                  "(A 10k account at gold ~4400 supports about 9 slots x 6 levels, "
                  "or 5 slots x 8 levels.)",infeasible);
   Print("QQX -------------------------------------------------------");
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   for(int i=0;i<g_count;i++) g_strat[i].Deinit();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Midnight stamp of a server datetime.                             |
//+------------------------------------------------------------------+
datetime DayStamp(const datetime t)
  {
   return((datetime)((long)t-((long)t%86400)));
  }

//+------------------------------------------------------------------+
//| Portfolio snapshot across every slot this EA owns.                |
//+------------------------------------------------------------------+
struct SPortfolio
  {
   int               positions;
   double            lotsBuy;
   double            lotsSell;
  };

SPortfolio ScanPortfolio(void)
  {
   SPortfolio p;
   p.positions=0; p.lotsBuy=0.0; p.lotsSell=0.0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      if(PositionGetTicket(i)==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym.Symbol()) continue;
      ulong m=(ulong)PositionGetInteger(POSITION_MAGIC);
      if(m<InpMagicBase || m>=InpMagicBase+QQX_MAX_STRATEGIES*QQX_MAGIC_STRIDE) continue;
      p.positions++;
      double v=PositionGetDouble(POSITION_VOLUME);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) p.lotsBuy+=v;
      else                                                                          p.lotsSell+=v;
     }
   return(p);
  }

//+------------------------------------------------------------------+
//| Account level protection.                                         |
//|                                                                   |
//| The original build carried a single hard equity stop, and the      |
//| 2026 backtest showed why that is the wrong instrument: it fires    |
//| at maximum adverse excursion and liquidates every slot at once,    |
//| converting a floating drawdown into a realised -11,828.  It is     |
//| replaced here by a two-stage brake:                                |
//|                                                                    |
//|   soft brake  -> stop opening, stop averaging, wind baskets down   |
//|   hard stop   -> flatten, and only far below the soft level        |
//|                                                                    |
//| Sets "brake" when the soft level is breached.  Returns false when  |
//| no NEW basket may be opened.                                       |
//+------------------------------------------------------------------+
bool AccountGuard(const datetime now,const SPortfolio &pf,bool &brake)
  {
   brake=false;

   datetime stamp=DayStamp(now);
   if(stamp!=g_dayStamp)
     {
      g_dayStamp  =stamp;
      g_dayStartEq=AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayBlocked=false;
     }

   double equity =AccountInfoDouble(ACCOUNT_EQUITY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double ratio  =(balance>0.0 ? equity/balance*100.0 : 100.0);

   //--- soft brake: de-risk without realising anything
   if(InpSoftBrakePercent>0.0 && ratio<InpSoftBrakePercent)
     {
      brake=true;
      if(!g_braked)
        {
         g_braked=true;
         PrintFormat("QQX: equity at %.1f%% of balance - soft brake on "
                     "(no new baskets, no grid adds, baskets wind down)",ratio);
        }
     }
   else if(g_braked && ratio>InpSoftBrakePercent+5.0)
     {
      g_braked=false;
      Print("QQX: soft brake released");
     }

   //--- hard floor: last resort only
   if(InpEquityStopPercent>0.0 && balance>0.0 && ratio<InpEquityStopPercent)
     {
      if(!g_panic)
        {
         g_panic=true;
         PrintFormat("QQX: equity %.2f below %.1f%% of balance %.2f - flattening",
                     equity,InpEquityStopPercent,balance);
         for(int i=0;i<g_count;i++) g_strat[i].PanicClose();
        }
      return(false);
     }
   g_panic=false;

   //--- daily loss brake: stop opening, let live baskets finish
   if(InpDailyLossStop>0.0 && (g_dayStartEq-equity)>=InpDailyLossStop)
     {
      if(!g_dayBlocked)
        {
         g_dayBlocked=true;
         PrintFormat("QQX: daily loss limit %.2f reached - no new baskets today",InpDailyLossStop);
        }
     }
   if(g_dayBlocked) return(false);
   if(brake)        return(false);

   if(InpMaxTotalPositions>0 && pf.positions>=InpMaxTotalPositions) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_sym.Refresh()) return;

   datetime   now=TimeCurrent();
   SPortfolio pf =ScanPortfolio();
   bool       brake=false;
   bool       canOpen=AccountGuard(now,pf,brake);

   //--- Portfolio exposure cap.  Nine of the eleven recovered slots are long
   //--- gold, so a sell-off loads every one of them at the same time.  This
   //--- caps how much the book may accumulate on a single side.
   bool buyOk =true, sellOk=true;
   if(InpMaxLotsPerSide>0.0)
     {
      buyOk =(pf.lotsBuy  < InpMaxLotsPerSide);
      sellOk=(pf.lotsSell < InpMaxLotsPerSide);
     }

   //--- Every slot always gets a chance to manage its own basket, even when
   //--- the account guard has forbidden new baskets.
   for(int i=0;i<g_count;i++)
      g_strat[i].Process(now,canOpen,brake,
                         g_strat[i].PrefersBuy() ? buyOk : sellOk);

   if(InpShowPanel) DrawPanel(now,canOpen,brake);
  }

//+------------------------------------------------------------------+
//| On-chart dashboard                                               |
//+------------------------------------------------------------------+
void DrawPanel(const datetime now,const bool canOpen,const bool brake)
  {
   static datetime lastDraw=0;
   if(now==lastDraw) return;         // once per second is plenty
   lastDraw=now;

   int    totalPos=0;
   double totalVol=0.0,floating=0.0,realized=0.0;
   for(int i=0;i<g_count;i++)
     {
      totalPos+=g_strat[i].Positions();
      totalVol+=g_strat[i].Volume();
      floating+=g_strat[i].Floating();
      realized+=g_strat[i].Realized();
     }

   string s="";
   s+="Quantum Queen X  (reconstruction)\n";
   s+=StringFormat("%s   spread %.0f pts   server %s\n",
                   g_sym.Symbol(),g_sym.SpreadPoints(),TimeToString(now,TIME_MINUTES|TIME_SECONDS));
   double eq=AccountInfoDouble(ACCOUNT_EQUITY), bl=AccountInfoDouble(ACCOUNT_BALANCE);
   s+=StringFormat("preset %s   slots %d   new baskets: %s%s\n",
                   EnumToString(InpPreset),g_count,(canOpen?"allowed":"BLOCKED"),
                   (brake?"   [SOFT BRAKE]":""));
   s+=StringFormat("equity %.2f / balance %.2f = %.1f%%\n",
                   eq,bl,(bl>0.0?eq/bl*100.0:100.0));
   s+=StringFormat("open %d pos / %.2f lots   floating %.2f   session P/L %.2f\n",
                   totalPos,totalVol,floating,realized);
   s+="------------------------------------------------------------\n";
   s+="slot                    session      tf   dir   pos    lots   float   age   stage\n";

   for(int i=0;i<g_count;i++)
     {
      int st=g_strat[i].Stage(now);
      string stage="-";
      if(g_strat[i].Positions()>0)
        {
         if(st==1)      stage="reduce";
         else if(st==2) stage="b/even";
         else if(st==3) stage="giveup";
         else           stage="normal";
        }
      s+=StringFormat("%-22s %-11s %-5s %-5s %3d  %6.2f  %7.2f  %5.1f  %s\n",
                      g_strat[i].Name(),
                      g_strat[i].SessionText(),
                      QQXTfToString(g_strat[i].Timeframe()),
                      g_strat[i].DirText(),
                      g_strat[i].Positions(),
                      g_strat[i].Volume(),
                      g_strat[i].Floating(),
                      g_strat[i].AgeHours(now),
                      stage);
     }
   Comment(s);
  }
//+------------------------------------------------------------------+

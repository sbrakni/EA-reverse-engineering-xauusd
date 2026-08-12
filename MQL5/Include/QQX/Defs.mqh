//+------------------------------------------------------------------+
//|                                                         Defs.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  Shared enumerations, constants and small helpers used by every   |
//|  module of the engine.                                            |
//+------------------------------------------------------------------+
#property copyright "Reverse-engineered reconstruction for research use"
#property link      ""
#ifndef __QQX_DEFS_MQH__
#define __QQX_DEFS_MQH__

//--- Number of strategy slots the engine can host.
//    The published product advertises "12 optimized built-in strategies"
//    of which 9 are enabled by the default preset.  The session/timeframe
//    fingerprint recovered from the live signal history yields exactly 11
//    distinct session x timeframe x direction clusters; slot 12 is kept as
//    a spare so a Custom-Mode user can wire an extra session.
#define QQX_MAX_STRATEGIES   12

//--- Sub-range of the magic space reserved per strategy slot.
#define QQX_MAGIC_STRIDE     1

//+------------------------------------------------------------------+
//| Direction lock for a strategy slot.                              |
//|                                                                  |
//| Reverse-engineering note: the live history is strongly direction  |
//| locked per session (e.g. 03:00-04:59 produced 75 buy baskets and  |
//| zero sell baskets; 18:00-18:59 produced 33 sell baskets and zero  |
//| buy baskets).  Direction is therefore a per-strategy property,    |
//| not a per-signal outcome.                                         |
//+------------------------------------------------------------------+
enum ENUM_QQX_DIRECTION
  {
   QQX_DIR_BUY_ONLY  = 0,  // Buy only
   QQX_DIR_SELL_ONLY = 1,  // Sell only
   QQX_DIR_BOTH      = 2   // Both directions
  };

//+------------------------------------------------------------------+
//| How the grid spacing and the basket target are measured.         |
//|                                                                  |
//| Reverse-engineering note: expressed as a fraction of price the    |
//| observed grid spacing is remarkably stable across the whole       |
//| record (5.33 bp in 2024, 5.39 bp in 2025, 4.60 bp in 2026) while  |
//| the absolute spacing grew from 1.34 to 2.10 USD as gold went from |
//| 2500 to 4640.  Volatility-relative spacing is therefore the       |
//| default; fixed spacing is offered for reproducibility.            |
//+------------------------------------------------------------------+
enum ENUM_QQX_SCALE
  {
   QQX_SCALE_ATR    = 0,   // Multiple of ATR (adaptive)
   QQX_SCALE_PRICE  = 1,   // Basis points of price (adaptive)
   QQX_SCALE_FIXED  = 2    // Fixed distance in points
  };

//+------------------------------------------------------------------+
//| Money-management mode.                                           |
//+------------------------------------------------------------------+
enum ENUM_QQX_MM
  {
   QQX_MM_FIXED    = 0,    // Fixed lot
   QQX_MM_BALANCE  = 1,    // Lots per 1000 of balance
   QQX_MM_EQUITY   = 2     // Lots per 1000 of equity
  };

//+------------------------------------------------------------------+
//| Preset selector.                                                 |
//+------------------------------------------------------------------+
enum ENUM_QQX_PRESET
  {
   QQX_PRESET_DEFAULT   = 0, // Default (9 strategies)
   QQX_PRESET_LOW_RISK  = 1, // Low risk (5 strategies)
   QQX_PRESET_ALL       = 2, // All strategies
   QQX_PRESET_CUSTOM    = 3  // Custom mode (use the enable switches)
  };

//+------------------------------------------------------------------+
//| Basket close reason - used only for the log / dashboard.         |
//+------------------------------------------------------------------+
enum ENUM_QQX_CLOSE_REASON
  {
   QQX_CLOSE_NONE      = 0,
   QQX_CLOSE_TARGET    = 1,  // basket profit target reached
   QQX_CLOSE_TRAIL     = 2,  // profit trail gave back too much
   QQX_CLOSE_SESSION   = 3,  // hard session/lifetime expiry
   QQX_CLOSE_STOP      = 4,  // basket protective stop
   QQX_CLOSE_PANIC     = 5   // account level protection
  };

//+------------------------------------------------------------------+
//| Clamp helper.                                                    |
//+------------------------------------------------------------------+
double QQXClamp(const double v,const double lo,const double hi)
  {
   if(v<lo) return(lo);
   if(v>hi) return(hi);
   return(v);
  }

//+------------------------------------------------------------------+
//| Minutes since midnight for a server datetime.                     |
//+------------------------------------------------------------------+
int QQXMinuteOfDay(const datetime t)
  {
   MqlDateTime st;
   TimeToStruct(t,st);
   return(st.hour*60+st.min);
  }

//+------------------------------------------------------------------+
//| Day of week for a server datetime (0 = Sunday .. 6 = Saturday).   |
//+------------------------------------------------------------------+
int QQXDayOfWeek(const datetime t)
  {
   MqlDateTime st;
   TimeToStruct(t,st);
   return((int)st.day_of_week);
  }

//+------------------------------------------------------------------+
//| Text label for a timeframe, used in the dashboard.                |
//+------------------------------------------------------------------+
string QQXTfToString(const ENUM_TIMEFRAMES tf)
  {
   string s=EnumToString(tf);
   StringReplace(s,"PERIOD_","");
   return(s);
  }

#endif // __QQX_DEFS_MQH__
//+------------------------------------------------------------------+

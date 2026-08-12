//+------------------------------------------------------------------+
//|                                                       Signal.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  Entry filter.                                                    |
//|                                                                  |
//|  Reverse-engineering note - READ THIS                             |
//|  -----------------------------------                              |
//|  Everything else in this project is measured directly from the    |
//|  1466 published deals.  The entry *filter* is the one component   |
//|  that a trade log cannot uniquely determine: the log records the  |
//|  moments the EA decided to trade, never the moments it looked and |
//|  declined, and no price series is bundled with the export.        |
//|                                                                   |
//|  What the log does pin down, and what this module reproduces:      |
//|    * entries land on the *bar open* of a strategy specific        |
//|      timeframe - 88% of all 1466 entries carry second == 0, and   |
//|      the per-session minute fingerprints are exact (03:00/15/30/  |
//|      45 -> M15, 08:00/12/24/36/48 -> M12, 18:00/20/40 -> M20,     |
//|      21:00/30 -> M30, 23:00/10/20/30/40 -> M10 ...);              |
//|    * the direction is locked per session, so the filter only ever |
//|      answers "trade now?", never "which way?";                     |
//|    * the filter is selective - only 219 of ~594 weekdays in the   |
//|      window produced any trade at all (37%).                       |
//|                                                                   |
//|  The vendor describes the system as an "elite trend-following     |
//|  grid" that "waits, analyses and executes when multiple           |
//|  conditions align".  The reconstruction below is a trend +        |
//|  pullback + momentum confluence gate calibrated to fire at        |
//|  roughly the observed frequency.  Its thresholds are exposed as   |
//|  inputs precisely because they are inferred rather than measured. |
//+------------------------------------------------------------------+
#ifndef __QQX_SIGNAL_MQH__
#define __QQX_SIGNAL_MQH__

#include "Defs.mqh"

//+------------------------------------------------------------------+
//| Tunable thresholds shared by every strategy slot.                |
//+------------------------------------------------------------------+
struct SSignalCfg
  {
   int               atrPeriod;
   int               emaFastPeriod;
   int               emaSlowPeriod;
   int               rsiPeriod;
   double            rsiBuyMax;        // buys only below this RSI (pullback)
   double            rsiSellMin;       // sells only above this RSI
   int               extremeLookback;  // bars scanned for the swing extreme
   double            pullbackAtr;      // required retrace from the extreme, in ATR
   bool              useTrendFilter;   // require EMA fast/slow alignment
   bool              useRsiFilter;
   bool              usePullbackFilter;
  };

//+------------------------------------------------------------------+
//| CSignal - one instance per strategy slot, bound to that slot's   |
//| signal timeframe.                                                |
//+------------------------------------------------------------------+
class CSignal
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_hAtr;
   int               m_hEmaFast;
   int               m_hEmaSlow;
   int               m_hRsi;
   SSignalCfg        m_cfg;
   bool              m_ready;

   //--- read one indicator value from the closed bar "shift"
   bool              Value(const int handle,const int buffer,const int shift,double &out) const
     {
      double buf[];
      if(handle==INVALID_HANDLE) return(false);
      if(CopyBuffer(handle,buffer,shift,1,buf)!=1) return(false);
      out=buf[0];
      return(out!=EMPTY_VALUE);
     }

public:
                     CSignal(void): m_symbol(""),m_tf(PERIOD_M15),m_hAtr(INVALID_HANDLE),
                                    m_hEmaFast(INVALID_HANDLE),m_hEmaSlow(INVALID_HANDLE),
                                    m_hRsi(INVALID_HANDLE),m_ready(false) {}
                    ~CSignal(void) { Release(); }

   bool              IsReady(void) const { return(m_ready); }

   //+---------------------------------------------------------------+
   //| Create the indicator handles for this slot.                    |
   //+---------------------------------------------------------------+
   bool              Init(const string symbol,const ENUM_TIMEFRAMES tf,const SSignalCfg &cfg)
     {
      Release();
      m_symbol=symbol;
      m_tf=tf;
      m_cfg=cfg;

      m_hAtr    =iATR(m_symbol,m_tf,m_cfg.atrPeriod);
      m_hEmaFast=iMA (m_symbol,m_tf,m_cfg.emaFastPeriod,0,MODE_EMA,PRICE_CLOSE);
      m_hEmaSlow=iMA (m_symbol,m_tf,m_cfg.emaSlowPeriod,0,MODE_EMA,PRICE_CLOSE);
      m_hRsi    =iRSI(m_symbol,m_tf,m_cfg.rsiPeriod,PRICE_CLOSE);

      m_ready=(m_hAtr!=INVALID_HANDLE && m_hEmaFast!=INVALID_HANDLE &&
               m_hEmaSlow!=INVALID_HANDLE && m_hRsi!=INVALID_HANDLE);
      if(!m_ready)
        {
         PrintFormat("QQX: failed to create indicators for %s %s",m_symbol,QQXTfToString(m_tf));
         return(false);
        }

      //--- Several slots run on non-standard periods (M4, M6, M10, M12, M20).
      //--- Touching the series here asks the terminal to synthesise them from
      //--- M1 straight away instead of on the first signal evaluation.
      datetime warm[];
      CopyTime(m_symbol,m_tf,0,2,warm);
      return(true);
     }

   void              Release(void)
     {
      if(m_hAtr    !=INVALID_HANDLE) { IndicatorRelease(m_hAtr);     m_hAtr    =INVALID_HANDLE; }
      if(m_hEmaFast!=INVALID_HANDLE) { IndicatorRelease(m_hEmaFast); m_hEmaFast=INVALID_HANDLE; }
      if(m_hEmaSlow!=INVALID_HANDLE) { IndicatorRelease(m_hEmaSlow); m_hEmaSlow=INVALID_HANDLE; }
      if(m_hRsi    !=INVALID_HANDLE) { IndicatorRelease(m_hRsi);     m_hRsi    =INVALID_HANDLE; }
      m_ready=false;
     }

   //+---------------------------------------------------------------+
   //| Current ATR on the slot timeframe, taken from the closed bar.  |
   //| This is the volatility yardstick the grid spacing and the      |
   //| basket target are expressed in.                                |
   //+---------------------------------------------------------------+
   double            Atr(void) const
     {
      double v=0.0;
      if(!Value(m_hAtr,0,1,v)) return(0.0);
      return(v);
     }

   //+---------------------------------------------------------------+
   //| Evaluate the confluence gate for the requested direction.      |
   //| Called once per closed bar of the slot timeframe.              |
   //+---------------------------------------------------------------+
   bool              Allows(const bool isBuy) const
     {
      if(!m_ready) return(false);

      //--- trend leg: price must be on the working side of the slow EMA
      //--- and the fast EMA must agree with the traded direction
      if(m_cfg.useTrendFilter)
        {
         double fast=0.0,slow=0.0;
         if(!Value(m_hEmaFast,0,1,fast)) return(false);
         if(!Value(m_hEmaSlow,0,1,slow)) return(false);
         if(isBuy  && fast<=slow) return(false);
         if(!isBuy && fast>=slow) return(false);
        }

      //--- momentum leg: only join a trend from a cooled-off reading, which
      //--- is what keeps the system out of the market on most days
      if(m_cfg.useRsiFilter)
        {
         double rsi=0.0;
         if(!Value(m_hRsi,0,1,rsi)) return(false);
         if(isBuy  && rsi>m_cfg.rsiBuyMax)  return(false);
         if(!isBuy && rsi<m_cfg.rsiSellMin) return(false);
        }

      //--- location leg: require a real retrace from the recent swing so the
      //--- first grid entry is never placed into an extended move
      if(m_cfg.usePullbackFilter)
        {
         double atr=Atr();
         if(atr<=0.0) return(false);

         int lookback=m_cfg.extremeLookback;
         if(lookback<2) lookback=2;

         double cl[];
         if(CopyClose(m_symbol,m_tf,1,1,cl)!=1) return(false);
         double last=cl[0];

         if(isBuy)
           {
            double hi[];
            if(CopyHigh(m_symbol,m_tf,1,lookback,hi)!=lookback) return(false);
            double top=hi[ArrayMaximum(hi)];
            if((top-last)<m_cfg.pullbackAtr*atr) return(false);
           }
         else
           {
            double lo[];
            if(CopyLow(m_symbol,m_tf,1,lookback,lo)!=lookback) return(false);
            double bottom=lo[ArrayMinimum(lo)];
            if((last-bottom)<m_cfg.pullbackAtr*atr) return(false);
           }
        }

      return(true);
     }
  };

#endif // __QQX_SIGNAL_MQH__
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                     Strategy.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  One strategy slot = one trading session, one signal timeframe,   |
//|  one locked direction, one basket, one magic number.              |
//+------------------------------------------------------------------+
#ifndef __QQX_STRATEGY_MQH__
#define __QQX_STRATEGY_MQH__

#include "Defs.mqh"
#include "Sym.mqh"
#include "Money.mqh"
#include "Signal.mqh"
#include "Basket.mqh"

//+------------------------------------------------------------------+
//| Static description of a slot.                                    |
//+------------------------------------------------------------------+
struct SStrategyCfg
  {
   bool              enabled;
   string            name;
   int               startMin;      // session open, minutes since server midnight
   int               endMin;        // session close, exclusive
   ENUM_TIMEFRAMES   tf;            // timeframe whose bar opens trigger entries
   ENUM_QQX_DIRECTION dir;
   double            tpValue;       // basket target, in the active scale unit
   double            stepValue;     // grid spacing, in the active scale unit
   int               maxLevels;     // hard cap on positions in the basket
   double            riskShare;     // multiplier on the global position size
   ulong             magic;
  };

//+------------------------------------------------------------------+
//| Runtime behaviour shared by every slot.                          |
//+------------------------------------------------------------------+
struct SEngineCfg
  {
   ENUM_QQX_SCALE    tpScale;
   ENUM_QQX_SCALE    stepScale;
   double            tpAtrMult;        // used when tpScale  == ATR
   double            stepAtrMult;      // used when stepScale == ATR
   double            tpFixedPoints;    // used when tpScale  == FIXED
   double            stepFixedPoints;  // used when stepScale== FIXED
   ENUM_TIMEFRAMES   gridTf;           // cadence for grid adds and exit checks
   int               minSecondsBetweenEntries;
   bool              useProfitTrail;
   double            trailStartMult;   // trail arms at this multiple of the target
   double            trailGiveback;    // fraction of the peak that may be given back
   double            basketStopMult;   // emergency stop, multiple of the target (0 = off)
   int               maxBasketMinutes; // hard lifetime cap (0 = off)
   double            maxSpreadPoints;
   bool              closeOnFriday;
   int               fridayCloseMin;
   string            commentPrefix;
  };

//+------------------------------------------------------------------+
//| CStrategy                                                        |
//+------------------------------------------------------------------+
class CStrategy
  {
private:
   SStrategyCfg      m_cfg;
   //--- MQL5 has no pointers to structures, so the engine settings are held
   //--- by value; they are fixed at init time and never mutate afterwards.
   SEngineCfg        m_eng;
   CSymbolCtx       *m_sym;
   CMoneyManager    *m_money;
   CBasket           m_basket;
   CSignal           m_signal;

   datetime          m_lastSignalBar;
   datetime          m_lastGridBar;
   double            m_baseVolume;     // volume of the first entry, frozen per basket
   int               m_wins;
   int               m_losses;
   double            m_realized;

   //+---------------------------------------------------------------+
   //| Convert a configured distance into price units.                |
   //+---------------------------------------------------------------+
   double            Scaled(const ENUM_QQX_SCALE mode,const double cfgValue,
                            const double atrMult,const double fixedPoints) const
     {
      switch(mode)
        {
         case QQX_SCALE_ATR:
           {
            double atr=m_signal.Atr();
            if(atr<=0.0) return(0.0);
            return(atr*atrMult);
           }
         case QQX_SCALE_FIXED:
            return(fixedPoints*m_sym.Point());

         case QQX_SCALE_PRICE:
         default:
           {
            //--- cfgValue is expressed in basis points of price, which is the
            //--- form the live record pins down most tightly (the grid spacing
            //--- measures 5.33 / 5.39 / 4.60 bp in 2024 / 2025 / 2026 while the
            //--- absolute spacing nearly doubled with the gold price)
            double ref=m_sym.Bid();
            if(ref<=0.0) return(0.0);
            return(ref*cfgValue/10000.0);
           }
        }
     }

   double            TargetDistance(void) const
     {
      return(Scaled(m_eng.tpScale,m_cfg.tpValue,m_eng.tpAtrMult,m_eng.tpFixedPoints));
     }

   double            StepDistance(void) const
     {
      return(Scaled(m_eng.stepScale,m_cfg.stepValue,m_eng.stepAtrMult,m_eng.stepFixedPoints));
     }

   //+---------------------------------------------------------------+
   //| True while the server clock sits inside this slot's session.   |
   //| Sessions never wrap midnight in the recovered schedule, but    |
   //| the wrap case is handled so Custom Mode users can define one.  |
   //+---------------------------------------------------------------+
   bool              InSession(const datetime now) const
     {
      int m=QQXMinuteOfDay(now);
      if(m_cfg.startMin<=m_cfg.endMin)
         return(m>=m_cfg.startMin && m<m_cfg.endMin);
      return(m>=m_cfg.startMin || m<m_cfg.endMin);
     }

   //+---------------------------------------------------------------+
   //| Bar-open detection on an arbitrary timeframe.                  |
   //+---------------------------------------------------------------+
   bool              IsNewBar(const ENUM_TIMEFRAMES tf,datetime &store)
     {
      datetime t=(datetime)SeriesInfoInteger(m_sym.Symbol(),tf,SERIES_LASTBAR_DATE);
      if(t==0) return(false);
      if(t==store) return(false);
      bool first=(store==0);
      store=t;
      return(!first);      // never fire on the very first tick after attach
     }

   bool              WantsBuy(void)  const { return(m_cfg.dir!=QQX_DIR_SELL_ONLY); }
   bool              WantsSell(void) const { return(m_cfg.dir!=QQX_DIR_BUY_ONLY);  }

   //+---------------------------------------------------------------+
   //| Exit evaluation for a live basket.                             |
   //+---------------------------------------------------------------+
   bool              CheckExit(const datetime now)
     {
      if(m_basket.Count()==0) return(false);

      double target=TargetDistance();
      double dist  =m_basket.ProfitDistance();

      //--- 1. primary exit: the volume weighted basket reached its target
      if(target>0.0 && dist>=target && !m_eng.useProfitTrail)
         return(Close(QQX_CLOSE_TARGET));

      //--- 2. profit trail: arm past the target, then close on a giveback.
      //---    This is what reproduces the long right tail of the live exit
      //---    distribution (median 1.05 USD per 0.01 lot, but a 95th
      //---    percentile of 4.20 and a maximum of 34.24).
      if(m_eng.useProfitTrail && target>0.0)
        {
         double arm=target*m_eng.trailStartMult;
         if(dist>=arm)
           {
            double peak=m_basket.PeakProfit();
            double now_=m_basket.Profit();
            if(peak>0.0 && now_<=peak*(1.0-m_eng.trailGiveback))
               return(Close(QQX_CLOSE_TRAIL));
           }
        }

      //--- 3. emergency basket stop
      if(m_eng.basketStopMult>0.0 && target>0.0)
        {
         if(dist<=-target*m_eng.basketStopMult)
            return(Close(QQX_CLOSE_STOP));
        }

      //--- 4. hard lifetime cap
      if(m_eng.maxBasketMinutes>0)
        {
         SBasketState st=m_basket.State();
         if(st.firstTime>0 && (now-st.firstTime)>=(m_eng.maxBasketMinutes*60))
            return(Close(QQX_CLOSE_SESSION));
        }

      //--- 5. weekend flat
      if(m_eng.closeOnFriday && QQXDayOfWeek(now)==5 &&
         QQXMinuteOfDay(now)>=m_eng.fridayCloseMin)
         return(Close(QQX_CLOSE_SESSION));

      return(false);
     }

   bool              Close(const ENUM_QQX_CLOSE_REASON reason)
     {
      double pnl=m_basket.Profit();
      if(!m_basket.CloseAll(reason)) return(false);
      m_realized+=pnl;
      if(pnl>=0.0) m_wins++; else m_losses++;
      m_baseVolume=0.0;
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Grid extension for a live basket.                              |
   //+---------------------------------------------------------------+
   void              CheckGrid(const datetime now)
     {
      if(m_basket.Count()==0) return;
      if(m_basket.Count()>=m_cfg.maxLevels) return;

      double step=StepDistance();
      if(step<=0.0) return;
      if(m_basket.AdverseFromLast()<step) return;

      SBasketState st=m_basket.State();
      if(m_eng.minSecondsBetweenEntries>0 &&
         (now-st.lastTime)<m_eng.minSecondsBetweenEntries) return;

      if(m_sym.SpreadPoints()>m_eng.maxSpreadPoints) return;

      //--- the grid ladder is always derived from the volume of the FIRST
      //--- position, so a terminal restart mid-basket resumes the same ladder
      double base=(m_baseVolume>0.0 ? m_baseVolume : st.firstVolume);
      double vol=m_money.GridVolume(base,m_basket.Count());
      if(vol<=0.0) return;

      m_basket.Open(st.isBuy,vol,
                    StringFormat("%s %s L%d",m_eng.commentPrefix,m_cfg.name,m_basket.Count()+1));
     }

   //+---------------------------------------------------------------+
   //| First entry of a new basket.                                   |
   //+---------------------------------------------------------------+
   void              CheckEntry(const datetime now)
     {
      if(m_basket.Count()>0) return;
      if(!InSession(now)) return;
      if(m_sym.SpreadPoints()>m_eng.maxSpreadPoints) return;
      if(m_eng.closeOnFriday && QQXDayOfWeek(now)==5 &&
         QQXMinuteOfDay(now)>=m_eng.fridayCloseMin) return;

      bool buy=false;
      if(WantsBuy() && m_signal.Allows(true))       buy=true;
      else if(WantsSell() && m_signal.Allows(false)) buy=false;
      else return;

      double vol=m_money.BaseVolume(m_cfg.riskShare);
      if(vol<=0.0) return;

      m_baseVolume=vol;
      m_basket.Open(buy,vol,StringFormat("%s %s L1",m_eng.commentPrefix,m_cfg.name));
     }

public:
                     CStrategy(void): m_sym(NULL),m_money(NULL),
                                      m_lastSignalBar(0),m_lastGridBar(0),m_baseVolume(0.0),
                                      m_wins(0),m_losses(0),m_realized(0.0) {}

   bool              Init(const SStrategyCfg &cfg,const SEngineCfg &eng,CSymbolCtx *sym,
                          CTrade *trade,CMoneyManager *money,const SSignalCfg &sigCfg)
     {
      m_cfg=cfg; m_eng=eng; m_sym=sym; m_money=money;
      m_basket.Init(sym,trade,cfg.magic);
      if(!m_signal.Init(sym.Symbol(),cfg.tf,sigCfg)) return(false);
      m_basket.Refresh();
      //--- adopt a basket that survived a restart
      if(m_basket.Count()>0) m_baseVolume=0.0;
      return(true);
     }

   void              Deinit(void) { m_signal.Release(); }

   //--- read-only surface for the dashboard
   string            Name(void)     const { return(m_cfg.name);      }
   bool              Enabled(void)  const { return(m_cfg.enabled);   }
   int               Positions(void)const { return(m_basket.Count());}
   double            Volume(void)   const { return(m_basket.Volume());}
   double            Floating(void) const { return(m_basket.Profit());}
   double            Realized(void) const { return(m_realized);      }
   int               Wins(void)     const { return(m_wins);          }
   int               Losses(void)   const { return(m_losses);        }
   ENUM_TIMEFRAMES   Timeframe(void)const { return(m_cfg.tf);        }
   ulong             Magic(void)    const { return(m_cfg.magic);     }
   string            SessionText(void) const
     {
      return(StringFormat("%02d:%02d-%02d:%02d",m_cfg.startMin/60,m_cfg.startMin%60,
                          m_cfg.endMin/60,m_cfg.endMin%60));
     }
   string            DirText(void) const
     {
      if(m_cfg.dir==QQX_DIR_BUY_ONLY)  return("BUY");
      if(m_cfg.dir==QQX_DIR_SELL_ONLY) return("SELL");
      return("BOTH");
     }

   //+---------------------------------------------------------------+
   //| Force every position of this slot out of the market.           |
   //+---------------------------------------------------------------+
   void              PanicClose(void)
     {
      if(m_basket.Count()>0) Close(QQX_CLOSE_PANIC);
     }

   //+---------------------------------------------------------------+
   //| Main per-tick entry point.                                     |
   //+---------------------------------------------------------------+
   void              Process(const datetime now,const bool tradingEnabled)
     {
      m_basket.Refresh();

      bool newGridBar  =IsNewBar(m_eng.gridTf,m_lastGridBar);
      bool newSignalBar=IsNewBar(m_cfg.tf,m_lastSignalBar);

      //--- Exits and grid extensions are evaluated on the grid cadence.
      //--- The live record shows 76% of all closes and 88% of all entries
      //--- landing exactly on second 00, i.e. the EA acts on bar opens
      //--- rather than continuously.
      if(m_basket.Count()>0 && newGridBar)
        {
         if(CheckExit(now)) return;
         CheckGrid(now);
         return;
        }

      if(!tradingEnabled) return;
      if(!m_cfg.enabled)  return;

      //--- A fresh basket may only start on a bar open of the slot timeframe.
      if(newSignalBar) CheckEntry(now);
     }
  };

#endif // __QQX_STRATEGY_MQH__
//+------------------------------------------------------------------+

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

   //--- ---------------- risk engineering (added after the 2026 backtest) ----
   //--- Diagnosis: 440 of 445 baskets were profitable; the 5 that were not
   //--- cost -31,540 against +20,236 of wins.  Every one of them ran deep,
   //--- ran long (59 to 671 hours) and kept averaging into a one-way move.
   //--- The settings below attack that tail directly.
   double            gridStepMult;      // geometric spacing: step x mult^level
   bool              gridTrendGuard;    // freeze adds against a higher-TF trend
   bool              volRegimeGate;     // block new baskets in a volatility spike

   int               recoveryLevel;     // depth at which the target is reduced
   double            recoveryHours;     // age at which the target is reduced
   double            recoveryTargetMult;// target multiplier once in recovery
   double            breakEvenHours;    // age at which break-even is accepted
   double            giveUpHours;       // age at which a bounded loss is accepted
   double            giveUpLossPct;     // that bound, in % of balance
   bool              pairDeRisk;        // shed legs in pairs while in recovery

   double            basketMaxLossPct;  // hard per-basket stop, % of balance
   double            minMarginLevel;    // block new risk below this margin level %
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
   //| Spacing required for the NEXT grid level.                      |
   //|                                                                |
   //| Constant spacing is what killed the 2026 backtest: at ~4.9 bp   |
   //| of price, eight levels cover barely 16 USD of gold.  Every      |
   //| catastrophic basket exhausted its levels inside that 16 USD     |
   //| and then rode the rest of a 50-800 USD move at full size.       |
   //| Widening geometrically buys back the range that matters -       |
   //| at x1.35 the same eight levels span roughly 48 USD.             |
   //+---------------------------------------------------------------+
   double            StepForLevel(const int level) const
     {
      double step=StepDistance();
      if(step<=0.0) return(0.0);
      double m=m_eng.gridStepMult;
      if(m<1.0) m=1.0;
      if(level<=1) return(step);
      return(step*MathPow(m,(double)(level-1)));
     }

   //+---------------------------------------------------------------+
   //| Age of the live basket, in hours.                              |
   //+---------------------------------------------------------------+
   double            BasketHours(const datetime now) const
     {
      SBasketState st=m_basket.State();
      if(st.count==0 || st.firstTime==0) return(0.0);
      return((double)(now-st.firstTime)/3600.0);
     }

   //+---------------------------------------------------------------+
   //| Recovery staging.                                              |
   //|                                                                |
   //| 0 = normal, 1 = reduced target, 2 = break-even, 3 = give up.    |
   //|                                                                |
   //| The backtest separates cleanly on age: 313 baskets closed       |
   //| within 8 hours with a 100% win rate, while every basket that    |
   //| destroyed the account had been open for more than 59.  Nothing  |
   //| good happens to a grid that is still open the next day, so the  |
   //| exit condition is relaxed in stages until it gets out.          |
   //+---------------------------------------------------------------+
   int               RecoveryStage(const datetime now,const bool accountBrake) const
     {
      if(m_basket.Count()==0) return(0);
      double age=BasketHours(now);

      if(m_eng.giveUpHours>0.0    && age>=m_eng.giveUpHours)    return(3);
      if(m_eng.breakEvenHours>0.0 && age>=m_eng.breakEvenHours) return(2);
      if(accountBrake) return(1);
      if(m_eng.recoveryHours>0.0 && age>=m_eng.recoveryHours)   return(1);
      if(m_eng.recoveryLevel>0 && m_basket.Count()>=m_eng.recoveryLevel) return(1);
      return(0);
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

   //+---------------------------------------------------------------+
   //| Free-margin guard.                                             |
   //|                                                                |
   //| This is the instrument that actually protects a grid account.   |
   //| In the 2026 backtest the single worst basket carried a floating |
   //| loss of 137% of balance and was liquidated by the broker at a   |
   //| margin level of -53%; the strategy itself never chose that      |
   //| exit.  Refusing new risk while margin is thin keeps the broker  |
   //| from picking the exit point.                                    |
   //+---------------------------------------------------------------+
   bool              MarginOk(void) const
     {
      if(m_eng.minMarginLevel<=0.0) return(true);
      if(AccountInfoDouble(ACCOUNT_MARGIN)<=0.0) return(true);   // nothing open
      double lvl=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(lvl<=0.0) return(true);
      return(lvl>=m_eng.minMarginLevel);
     }

   bool              WantsBuy(void)  const { return(m_cfg.dir!=QQX_DIR_SELL_ONLY); }
   bool              WantsSell(void) const { return(m_cfg.dir!=QQX_DIR_BUY_ONLY);  }

   //+---------------------------------------------------------------+
   //| Exit evaluation for a live basket.                             |
   //+---------------------------------------------------------------+
   bool              CheckExit(const datetime now,const bool accountBrake)
     {
      if(m_basket.Count()==0) return(false);

      double target =TargetDistance();
      double dist   =m_basket.ProfitDistance();
      double money  =m_basket.Profit();
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      int    stage  =RecoveryStage(now,accountBrake);

      //--- 1. hard per-basket stop.
      //---    Measured on the 2026 run: capping any single basket at 5% of
      //---    balance turns a -11,776 account into +17,736 and fires five
      //---    times in seven months.  Everything else in this function
      //---    exists to make it fire even less often than that.
      if(m_eng.basketMaxLossPct>0.0 && balance>0.0)
        {
         if(money<=-balance*m_eng.basketMaxLossPct/100.0)
            return(Close(QQX_CLOSE_STOP));
        }

      //--- 2. staged exit conditions
      if(stage>=3)
        {
         //--- release at a bounded loss rather than carry the position further
         double bound=balance*m_eng.giveUpLossPct/100.0;
         if(money>=-bound) return(Close(QQX_CLOSE_GIVEUP));
        }
      else if(stage==2)
        {
         //--- accept flat: costs covered is good enough for an aged basket
         if(money>=0.0) return(Close(QQX_CLOSE_BREAKEVEN));
        }
      else
        {
         double mult=(stage==1 ? m_eng.recoveryTargetMult : 1.0);
         if(mult<=0.0) mult=1.0;
         double eff=target*mult;

         if(m_eng.useProfitTrail && target>0.0)
           {
            //--- arm past the (possibly reduced) target, then close on giveback
            if(dist>=eff*m_eng.trailStartMult)
              {
               double peak=m_basket.PeakProfit();
               if(peak>0.0 && money<=peak*(1.0-m_eng.trailGiveback))
                  return(Close(QQX_CLOSE_TRAIL));
              }
           }
         else if(eff>0.0 && dist>=eff)
            return(Close(QQX_CLOSE_TARGET));
        }

      //--- 3. shed exposure in pairs while stuck.  This is the mechanism that
      //---    replaces stop losses: a losing leg leaves the book funded by
      //---    winning legs, so the basket shrinks without realising a loss.
      if(m_eng.pairDeRisk && stage>=1 && m_basket.Count()>=2)
        {
         //--- returning true only tells Process to stop here for this bar,
         //--- so the basket is not extended on the same bar it was trimmed
         if(m_basket.PartialDeRisk(0.0)>0) return(true);
        }

      //--- 4. legacy multiple-of-target stop, kept for compatibility
      if(m_eng.basketStopMult>0.0 && target>0.0 && dist<=-target*m_eng.basketStopMult)
         return(Close(QQX_CLOSE_STOP));

      //--- 5. hard lifetime cap
      if(m_eng.maxBasketMinutes>0)
        {
         SBasketState st=m_basket.State();
         if(st.firstTime>0 && (now-st.firstTime)>=(m_eng.maxBasketMinutes*60))
            return(Close(QQX_CLOSE_SESSION));
        }

      //--- 6. weekend flat
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
   void              CheckGrid(const datetime now,const bool accountBrake)
     {
      if(m_basket.Count()==0) return;
      if(m_basket.Count()>=m_cfg.maxLevels) return;

      //--- an aged or account-braked basket is being wound down, not extended
      if(accountBrake) return;
      if(RecoveryStage(now,accountBrake)>=2) return;

      SBasketState st=m_basket.State();

      //--- do not average into a higher-timeframe trend that is running
      //--- against the basket.  All five losing baskets of the 2026 run
      //--- share exactly this signature.
      if(m_eng.gridTrendGuard && !m_signal.AllowsGridAdd(st.isBuy)) return;

      //--- never deepen a grid on thin margin
      if(!MarginOk()) return;

      double step=StepForLevel(m_basket.Count());
      if(step<=0.0) return;
      if(m_basket.AdverseFromLast()<step) return;

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

      //--- a grid opened into a volatility spike is the one that runs out
      //--- of levels; sit that regime out instead
      if(m_eng.volRegimeGate && !m_signal.VolatilityOk()) return;
      if(!MarginOk()) return;

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
   void              Process(const datetime now,const bool tradingEnabled,
                             const bool accountBrake,const bool dirAllowed)
     {
      m_basket.Refresh();

      bool newGridBar  =IsNewBar(m_eng.gridTf,m_lastGridBar);
      bool newSignalBar=IsNewBar(m_cfg.tf,m_lastSignalBar);

      //--- Exits and grid extensions are evaluated on the grid cadence.
      //--- The live record shows 76% of all closes and 88% of all entries
      //--- landing exactly on second 00, i.e. the EA acts on bar opens
      //--- rather than continuously.
      if(m_basket.Count()>0)
        {
         //--- The hard basket stop is the one thing that must not wait for a
         //--- bar boundary - a fast move can travel a long way inside one M1
         //--- bar, and this stop exists precisely to bound that.
         if(m_eng.basketMaxLossPct>0.0)
           {
            double bal=AccountInfoDouble(ACCOUNT_BALANCE);
            if(bal>0.0 && m_basket.Profit()<=-bal*m_eng.basketMaxLossPct/100.0)
              {
               Close(QQX_CLOSE_STOP);
               return;
              }
           }
         if(!newGridBar) return;
         if(CheckExit(now,accountBrake)) return;
         CheckGrid(now,accountBrake);
         return;
        }

      if(!tradingEnabled) return;
      if(!m_cfg.enabled)  return;
      if(!dirAllowed)     return;

      //--- A fresh basket may only start on a bar open of the slot timeframe.
      if(newSignalBar) CheckEntry(now);
     }

   //--- direction of this slot, for the portfolio exposure cap
   bool              PrefersBuy(void) const { return(m_cfg.dir!=QQX_DIR_SELL_ONLY); }
   double            OpenLots(void)   const { return(m_basket.Volume()); }
   bool              OpenIsBuy(void)  const { return(m_basket.IsBuy()); }
   double            AgeHours(const datetime now) const { return(BasketHours(now)); }
   int               Stage(const datetime now) const { return(RecoveryStage(now,false)); }
  };

#endif // __QQX_STRATEGY_MQH__
//+------------------------------------------------------------------+

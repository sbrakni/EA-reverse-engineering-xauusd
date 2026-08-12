//+------------------------------------------------------------------+
//|                                                        Money.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  Position sizing.                                                 |
//|                                                                  |
//|  Reverse-engineering note                                         |
//|  ------------------------                                         |
//|  Across the 1466 live deals the traded volume tracks the account  |
//|  balance, not a constant.  The clearest evidence is the basket    |
//|  opened on 2026-07-29 22:18 while three 2000 USD deposits landed  |
//|  mid-basket at 22:33:55, 22:55:23 and 22:59:26.  The volume of    |
//|  every subsequent grid entry stepped up immediately afterwards:   |
//|                                                                   |
//|      before deposits   0.04   (balance  ~2.1k)                    |
//|      after  +2000      0.07   (balance  ~4.1k)                    |
//|      after  +4000      0.11   (balance  ~6.1k)                    |
//|      after  +6000      0.15   (balance  ~8.1k)                    |
//|                                                                   |
//|  i.e. the size is recomputed from the account state on every      |
//|  single order, giving ~0.0185 lots per 1000 units of balance.     |
//|  The median over the whole record is 0.0183 lots per 1000, so     |
//|  the default risk factor below is set to 0.02 lots / 1000.        |
//+------------------------------------------------------------------+
#ifndef __QQX_MONEY_MQH__
#define __QQX_MONEY_MQH__

#include "Defs.mqh"
#include "Sym.mqh"

//+------------------------------------------------------------------+
//| CMoneyManager                                                    |
//+------------------------------------------------------------------+
class CMoneyManager
  {
private:
   CSymbolCtx       *m_sym;
   ENUM_QQX_MM       m_mode;
   double            m_fixedLot;
   double            m_lotsPer1000;
   double            m_maxLot;
   double            m_gridMultiplier;

public:
                     CMoneyManager(void): m_sym(NULL),m_mode(QQX_MM_BALANCE),m_fixedLot(0.01),
                                          m_lotsPer1000(0.02),m_maxLot(10.0),m_gridMultiplier(1.0) {}

   void              Init(CSymbolCtx *sym,const ENUM_QQX_MM mode,const double fixedLot,
                          const double lotsPer1000,const double maxLot,const double gridMult)
     {
      m_sym            =sym;
      m_mode           =mode;
      m_fixedLot       =fixedLot;
      m_lotsPer1000    =lotsPer1000;
      m_maxLot         =maxLot;
      m_gridMultiplier =gridMult;
     }

   double            GridMultiplier(void) const { return(m_gridMultiplier); }

   //+---------------------------------------------------------------+
   //| Volume for the first position of a basket.                     |
   //|                                                                |
   //| "riskShare" lets an individual strategy run lighter or heavier  |
   //| than the global setting (1.0 = the global size).                |
   //+---------------------------------------------------------------+
   double            BaseVolume(const double riskShare=1.0) const
     {
      if(m_sym==NULL) return(0.0);
      double lot=m_fixedLot;

      if(m_mode==QQX_MM_BALANCE || m_mode==QQX_MM_EQUITY)
        {
         double capital=(m_mode==QQX_MM_BALANCE)
                        ? AccountInfoDouble(ACCOUNT_BALANCE)
                        : AccountInfoDouble(ACCOUNT_EQUITY);
         if(capital<0.0) capital=0.0;
         lot=capital/1000.0*m_lotsPer1000;
        }

      lot*=riskShare;
      if(lot>m_maxLot) lot=m_maxLot;
      return(m_sym.NormalizeVolume(lot));
     }

   //+---------------------------------------------------------------+
   //| Solve the base volume from the grid's own worst case.          |
   //|                                                                |
   //| This is the sizing mode that makes a grid safe, and it is the   |
   //| one lesson of the two blown backtests.  Instead of picking a    |
   //| lot and hoping, it asks: if this basket deploys ALL of its      |
   //| levels and price stops exactly at the last one, how much is     |
   //| floating?  Then it sizes so that number equals the budget.      |
   //|                                                                |
   //|   level i sits D_i away from the first entry, where the gaps    |
   //|   grow geometrically:  D_0 = 0,  D_i = D_(i-1) + step*m^(i-1)   |
   //|   worst-case loss     = SUM_i  lot_i * (D_last - D_i) * value   |
   //|                                                                |
   //| Everything is known at entry time, so the lot follows directly. |
   //| Nothing downstream then has to interfere with the grid - and    |
   //| interfering is exactly what strands a basket, because averaging |
   //| down IS the recovery mechanism.                                 |
   //|                                                                |
   //| A second ceiling applies: the fully deployed ladder must also   |
   //| fit inside a margin allowance.  On a small account margin, not  |
   //| the loss budget, is usually the binding constraint.             |
   //|                                                                |
   //| Returns 0 when the answer is below the broker's minimum volume. |
   //| That is a REFUSAL, not a clamp: rounding 0.002 up to 0.01 would |
   //| quietly multiply the intended risk by five, which is exactly    |
   //| how the second account was lost.                                |
   //+---------------------------------------------------------------+
   double            GridBudgetVolume(const int levels,const double step,
                                      const double stepMult,const double budgetMoney,
                                      const double marginAllowance=0.0) const
     {
      if(m_sym==NULL || levels<1 || step<=0.0 || budgetMoney<=0.0) return(0.0);

      double moneyPerPricePerLot=m_sym.MoneyForDistance(1.0,1.0);
      if(moneyPerPricePerLot<=0.0) return(0.0);

      double sm=(stepMult<1.0 ? 1.0 : stepMult);
      double gap=step;
      double dist[];
      ArrayResize(dist,levels);
      dist[0]=0.0;
      for(int i=1;i<levels;i++)
        {
         dist[i]=dist[i-1]+gap;
         gap*=sm;
        }

      //--- weight each level by its share of the volume ladder
      double lossFactor=0.0;
      double w=1.0;
      for(int i=0;i<levels;i++)
        {
         lossFactor+=w*(dist[levels-1]-dist[i]);
         w*=m_gridMultiplier;
        }
      if(lossFactor<=0.0) return(0.0);

      double lot=budgetMoney/(lossFactor*moneyPerPricePerLot);

      //--- margin ceiling for the fully deployed ladder
      if(marginAllowance>0.0)
        {
         double lev=(double)AccountInfoInteger(ACCOUNT_LEVERAGE);
         if(lev<=0.0) lev=100.0;
         double wsum=0.0,ww=1.0;
         for(int i=0;i<levels;i++) { wsum+=ww; ww*=m_gridMultiplier; }
         double per=wsum*m_sym.ContractSize()*m_sym.Bid()/lev;
         if(per>0.0)
           {
            double lotMargin=marginAllowance/per;
            if(lotMargin<lot) lot=lotMargin;
           }
        }

      if(lot>m_maxLot) lot=m_maxLot;
      //--- refuse rather than round up past the budget
      if(lot<m_sym.VolMin()) return(0.0);
      return(m_sym.NormalizeVolume(lot));
     }

   //+---------------------------------------------------------------+
   //| Worst-case floating loss of a fully deployed grid, in money.   |
   //| Used by the init report so the operator sees the number before |
   //| the strategy runs rather than after.                            |
   //+---------------------------------------------------------------+
   double            GridWorstCase(const double baseVolume,const int levels,
                                   const double step,const double stepMult,
                                   double &totalLots,double &spanCovered) const
     {
      totalLots=0.0; spanCovered=0.0;
      if(m_sym==NULL || levels<1 || step<=0.0 || baseVolume<=0.0) return(0.0);

      double sm=(stepMult<1.0 ? 1.0 : stepMult);
      double gap=step,d=0.0,loss=0.0,w=1.0;
      double dist[];
      ArrayResize(dist,levels);
      for(int i=0;i<levels;i++)
        {
         dist[i]=d;
         if(i<levels-1) { d+=gap; gap*=sm; }
        }
      spanCovered=dist[levels-1];
      for(int i=0;i<levels;i++)
        {
         double lot=m_sym.NormalizeVolume(baseVolume*w);
         totalLots+=lot;
         loss+=m_sym.MoneyForDistance(dist[levels-1]-dist[i],lot);
         w*=m_gridMultiplier;
        }
      return(loss);
     }

   //+---------------------------------------------------------------+
   //| Volume for grid entry number "level" (level 0 = first entry).  |
   //|                                                                |
   //| Reverse-engineering note: 269 of the 301 multi-entry baskets    |
   //| in the live record (89%) use a flat volume across the whole      |
   //| grid, and every basket after 2025-05 does, so the default        |
   //| multiplier is 1.0.  A martingale phase runs from 2024-08 to      |
   //| 2025-05, e.g. 0.02 / 0.03 / 0.04 / 0.06 / 0.09 / 0.14 on         |
   //| 2024-11-11 and 0.03 / 0.04 / 0.06 / 0.09 on 2024-08-16.          |
   //|                                                                  |
   //| The ladder compounds on the RAW base volume and is rounded only  |
   //| once, at the end:      lot(level) = round(base * m^level)        |
   //|                                                                  |
   //| Compounding on the already-rounded previous volume cannot        |
   //| reproduce those ladders for any multiplier at all - the 0.03 ->  |
   //| 0.04 step needs m < 1.5 while the 0.09 -> 0.14 step needs        |
   //| m >= 1.5.  Solving the raw-compounding form against every        |
   //| observed ladder pins the multiplier to [1.466, 1.468].           |
   //+---------------------------------------------------------------+
   double            GridVolume(const double baseVolume,const int level) const
     {
      if(m_sym==NULL) return(0.0);
      if(level<=0) return(m_sym.NormalizeVolume(baseVolume));

      double lot=baseVolume*MathPow(m_gridMultiplier,(double)level);
      if(lot>m_maxLot) lot=m_maxLot;
      return(m_sym.NormalizeVolume(lot));
     }
  };

#endif // __QQX_MONEY_MQH__
//+------------------------------------------------------------------+

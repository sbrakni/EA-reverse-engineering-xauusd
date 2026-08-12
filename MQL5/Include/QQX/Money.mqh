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

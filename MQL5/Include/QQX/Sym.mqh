//+------------------------------------------------------------------+
//|                                                          Sym.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  Symbol context: cached contract specification, live quotes,      |
//|  spread policing and volume normalisation.                        |
//+------------------------------------------------------------------+
#ifndef __QQX_SYM_MQH__
#define __QQX_SYM_MQH__

#include "Defs.mqh"

//+------------------------------------------------------------------+
//| CSymbolCtx                                                       |
//+------------------------------------------------------------------+
class CSymbolCtx
  {
private:
   string            m_symbol;
   int               m_digits;
   double            m_point;
   double            m_tickSize;
   double            m_tickValue;
   double            m_contract;
   double            m_volMin;
   double            m_volMax;
   double            m_volStep;
   int               m_stopLevel;
   int               m_freezeLevel;
   //--- live
   double            m_bid;
   double            m_ask;
   double            m_spreadPts;

public:
                     CSymbolCtx(void): m_symbol(""),m_digits(2),m_point(0.01),m_tickSize(0.01),
                                       m_tickValue(1.0),m_contract(100.0),m_volMin(0.01),
                                       m_volMax(100.0),m_volStep(0.01),m_stopLevel(0),
                                       m_freezeLevel(0),m_bid(0),m_ask(0),m_spreadPts(0) {}

   //--- accessors
   string            Symbol(void)      const { return(m_symbol);      }
   int               Digits(void)      const { return(m_digits);      }
   double            Point(void)       const { return(m_point);       }
   double            TickValue(void)   const { return(m_tickValue);   }
   double            TickSize(void)    const { return(m_tickSize);    }
   double            ContractSize(void)const { return(m_contract);    }
   double            VolMin(void)      const { return(m_volMin);      }
   double            VolMax(void)      const { return(m_volMax);      }
   double            VolStep(void)     const { return(m_volStep);     }
   double            Bid(void)         const { return(m_bid);         }
   double            Ask(void)         const { return(m_ask);         }
   double            SpreadPoints(void)const { return(m_spreadPts);   }
   int               StopLevel(void)   const { return(m_stopLevel);   }

   //+---------------------------------------------------------------+
   //| Load the contract specification once, at init.                 |
   //+---------------------------------------------------------------+
   bool              Init(const string sym)
     {
      m_symbol=sym;
      if(!SymbolSelect(m_symbol,true))
        {
         PrintFormat("QQX: symbol %s cannot be selected in Market Watch",m_symbol);
         return(false);
        }
      m_digits      =(int)SymbolInfoInteger(m_symbol,SYMBOL_DIGITS);
      m_point       =SymbolInfoDouble(m_symbol,SYMBOL_POINT);
      m_tickSize    =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_SIZE);
      m_tickValue   =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_TICK_VALUE);
      m_contract    =SymbolInfoDouble(m_symbol,SYMBOL_TRADE_CONTRACT_SIZE);
      m_volMin      =SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MIN);
      m_volMax      =SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_MAX);
      m_volStep     =SymbolInfoDouble(m_symbol,SYMBOL_VOLUME_STEP);
      m_stopLevel   =(int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_STOPS_LEVEL);
      m_freezeLevel =(int)SymbolInfoInteger(m_symbol,SYMBOL_TRADE_FREEZE_LEVEL);

      if(m_point<=0.0)     m_point=MathPow(10,-m_digits);
      if(m_tickSize<=0.0)  m_tickSize=m_point;
      if(m_volStep<=0.0)   m_volStep=0.01;
      if(m_contract<=0.0)  m_contract=100.0;
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Refresh live quotes.  Returns false when the tick is stale.     |
   //+---------------------------------------------------------------+
   bool              Refresh(void)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol,tick)) return(false);
      if(tick.bid<=0.0 || tick.ask<=0.0) return(false);
      m_bid=tick.bid;
      m_ask=tick.ask;
      m_spreadPts=(m_ask-m_bid)/m_point;
      return(true);
     }

   //+---------------------------------------------------------------+
   //| Price used to evaluate an open position of the given side.     |
   //| Buys are marked to Bid, sells to Ask.                          |
   //+---------------------------------------------------------------+
   double            ClosePrice(const bool isBuy) const
     {
      return(isBuy ? m_bid : m_ask);
     }

   //+---------------------------------------------------------------+
   //| Price paid when opening a position of the given side.           |
   //+---------------------------------------------------------------+
   double            OpenPrice(const bool isBuy) const
     {
      return(isBuy ? m_ask : m_bid);
     }

   //+---------------------------------------------------------------+
   //| Round a volume onto the broker's volume grid and clamp it.     |
   //+---------------------------------------------------------------+
   double            NormalizeVolume(const double vol) const
     {
      double v=vol;
      if(v<=0.0) return(0.0);
      v=MathRound(v/m_volStep)*m_volStep;
      if(v<m_volMin) v=m_volMin;
      if(v>m_volMax) v=m_volMax;
      //--- kill binary dust so the request volume compares equal broker-side
      int vdig=0;
      double st=m_volStep;
      while(st<1.0 && vdig<8) { st*=10.0; vdig++; }
      return(NormalizeDouble(v,vdig));
     }

   //+---------------------------------------------------------------+
   //| Round a price onto the broker's tick grid.                      |
   //+---------------------------------------------------------------+
   double            NormalizePrice(const double price) const
     {
      if(m_tickSize<=0.0) return(NormalizeDouble(price,m_digits));
      return(NormalizeDouble(MathRound(price/m_tickSize)*m_tickSize,m_digits));
     }

   //+---------------------------------------------------------------+
   //| Money value of a price move of "distance" on "volume" lots.    |
   //|                                                                |
   //| Uses the broker supplied tick value so the engine behaves the  |
   //| same on 2-digit and 3-digit gold feeds and on accounts whose   |
   //| deposit currency is not USD.                                   |
   //+---------------------------------------------------------------+
   double            MoneyForDistance(const double distance,const double volume) const
     {
      if(m_tickSize<=0.0) return(0.0);
      return(distance/m_tickSize*m_tickValue*volume);
     }

   //+---------------------------------------------------------------+
   //| Inverse of MoneyForDistance: price distance that yields the     |
   //| requested money amount on the requested volume.                |
   //+---------------------------------------------------------------+
   double            DistanceForMoney(const double money,const double volume) const
     {
      if(volume<=0.0 || m_tickValue<=0.0) return(0.0);
      return(money/(m_tickValue*volume)*m_tickSize);
     }
  };

#endif // __QQX_SYM_MQH__
//+------------------------------------------------------------------+

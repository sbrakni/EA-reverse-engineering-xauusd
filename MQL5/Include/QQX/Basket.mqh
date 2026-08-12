//+------------------------------------------------------------------+
//|                                                       Basket.mqh |
//|              Quantum Queen X - reverse engineered reconstruction |
//|                                                                  |
//|  A basket is the set of live positions belonging to one strategy  |
//|  slot.  It is opened, extended and closed as a single unit.       |
//|                                                                  |
//|  Reverse-engineering note                                         |
//|  ------------------------                                         |
//|  The live record leaves no doubt that positions are managed in    |
//|  baskets rather than individually:                                |
//|    * 87% of the multi-position groups close on one timestamp;     |
//|    * inside those groups individual deals close in profit AND in  |
//|      loss simultaneously (2026-08-11 03:45 closed +10.80, +6.66,  |
//|      +2.36 and -0.02 together), which only happens when the exit  |
//|      decision is taken on the aggregate, not per position;        |
//|    * no fixed take-profit distance exists - the distance from the |
//|      volume weighted entry to the exit ranges from 0.3 to 34 USD, |
//|      so the exit is a monitored condition, not a resting order.   |
//+------------------------------------------------------------------+
#ifndef __QQX_BASKET_MQH__
#define __QQX_BASKET_MQH__

#include <Trade\Trade.mqh>
#include "Defs.mqh"
#include "Sym.mqh"

//+------------------------------------------------------------------+
//| Aggregate state of one basket.                                   |
//+------------------------------------------------------------------+
struct SBasketState
  {
   int               count;         // live positions
   double            volume;        // total lots
   double            firstVolume;   // lots of the earliest position (grid base)
   double            avgPrice;      // volume weighted entry
   double            lastPrice;     // entry price of the most recent position
   double            worstPrice;    // most adverse entry price in the basket
   datetime          firstTime;     // open time of the first position
   datetime          lastTime;      // open time of the most recent position
   double            profit;        // floating money incl. swap and commission
   bool              isBuy;
  };

//+------------------------------------------------------------------+
//| CBasket                                                          |
//+------------------------------------------------------------------+
class CBasket
  {
private:
   CSymbolCtx       *m_sym;
   CTrade           *m_trade;
   ulong             m_magic;
   SBasketState      m_st;
   //--- peak floating profit since the basket was opened, used by the
   //--- profit trail; reset whenever the basket goes flat
   double            m_peakProfit;

   void              Reset(void)
     {
      m_st.count=0;
      m_st.volume=0.0;
      m_st.firstVolume=0.0;
      m_st.avgPrice=0.0;
      m_st.lastPrice=0.0;
      m_st.worstPrice=0.0;
      m_st.firstTime=0;
      m_st.lastTime=0;
      m_st.profit=0.0;
      m_st.isBuy=true;
     }

public:
                     CBasket(void): m_sym(NULL),m_trade(NULL),m_magic(0),m_peakProfit(0.0) { Reset(); }

   void              Init(CSymbolCtx *sym,CTrade *trade,const ulong magic)
     {
      m_sym=sym; m_trade=trade; m_magic=magic;
      Reset();
     }

   SBasketState      State(void) const { return(m_st); }
   int               Count(void)  const { return(m_st.count);  }
   double            Volume(void) const { return(m_st.volume); }
   double            Profit(void) const { return(m_st.profit); }
   bool              IsBuy(void)  const { return(m_st.isBuy);  }
   double            PeakProfit(void) const { return(m_peakProfit); }
   ulong             Magic(void)  const { return(m_magic);     }

   //+---------------------------------------------------------------+
   //| Re-read the terminal's position list and rebuild the aggregate.|
   //+---------------------------------------------------------------+
   void              Refresh(void)
     {
      Reset();
      double weighted=0.0;
      string sym=(m_sym!=NULL ? m_sym.Symbol() : _Symbol);

      int total=PositionsTotal();
      for(int i=total-1;i>=0;i--)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;

         double vol  =PositionGetDouble(POSITION_VOLUME);
         double price=PositionGetDouble(POSITION_PRICE_OPEN);
         datetime t  =(datetime)PositionGetInteger(POSITION_TIME);
         bool isBuy  =((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);

         if(m_st.count==0)
           {
            m_st.isBuy=isBuy;
            m_st.firstTime=t;
            m_st.lastTime=t;
            m_st.firstVolume=vol;
            m_st.lastPrice=price;
            m_st.worstPrice=price;
           }
         else
           {
            if(t<m_st.firstTime) { m_st.firstTime=t; m_st.firstVolume=vol; }
            if(t>m_st.lastTime) { m_st.lastTime=t; m_st.lastPrice=price; }
            if(isBuy)  { if(price<m_st.worstPrice) m_st.worstPrice=price; }
            else       { if(price>m_st.worstPrice) m_st.worstPrice=price; }
           }

         m_st.count++;
         m_st.volume+=vol;
         weighted+=price*vol;
         m_st.profit+=PositionGetDouble(POSITION_PROFIT)
                     +PositionGetDouble(POSITION_SWAP);
        }

      if(m_st.count>0 && m_st.volume>0.0)
         m_st.avgPrice=weighted/m_st.volume;
      else
         m_peakProfit=0.0;                    // flat -> forget the old peak

      if(m_st.count>0 && m_st.profit>m_peakProfit)
         m_peakProfit=m_st.profit;
     }

   //+---------------------------------------------------------------+
   //| Signed distance, in price, from the volume weighted entry to    |
   //| the current mark.  Positive means the basket is in profit.      |
   //| This is the quantity the take-profit is expressed in, because   |
   //| it is scale free: the live record shows the same distribution   |
   //| of it whether the basket holds one position or sixteen.         |
   //+---------------------------------------------------------------+
   double            ProfitDistance(void) const
     {
      if(m_st.count==0 || m_sym==NULL) return(0.0);
      double mark=m_sym.ClosePrice(m_st.isBuy);
      return(m_st.isBuy ? (mark-m_st.avgPrice) : (m_st.avgPrice-mark));
     }

   //+---------------------------------------------------------------+
   //| Adverse excursion, in price, from the most recent entry.        |
   //| The grid step is measured against this.                         |
   //+---------------------------------------------------------------+
   double            AdverseFromLast(void) const
     {
      if(m_st.count==0 || m_sym==NULL) return(0.0);
      double mark=m_sym.OpenPrice(m_st.isBuy);
      return(m_st.isBuy ? (m_st.lastPrice-mark) : (mark-m_st.lastPrice));
     }

   //+---------------------------------------------------------------+
   //| Open a new position for this basket.                           |
   //+---------------------------------------------------------------+
   bool              Open(const bool isBuy,const double volume,const string comment)
     {
      if(m_sym==NULL || m_trade==NULL) return(false);
      if(volume<=0.0) return(false);

      m_trade.SetExpertMagicNumber(m_magic);
      bool ok=false;
      string sym=m_sym.Symbol();

      if(isBuy) ok=m_trade.Buy (volume,sym,0.0,0.0,0.0,comment);
      else      ok=m_trade.Sell(volume,sym,0.0,0.0,0.0,comment);

      if(!ok)
         PrintFormat("QQX[%I64u]: %s %.2f failed - retcode %d (%s)",
                     m_magic,(isBuy?"BUY":"SELL"),volume,
                     m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
      else
         Refresh();

      return(ok);
     }

   //+---------------------------------------------------------------+
   //| Close every position of this basket.                           |
   //|                                                                |
   //| Positions are closed newest-first, which is the order the live  |
   //| record shows (the 23:42:03 / :07 / :09 chains on 2026-08-10).   |
   //| Returns true when the basket is flat afterwards.                |
   //+---------------------------------------------------------------+
   bool              CloseAll(const ENUM_QQX_CLOSE_REASON reason)
     {
      if(m_sym==NULL || m_trade==NULL) return(false);
      string sym=m_sym.Symbol();
      bool allOk=true;

      for(int attempt=0;attempt<3;attempt++)
        {
         bool anyLeft=false;
         for(int i=PositionsTotal()-1;i>=0;i--)
           {
            ulong ticket=PositionGetTicket(i);
            if(ticket==0) continue;
            if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
            if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;

            anyLeft=true;
            m_trade.SetExpertMagicNumber(m_magic);
            if(!m_trade.PositionClose(ticket))
              {
               allOk=false;
               PrintFormat("QQX[%I64u]: close #%I64u failed - retcode %d (%s)",
                           m_magic,ticket,m_trade.ResultRetcode(),
                           m_trade.ResultRetcodeDescription());
              }
           }
         if(!anyLeft) break;
        }

      Refresh();
      if(m_st.count==0)
        {
         m_peakProfit=0.0;
         PrintFormat("QQX[%I64u]: basket closed (%s)",m_magic,ReasonToString(reason));
        }
      return(m_st.count==0 && allOk);
     }

   //+---------------------------------------------------------------+
   //| Partial de-risk ("pair close").                                |
   //|                                                                |
   //| Takes the deepest-losing leg and pairs it with as many of the   |
   //| best legs as are needed for the subset to net >= minNet, then   |
   //| closes that subset.  A stuck basket therefore sheds exposure    |
   //| a leg at a time WITHOUT realising a loss, instead of sitting    |
   //| at full size waiting for one all-or-nothing exit.               |
   //|                                                                |
   //| This is the mechanism that keeps the hard basket stop from      |
   //| firing: in the 2026 backtest every catastrophic basket held     |
   //| its full leg count for 59 to 671 hours.                         |
   //|                                                                |
   //| Returns the number of positions closed.                        |
   //+---------------------------------------------------------------+
   int               PartialDeRisk(const double minNet)
     {
      if(m_sym==NULL || m_trade==NULL) return(0);
      if(m_st.count<2) return(0);

      string sym=m_sym.Symbol();
      ulong  tickets[];
      double pnl[];
      int    n=0;

      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong ticket=PositionGetTicket(i);
         if(ticket==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=sym) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC)!=m_magic) continue;
         ArrayResize(tickets,n+1);
         ArrayResize(pnl,n+1);
         tickets[n]=ticket;
         pnl[n]=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         n++;
        }
      if(n<2) return(0);

      //--- ascending by profit: worst first, best last
      for(int a=0;a<n-1;a++)
         for(int b=a+1;b<n;b++)
            if(pnl[b]<pnl[a])
              {
               double tp=pnl[a]; pnl[a]=pnl[b]; pnl[b]=tp;
               ulong  tt=tickets[a]; tickets[a]=tickets[b]; tickets[b]=tt;
              }

      if(pnl[0]>=0.0) return(0);            // nothing under water, nothing to pair

      //--- greedily add the richest winners until the pair nets out
      double sum=pnl[0];
      int    take=1;
      for(int i=n-1;i>0 && sum<minNet;i--)
        {
         if(pnl[i]<=0.0) break;             // no winners left to fund the pair
         sum+=pnl[i];
         take++;
        }
      if(sum<minNet || take<2) return(0);

      //--- close the loser plus the winners that funded it
      int closed=0;
      m_trade.SetExpertMagicNumber(m_magic);
      if(m_trade.PositionClose(tickets[0])) closed++;
      double acc=pnl[0];
      for(int i=n-1;i>0 && acc<minNet;i--)
        {
         if(pnl[i]<=0.0) break;
         acc+=pnl[i];
         if(m_trade.PositionClose(tickets[i])) closed++;
        }

      if(closed>0)
        {
         Refresh();
         PrintFormat("QQX[%I64u]: pair-closed %d legs for %.2f, %d remain",
                     m_magic,closed,sum,m_st.count);
        }
      return(closed);
     }

   static string     ReasonToString(const ENUM_QQX_CLOSE_REASON r)
     {
      switch(r)
        {
         case QQX_CLOSE_TARGET : return("target");
         case QQX_CLOSE_TRAIL  : return("profit trail");
         case QQX_CLOSE_SESSION: return("session expiry");
         case QQX_CLOSE_STOP   : return("basket stop");
         case QQX_CLOSE_PANIC  : return("account protection");
         case QQX_CLOSE_BREAKEVEN: return("break-even release");
         case QQX_CLOSE_GIVEUP : return("bounded give-up");
         case QQX_CLOSE_PARTIAL: return("pair de-risk");
        }
      return("none");
     }
  };

#endif // __QQX_BASKET_MQH__
//+------------------------------------------------------------------+

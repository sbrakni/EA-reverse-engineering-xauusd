import pandas as pd, numpy as np
SRC="positions.csv"

def load():
    raw = pd.read_csv(SRC, sep=';', encoding='utf-8-sig', header=None, skiprows=1,
                      names=['otime','type','ovol','sym','oprice','cvol','ctime','cprice','comm','swap','profit'])
    bal = raw[raw['type']=='Balance'].copy()
    bal['otime']=pd.to_datetime(bal['otime'], format='%Y.%m.%d %H:%M:%S')
    bal['profit']=pd.to_numeric(bal['profit'])
    d = raw[raw['type'].isin(['Buy','Sell'])].copy()
    d['otime']=pd.to_datetime(d['otime'], format='%Y.%m.%d %H:%M:%S')
    d['ctime']=pd.to_datetime(d['ctime'], format='%Y.%m.%d %H:%M:%S')
    for c in ['ovol','oprice','cvol','cprice','comm','swap','profit']:
        d[c]=pd.to_numeric(d[c], errors='coerce').fillna(0.0)
    d=d.sort_values('otime').reset_index(drop=True)
    d['net']=d.profit+d.comm+d.swap
    d['pts']=np.where(d.type=='Buy', d.cprice-d.oprice, d.oprice-d.cprice)
    d['dur']=(d.ctime-d.otime).dt.total_seconds()/60
    # baskets
    events=[]
    for i,r in d.iterrows(): events.append((r.otime,'o',i)); events.append((r.ctime,'c',i))
    events.sort(key=lambda x:(x[0], 0 if x[1]=='c' else 1))
    open_set=set(); bidmap={}; bid=0
    for t,k,i in events:
        if k=='o':
            if not open_set: bid+=1
            open_set.add(i); bidmap[i]=bid
        else: open_set.discard(i)
    d['basket']=d.index.map(bidmap)
    d['isfirst']= ~d.basket.duplicated()
    d['seq']=d.groupby('basket').cumcount()
    d['hour']=d.otime.dt.hour; d['minute']=d.otime.dt.minute
    d['hm']=d.otime.dt.strftime('%H:%M')
    return d, bal

def tf_of(minute):
    """smallest MT5 timeframe whose bar boundary matches this minute"""
    for tf in [1,2,3,4,5,6,10,12,15,20,30,60]:
        if minute % tf == 0: return tf
    return 1

def tfset(minute):
    return [tf for tf in [2,3,4,5,6,10,12,15,20,30,60] if minute % tf==0]

import pandas as pd, numpy as np
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 400)
SRC="positions.csv"
raw = pd.read_csv(SRC, sep=';', encoding='utf-8-sig', header=None, skiprows=1,
                  names=['otime','type','ovol','sym','oprice','cvol','ctime','cprice','comm','swap','profit'])
d = raw[raw['type'].isin(['Buy','Sell'])].copy()
d['otime']=pd.to_datetime(d['otime'], format='%Y.%m.%d %H:%M:%S')
d['ctime']=pd.to_datetime(d['ctime'], format='%Y.%m.%d %H:%M:%S')
for c in ['ovol','oprice','cvol','cprice','comm','swap','profit']:
    d[c]=pd.to_numeric(d[c], errors='coerce').fillna(0.0)
d=d.sort_values('otime').reset_index(drop=True); d['net']=d.profit+d.comm+d.swap
d['pts']=np.where(d.type=='Buy', d.cprice-d.oprice, d.oprice-d.cprice)

# rebuild baskets
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

print("=== SINGLE-TRADE BASKETS: price move (TP distance) ===")
s=d[d.basket.map(d.basket.value_counts())==1]
print("count:", len(s))
print(s.pts.describe(percentiles=[.05,.1,.25,.5,.75,.9,.95,.99]))
print("\nhistogram of pts for single trades:")
print(pd.cut(s.pts, bins=[-100,-10,-5,-2,-1,0,.5,1,1.5,2,2.5,3,4,5,7.5,10,15,20,50,300]).value_counts().sort_index().to_string())
print("\nsingle trades closed at second==0:", (s.ctime.dt.second==0).mean())

# TP distance for trades whose close second != 0 (likely real TP order fills)
print("\n=== trades with non-zero close seconds (TP order fills?) ===")
nz=d[d.ctime.dt.second!=0]
print("count", len(nz), " pts describe:"); print(nz.pts.describe(percentiles=[.05,.25,.5,.75,.95]))

# Basket-level: weighted avg entry vs common exit price
print("\n\n=== BASKET LEVEL: distance from weighted-avg entry to exit ===")
rows=[]
for bk,grp in d.groupby('basket'):
    lots=grp.ovol.values; op=grp.oprice.values; cp=grp.cprice.values
    wavg=(op*lots).sum()/lots.sum()
    exitp = (cp*lots).sum()/lots.sum()
    dirn = 1 if grp.type.iloc[0]=='Buy' else -1
    dist = (exitp-wavg)*dirn
    rows.append(dict(basket=bk,n=len(grp),lots=lots.sum(),wavg=wavg,exitp=exitp,dist=dist,
                     net=grp.net.sum(), gross=grp.profit.sum(),
                     t0=grp.otime.min(), t1=grp.ctime.max(),
                     nclose=grp.ctime.nunique(), sec0=(grp.ctime.dt.second==0).all(),
                     dirn='Buy' if dirn==1 else 'Sell'))
B=pd.DataFrame(rows)
print(B.dist.describe(percentiles=[.05,.1,.25,.5,.75,.9,.95]))
print("\ndist histogram:")
print(pd.cut(B.dist, bins=[-30,-10,-5,-2,-1,-.5,0,.5,1,1.5,2,2.5,3,4,5,7.5,10,20,300]).value_counts().sort_index().to_string())

print("\n=== dist by basket size ===")
print(B.groupby('n').dist.describe()[['count','25%','50%','75%']].to_string())

print("\n=== how many distinct close timestamps per basket ===")
print(B.nclose.value_counts().sort_index().to_dict())

# Are all positions in a basket closed at same time?
B['allsame']=B.nclose==1
print("baskets closed all-at-once:", B.allsame.mean())

print("\n=== GROSS profit per basket / total lots*100 (i.e. $ per 0.01 lot) ===")
B['pl']=B.gross/(B.lots*100)
print(B.pl.describe(percentiles=[.05,.25,.5,.75,.95]))

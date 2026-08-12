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
d=d.sort_values('otime').reset_index(drop=True)
d['net']=d.profit+d.comm+d.swap

# ---- build baskets: sequential scan; a basket = set of same-direction trades whose
# lifetimes overlap (a new basket starts when no open positions remain)
events=[]
for i,r in d.iterrows():
    events.append((r.otime,'o',i)); events.append((r.ctime,'c',i))
events.sort(key=lambda x:(x[0], 0 if x[1]=='c' else 1))
open_set=set(); basket_id={}; bid=0; cur=[]
for t,k,i in events:
    if k=='o':
        if not open_set: bid+=1
        open_set.add(i); basket_id[i]=bid
    else:
        open_set.discard(i)
d['basket']=d.index.map(basket_id)
print("num baskets:", d.basket.nunique())

g=d.groupby('basket')
b=g.agg(n=('ovol','size'), dirs=('type', lambda s: '/'.join(sorted(set(s)))),
        t0=('otime','min'), t1=('ctime','max'), lots=('ovol','sum'),
        lot_first=('ovol','first'), lot_last=('ovol','last'),
        p_first=('oprice','first'), p_last=('oprice','last'),
        pmin=('oprice','min'), pmax=('oprice','max'),
        net=('net','sum'), gross=('profit','sum'))
b['dur']=(b.t1-b.t0).dt.total_seconds()/60
b['span']=b.pmax-b.pmin
print("\n=== basket size distribution ===")
print(b.n.value_counts().sort_index().to_string())
print("\n=== mixed-direction baskets ===")
print(b.dirs.value_counts().to_dict())
print("\n=== basket net profit ===")
print(b.net.describe(percentiles=[.01,.05,.25,.5,.75,.95,.99]))
print("losing baskets:", (b.net<0).sum(), "of", len(b))
print("\n=== worst 15 baskets ===")
print(b.nsmallest(15,'net')[['n','dirs','t0','t1','lots','net','span']].to_string())

print("\n=== basket net vs total lots  (profit per 0.01 lot) ===")
b['net_per_001']=b.net/(b.lots*100)
print(b[b.net>0].net_per_001.describe(percentiles=[.05,.25,.5,.75,.95]))

# ---- Grid spacing: within multi-trade baskets, look at consecutive entry price gaps
print("\n\n=== GRID STEP: gap between consecutive entries in a basket (same dir) ===")
gaps=[]
for bk,grp in d.groupby('basket'):
    grp=grp.sort_values('otime')
    if len(grp)<2: continue
    pr=grp.oprice.values; ty=grp.type.values; tm=grp.otime.values
    for j in range(1,len(pr)):
        step = (pr[j-1]-pr[j]) if ty[j]=='Buy' else (pr[j]-pr[j-1])  # positive = adverse (averaging down)
        gaps.append(dict(basket=bk, idx=j, step=step, dtmin=(tm[j]-tm[j-1])/np.timedelta64(1,'m'),
                         dir=ty[j], lot_prev=grp.ovol.values[j-1], lot=grp.ovol.values[j]))
G=pd.DataFrame(gaps)
print(G.step.describe(percentiles=[.05,.1,.25,.5,.75,.9,.95]))
print("\nfraction adverse (step>0):", round((G.step>0).mean(),3))
print("\nstep histogram (0.5 buckets):")
print(pd.cut(G.step, bins=np.arange(-8,20,1)).value_counts().sort_index().to_string())
print("\n=== time gap between consecutive entries (min) ===")
print(G.dtmin.value_counts().sort_index().head(30).to_string())

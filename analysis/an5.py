import pandas as pd, numpy as np
from common import load
pd.set_option('display.width',250); pd.set_option('display.max_rows',600)
d,bal=load()

# logical basket = same direction + close times within 15s of each other (chained)
d=d.sort_values(['type','ctime']).reset_index(drop=True)
grp=[]; gid=0; prev=None; prevdir=None
for i,r in d.iterrows():
    if prev is None or r.type!=prevdir or (r.ctime-prev).total_seconds()>15:
        gid+=1
    grp.append(gid); prev=r.ctime; prevdir=r.type
d['lb']=grp
d=d.sort_values('otime').reset_index(drop=True)
print("logical baskets:", d.lb.nunique())
sz=d.groupby('lb').size()
print("size dist:", sz.value_counts().sort_index().to_dict())

rows=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime')
    lots=g.ovol.values; op=g.oprice.values
    wavg=(op*lots).sum()/lots.sum()
    dirn=1 if g.type.iloc[0]=='Buy' else -1
    exitp=g.cprice.iloc[-1]
    rows.append(dict(lb=k,n=len(g),dir=g.type.iloc[0],t0=g.otime.min(),t1=g.ctime.max(),
        h=g.otime.min().hour, m=g.otime.min().minute,
        lots=lots.sum(), l0=lots[0], lmax=lots.max(), lmin=lots.min(),
        wavg=wavg, exitp=exitp, dist=(exitp-wavg)*dirn,
        span=(op.max()-op.min()), net=g.net.sum(), gross=g.profit.sum(),
        dur=(g.ctime.max()-g.otime.min()).total_seconds()/60))
B=pd.DataFrame(rows)
print("\n=== TP distance from weighted avg (logical baskets) ===")
print(B.dist.describe(percentiles=[.05,.25,.5,.75,.95]))
print("\n=== TP dist by first-entry hour ===")
print(B.groupby('h').dist.describe()[['count','min','25%','50%','75%','max']].to_string())
print("\n=== TP dist by basket size n ===")
print(B.groupby('n').dist.describe()[['count','25%','50%','75%']].to_string())

print("\n=== lots within a basket: all equal? ===")
print("all-equal baskets:", (B.lmax==B.lmin).mean())
print(B[B.lmax!=B.lmin][['n','dir','t0','l0','lmin','lmax','lots']].head(30).to_string())

print("\n=== first-entry HH:MM x direction for logical baskets ===")
B['hm']=B.t0.dt.strftime('%H:%M')
print(pd.crosstab(B.h, B.dir).to_string())
print("\nminute mod tf per hour:")
for h in sorted(B.h.unique()):
    s=B[B.h==h]
    mods={f'M{tf}':round((s.m%tf==0).mean(),2) for tf in [5,6,10,15,20,30]}
    print(f'  h={h:02d} n={len(s):4d} {mods} dirs={s["dir"].value_counts().to_dict()}')
B.to_csv('baskets.csv', index=False)
d.to_csv('trades.csv', index=False)

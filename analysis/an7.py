import pandas as pd, numpy as np
from common import load
pd.set_option('display.width',260); pd.set_option('display.max_rows',900)
d,bal=load()
d=d.sort_values(['type','ctime']).reset_index(drop=True)
gid=0; grp=[]; prev=None; prevdir=None
for i,r in d.iterrows():
    if prev is None or r.type!=prevdir or (r.ctime-prev).total_seconds()>15: gid+=1
    grp.append(gid); prev=r.ctime; prevdir=r.type
d['lb']=grp; d=d.sort_values('otime').reset_index(drop=True)

# ---------- session window boundaries ----------
print("=== ENTRY time-of-day: full HH:MM list per direction-locked session ===")
d['tod']=d.otime.dt.hour*60+d.otime.dt.minute
print("min/max time-of-day per hour-block:")
for h in sorted(d.hour.unique()):
    s=d[d.hour==h]
    print(f"  h={h:02d} n={len(s):4d} minutes={sorted(s.minute.unique())}")

# ---------- TP behaviour ----------
rows=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime')
    lots=g.ovol.values; dirn=1 if g.type.iloc[0]=='Buy' else -1
    wavg=(g.oprice.values*lots).sum()/lots.sum()
    wexit=(g.cprice.values*lots).sum()/lots.sum()
    rows.append(dict(lb=k,n=len(g),dir=g.type.iloc[0],t0=g.otime.min(),t1=g.ctime.max(),
        h0=g.otime.min().hour, m0=g.otime.min().minute, tod=g.otime.min().hour*60+g.otime.min().minute,
        lots=lots.sum(), dist=(wexit-wavg)*dirn, gross=g.profit.sum(),
        dur=(g.ctime.max()-g.otime.min()).total_seconds()/60,
        cprice_spread=g.cprice.max()-g.cprice.min(), sec0=(g.ctime.dt.second==0).mean(),
        year=g.otime.min().year))
B=pd.DataFrame(rows)

print("\n=== TP dist per session-hour, over time (does it change with EA version?) ===")
print(B.groupby([B.t0.dt.year, 'h0']).dist.median().unstack().round(2).to_string())

print("\n=== close-price spread within basket (0 => single bulk close) ===")
print(B.cprice_spread.describe(percentiles=[.5,.75,.9,.95]))
print("baskets with identical close price:", (B.cprice_spread==0).mean())
print("multi-trade baskets with identical close price:", (B[B.n>1].cprice_spread==0).mean())

print("\n=== duration per session-hour (min) ===")
print(B.groupby('h0').dur.describe()[['count','25%','50%','75%','max']].to_string())

print("\n=== BASKETS that lost money (exit logic other than TP) ===")
L=B[B.dist<0.05].sort_values('dist')
print(L[['n','dir','t0','t1','lots','dist','gross','dur']].to_string())

print("\n=== MAX concurrent open positions over time ===")
ev=[]
for _,r in d.iterrows(): ev.append((r.otime,1)); ev.append((r.ctime,-1))
ev.sort()
cur=0; mx=0; hist=[]
for t,x in ev:
    cur+=x; mx=max(mx,cur); hist.append((t,cur))
print("max concurrent:", mx)
H=pd.DataFrame(hist, columns=['t','n'])
print("concurrent by year (max):"); print(H.groupby(H.t.dt.year).n.max().to_string())
print("\ndistribution of concurrent counts (unique times):")
print(H.n.value_counts().sort_index().head(20).to_string())

print("\n=== trades per day / per session ===")
d['date']=d.otime.dt.date
print("trades per day:", d.groupby('date').size().describe(percentiles=[.5,.9,.99]).to_string())
print("distinct trading days:", d.date.nunique())
span=(d.otime.max()-d.otime.min()).days
print("calendar span days:", span, " approx weekdays:", round(span*5/7))

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
rows=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime'); lots=g.ovol.values; dirn=1 if g.type.iloc[0]=='Buy' else -1
    wavg=(g.oprice.values*lots).sum()/lots.sum(); wexit=(g.cprice.values*lots).sum()/lots.sum()
    rows.append(dict(lb=k,n=len(g),dir=g.type.iloc[0],t0=g.otime.min(),t1=g.ctime.max(),
        h0=g.otime.min().hour, lots=lots.sum(), dist=(wexit-wavg)*dirn,
        dur=(g.ctime.max()-g.otime.min()).total_seconds()/60, ch=g.ctime.max().hour,
        date=g.otime.min().date(), dow=g.otime.min().dayofweek))
B=pd.DataFrame(rows)

print("=== EXIT hour distribution ===")
print(B.ch.value_counts().sort_index().to_string())
print("\n=== positive dist: smallest values (is there a min profit floor?) ===")
p=B[B.dist>0].dist.sort_values()
print(p.head(40).round(3).tolist())
print("\ndist percentiles:", np.percentile(B.dist,[1,2,5,10,20,30,40,50,60,70,80,90,95,99]).round(3))

print("\n=== duration buckets vs dist ===")
B['dbuck']=pd.cut(B.dur, [0,1.1,2.1,5,15,60,240,1e6], include_lowest=True)
print(B.groupby('dbuck', observed=True).dist.describe()[['count','25%','50%','75%']].to_string())

print("\n=== DAY OF WEEK (basket starts) ===")
print(B.dow.value_counts().sort_index().to_string())
print("\n=== trading-day frequency by month ===")
m=B.groupby(B.t0.dt.to_period('M')).agg(baskets=('lb','size'), days=('date','nunique'))
print(m.to_string())

print("\n=== days with trades: which sessions fire together on a day? ===")
piv=B.pivot_table(index='date', columns='h0', values='lb', aggfunc='count').fillna(0)
print("sessions active per day (count of distinct h0):")
print((piv>0).sum(axis=1).value_counts().sort_index().to_string())

print("\n=== correlation: does session h=22/23 fire on the same days as h=19? ===")
c=(piv>0).astype(int)
print(c.corr().round(2).to_string())

print("\n=== consecutive-day pattern / gaps between trading days ===")
dates=sorted(B.date.unique())
gaps=[(pd.Timestamp(dates[i+1])-pd.Timestamp(dates[i])).days for i in range(len(dates)-1)]
print(pd.Series(gaps).value_counts().sort_index().head(15).to_string())

print("\n=== dist for n=1 baskets, by duration==1min ===")
one=B[(B.n==1)]
print("dur<=1min:", one[one.dur<=1.01].dist.describe()[['count','25%','50%','75%']].to_dict())
print("dur>1min :", one[one.dur>1.01].dist.describe()[['count','25%','50%','75%']].to_dict())

print("\n=== BIGGEST baskets detail ===")
for k in B.nlargest(4,'n').lb:
    g=d[d.lb==k].sort_values('otime')
    print(f"\n--- basket {k}  n={len(g)} {g.type.iloc[0]} ---")
    print(g[['otime','ovol','oprice','ctime','cprice','profit']].to_string())

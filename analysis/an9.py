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

def sess(h,m,dirn):
    if h==3 or h==4:                      return 'S1_AsiaBuy_M15'
    if h in (8,9) and dirn=='Sell':       return 'S2_AsiaSell_M12'
    if h in (8,) and dirn=='Buy':         return 'S3_LonBuy_M30'
    if h in (9,10,11,12,13) and dirn=='Buy': return 'S4_LonBuy_M12'
    if h==18:                             return 'S5_PreNYSell_M20'
    if h in (19,20):                      return 'S6_NYBuy_M15'
    if h==21 and dirn=='Sell':            return 'S7_NYCloseSell_M30'
    if h==22 and dirn=='Sell':            return 'S10_LateSell_M30'
    if h==23 and dirn=='Sell':            return 'S11_LateSell_M10'
    if h in (22,23) and dirn=='Buy':      return 'S8_LateBuy_M4' if m%4==0 else 'S9_LateBuy_M6'
    return 'OTHER'

rows=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime').reset_index(drop=True)
    lots=g.ovol.values; dirn=1 if g.type.iloc[0]=='Buy' else -1
    wavg=(g.oprice.values*lots).sum()/lots.sum(); wexit=(g.cprice.values*lots).sum()/lots.sum()
    steps=[(g.oprice[j-1]-g.oprice[j])*dirn for j in range(1,len(g))]
    rows.append(dict(lb=k,n=len(g),dir=g.type.iloc[0],t0=g.otime.min(),
        s=sess(g.otime.min().hour, g.otime.min().minute, g.type.iloc[0]),
        lots=lots.sum(), dist=(wexit-wavg)*dirn, price=g.oprice.iloc[0],
        step_med=np.median(steps) if steps else np.nan,
        dur=(g.ctime.max()-g.otime.min()).total_seconds()/60,
        year=g.otime.min().year, gross=g.profit.sum()))
B=pd.DataFrame(rows)
print("=== PER-STRATEGY SUMMARY ===")
t=B.groupby('s').agg(baskets=('lb','size'), maxlvl=('n','max'), med_lvl=('n','median'),
    tp_med=('dist','median'), tp_q25=('dist',lambda x:x.quantile(.25)), tp_q75=('dist',lambda x:x.quantile(.75)),
    step_med=('step_med','median'), dur_med=('dur','median'), gross=('gross','sum'),
    winrate=('gross',lambda x:(x>0).mean()))
print(t.round(3).to_string())
print("\ntotal baskets classified:", (B.s!='OTHER').sum(), "of", len(B))
print("\n=== relative to price (TP/price *10000 = bp) ===")
B['tp_bp']=B.dist/B.price*10000; B['st_bp']=B.step_med/B.price*10000
print(B.groupby(['year']).agg(tp_bp=('tp_bp','median'), st_bp=('st_bp','median'),
      tp_abs=('dist','median'), st_abs=('step_med','median'), price=('price','median')).round(3).to_string())
print("\n=== ratio TP / grid step ===")
r=(B.dist/B.step_med).replace([np.inf,-np.inf],np.nan).dropna()
print(r.describe(percentiles=[.25,.5,.75]).round(3))
print("\n=== max levels per strategy & distribution ===")
print(B.groupby('s').n.apply(lambda x: x.value_counts().sort_index().to_dict()).to_string())
print("\n=== yearly performance ===")
print(B.groupby('year').agg(n=('lb','size'), gross=('gross','sum'), wr=('gross',lambda x:(x>0).mean())).round(3).to_string())
B.to_csv('baskets_final.csv',index=False)

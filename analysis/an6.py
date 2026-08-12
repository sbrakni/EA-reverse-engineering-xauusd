import pandas as pd, numpy as np
from common import load
pd.set_option('display.width',250); pd.set_option('display.max_rows',900)
d,bal=load()
d=d.sort_values(['type','ctime']).reset_index(drop=True)
gid=0; grp=[]; prev=None; prevdir=None
for i,r in d.iterrows():
    if prev is None or r.type!=prevdir or (r.ctime-prev).total_seconds()>15: gid+=1
    grp.append(gid); prev=r.ctime; prevdir=r.type
d['lb']=grp; d=d.sort_values('otime').reset_index(drop=True)

print("=== verify x1.5 martingale hypothesis ===")
bad=0; ok=0; equal=0
for k,g in d.groupby('lb'):
    g=g.sort_values('otime'); L=list(g.ovol.values)
    if len(L)<2: continue
    if len(set(L))==1: equal+=1; continue
    pred=[L[0]]
    for j in range(1,len(L)): pred.append(round(pred[-1]*1.5+1e-9,2))
    if np.allclose(pred,L,atol=0.0051): ok+=1
    else:
        bad+=1
        if bad<=15: print("  MISMATCH", g.otime.min(), "actual",L,"pred",pred)
print(f"  constant-lot baskets: {equal}, x1.5 match: {ok}, mismatch: {bad}")

print("\n=== periods with multiplier != 1 ===")
mm=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime'); L=list(g.ovol.values)
    if len(L)>=2: mm.append((g.otime.min(), len(set(L))>1))
M=pd.DataFrame(mm, columns=['t','multi'])
M['ym']=M.t.dt.to_period('M')
print(M.groupby('ym').multi.agg(['size','sum']).to_string())

print("\n\n=== GRID STEP analysis (adverse distance from LAST entry) ===")
rows=[]
for k,g in d.groupby('lb'):
    g=g.sort_values('otime').reset_index(drop=True)
    if len(g)<2: continue
    dirn = 1 if g.type.iloc[0]=='Buy' else -1
    for j in range(1,len(g)):
        rows.append(dict(lb=k,j=j,n=len(g),h=g.otime.iloc[0].hour,dir=g.type.iloc[0],
            step_prev=(g.oprice.iloc[j-1]-g.oprice.iloc[j])*dirn,
            step_first=(g.oprice.iloc[0]-g.oprice.iloc[j])*dirn,
            step_worst=(g.oprice.iloc[:j].min()-g.oprice.iloc[j])*dirn if dirn==1 else (g.oprice.iloc[j]-g.oprice.iloc[:j].max())*dirn,
            dt=(g.otime.iloc[j]-g.otime.iloc[j-1]).total_seconds()/60))
S=pd.DataFrame(rows)
print("step from previous entry:"); print(S.step_prev.describe(percentiles=[.05,.1,.25,.5,.75,.9,.95]))
print("\nstep from WORST entry so far (should be >= grid step if grid measured vs last):")
print(S.step_worst.describe(percentiles=[.05,.1,.25,.5,.75,.9,.95]))
print("\nstep_prev by level j:")
print(S.groupby('j').step_prev.describe()[['count','min','25%','50%','75%','max']].to_string())
print("\nstep_prev by hour:")
print(S.groupby('h').step_prev.describe()[['count','min','25%','50%','75%','max']].to_string())
print("\nstep_prev histogram 0.25 buckets (0..6):")
print(pd.cut(S.step_prev, bins=np.arange(0,6.25,0.25)).value_counts().sort_index().to_string())
print("\n=== max levels reached ===")
print(d.groupby('lb').size().value_counts().sort_index().to_string())
S.to_csv('steps.csv',index=False)

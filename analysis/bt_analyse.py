import pandas as pd, numpy as np
pd.set_option('display.width',250); pd.set_option('display.max_rows',400)
df=pd.read_csv('bt_deals.csv', parse_dates=['time'])
df['slot']=df.comment.str.extract(r'QQX (\d\d)')
df['lvl']=df.comment.str.extract(r'L(\d+)$').astype(float)

# --- simulate the position book: 'in' deals carry the slot, 'out' deals do not.
# My EA closes a whole basket at once, so an out-cluster (same type, within 30s)
# consumes exactly the open positions of ONE slot with the matching direction.
book={}   # slot -> list of dicts
baskets=[]
i=0
rows=df.to_dict('records')
while i < len(rows):
    r=rows[i]
    if r['dir']=='in':
        s=r['slot']
        book.setdefault(s,[]).append(dict(t=r['time'],price=r['price'],vol=r['vol'],
                                          side=r['type'],comm=r['comm']))
        i+=1; continue
    # out cluster
    j=i; cl=[]
    while j<len(rows) and rows[j]['dir']=='out' and rows[j]['type']==r['type'] \
          and (rows[j]['time']-r['time']).total_seconds()<=30:
        cl.append(rows[j]); j+=1
    # the closing deal type is the OPPOSITE of the position side
    side='buy' if r['type']=='sell' else 'sell'
    cands=[s for s,v in book.items() if len(v)==len(cl) and v and v[0]['side']==side]
    if not cands:
        cands=[s for s,v in book.items() if v and v[0]['side']==side and len(v)>=len(cl)]
    if cands:
        # prefer the slot whose open volume matches the closed volume
        cv=sum(c['vol'] for c in cl)
        best=min(cands,key=lambda s: abs(sum(p['vol'] for p in book[s][:len(cl)])-cv))
        legs=book[best][:len(cl)]
        book[best]=book[best][len(cl):]
        lots=sum(p['vol'] for p in legs)
        wavg=sum(p['price']*p['vol'] for p in legs)/lots
        sgn=1 if side=='buy' else -1
        xp=sum(c['price']*c['vol'] for c in cl)/sum(c['vol'] for c in cl)
        baskets.append(dict(slot=best,n=len(legs),side=side,
            t0=min(p['t'] for p in legs),t1=cl[-1]['time'],lots=lots,
            wavg=wavg,exitp=xp,dist=(xp-wavg)*sgn,
            profit=sum(c['profit'] for c in cl),
            cost=sum(c['comm'] for c in cl)+sum(p['comm'] for p in legs),
            span=max(p['price'] for p in legs)-min(p['price'] for p in legs)))
    i=j
B=pd.DataFrame(baskets)
B['net']=B.profit+B.cost
B['dur']=(B.t1-B.t0).dt.total_seconds()/3600
B['h0']=B.t0.dt.hour
print(f"reconstructed {len(B)} baskets, {B.n.sum()} legs of {len(df[df.dir=='in'])} entries")
print("net sum:",round(B.net.sum(),2))
print()
print("=== BY SLOT ===")
g=B.groupby('slot').agg(baskets=('net','size'),legs=('n','sum'),net=('net','sum'),
    wins=('net',lambda x:(x>0).sum()),worst=('net','min'),maxlvl=('n','max'),
    gp=('net',lambda x:x[x>0].sum()),gl=('net',lambda x:x[x<0].sum()),
    meddur=('dur','median'),maxdur=('dur','max'))
g['wr']=(g.wins/g.baskets*100).round(1)
g['PF']=(g.gp/-g.gl).round(2)
print(g.round(2).to_string())
print()
print("=== LOSS CONCENTRATION ===")
L=B.sort_values('net')
print("worst 20 baskets:")
print(L.head(20)[['slot','n','side','t0','t1','lots','net','span','dur']].to_string())
print()
tot=B.net.sum(); loss=B[B.net<0].net.sum()
print(f"total net {tot:.0f} | gross loss {loss:.0f} | gross win {B[B.net>0].net.sum():.0f}")
for k in [1,3,5,10,20]:
    print(f"  worst {k:2d} baskets = {L.head(k).net.sum():9.0f}  ({L.head(k).net.sum()/loss*100:5.1f}% of all losses)")
print()
print("=== BY GRID DEPTH ===")
print(B.groupby('n').agg(cnt=('net','size'),net=('net','sum'),avg=('net','mean'),
      worst=('net','min'),wr=('net',lambda x:(x>0).mean()*100)).round(1).to_string())
print()
print("=== BY DURATION BUCKET (hours) ===")
B['db']=pd.cut(B.dur,[0,0.5,1,2,4,8,16,100],include_lowest=True)
print(B.groupby('db',observed=True).agg(cnt=('net','size'),net=('net','sum'),
      avg=('net','mean'),worst=('net','min'),wr=('net',lambda x:(x>0).mean()*100)).round(1).to_string())
print()
print("=== ADVERSE SPAN (max grid range) vs OUTCOME ===")
B['sb']=pd.cut(B.span,[-.01,5,10,20,40,80,1000])
print(B.groupby('sb',observed=True).agg(cnt=('net','size'),net=('net','sum'),
      avg=('net','mean'),worst=('net','min')).round(1).to_string())
B.to_csv('bt_baskets.csv',index=False)

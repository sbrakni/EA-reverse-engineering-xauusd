import pandas as pd, numpy as np
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 500)
SRC="positions.csv"
raw = pd.read_csv(SRC, sep=';', encoding='utf-8-sig', header=None, skiprows=1,
                  names=['otime','type','ovol','sym','oprice','cvol','ctime','cprice','comm','swap','profit'])
d = raw[raw['type'].isin(['Buy','Sell'])].copy()
d['otime']=pd.to_datetime(d['otime'], format='%Y.%m.%d %H:%M:%S')
d['ctime']=pd.to_datetime(d['ctime'], format='%Y.%m.%d %H:%M:%S')
for c in ['ovol','oprice','cvol','cprice','comm','swap','profit']:
    d[c]=pd.to_numeric(d[c], errors='coerce').fillna(0.0)
d=d.sort_values('otime').reset_index(drop=True); d['net']=d.profit+d.comm+d.swap
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

f=d[d.isfirst].copy()
f['hm']=f.otime.dt.strftime('%H:%M')
print("=== FIRST-ENTRY-OF-BASKET  HH:MM frequency (top 45) ===")
print(f.hm.value_counts().head(45).to_string())
print("\ntotal first entries:", len(f))
print("\n=== first-entry minute mod 15 ===")
print(f.otime.dt.minute.mod(15).value_counts().sort_index().to_dict())
print("=== first-entry minute mod 5 ===")
print(f.otime.dt.minute.mod(5).value_counts().sort_index().to_dict())
print("=== first-entry minute mod 30 ===")
print(f.otime.dt.minute.mod(30).value_counts().sort_index().to_dict())

print("\n=== ALL entries HH:MM top 40 ===")
d['hm']=d.otime.dt.strftime('%H:%M')
print(d.hm.value_counts().head(40).to_string())

print("\n=== first-entry hour by direction ===")
print(pd.crosstab(f.otime.dt.hour, f.type).to_string())

# DST detection: hour distribution per year-half
f['mon']=f.otime.dt.month; f['yr']=f.otime.dt.year
f['dst']=f.mon.between(4,10)
print("\n=== hour dist: summer(Apr-Oct) vs winter ===")
print(pd.crosstab(f.otime.dt.hour, f.dst).to_string())

print("\n=== SELL baskets: first entry HH:MM ===")
print(f[f.type=='Sell'].hm.value_counts().head(30).to_string())
print("\n=== SELL by hour ===")
print(f[f.type=='Sell'].otime.dt.hour.value_counts().sort_index().to_dict())
print("\n=== SELL by date (which months) ===")
print(f[f.type=='Sell'].otime.dt.to_period('M').value_counts().sort_index().to_string())

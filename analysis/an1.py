import pandas as pd, numpy as np
pd.set_option('display.width', 200); pd.set_option('display.max_rows', 300)

SRC="positions.csv"
raw = pd.read_csv(SRC, sep=';', encoding='utf-8-sig', header=None, skiprows=1,
                  names=['otime','type','ovol','sym','oprice','cvol','ctime','cprice','comm','swap','profit'])
bal = raw[raw['type']=='Balance']
print("=== BALANCE OPS ===")
print(bal[['otime','type','profit']].to_string())

d = raw[raw['type'].isin(['Buy','Sell'])].copy()
d['otime']=pd.to_datetime(d['otime'], format='%Y.%m.%d %H:%M:%S')
d['ctime']=pd.to_datetime(d['ctime'], format='%Y.%m.%d %H:%M:%S')
for c in ['ovol','oprice','cvol','cprice','comm','swap','profit']:
    d[c]=pd.to_numeric(d[c], errors='coerce').fillna(0.0)
d=d.sort_values('otime').reset_index(drop=True)
print("\n=== OVERVIEW ===")
print("trades:", len(d), " first:", d.otime.min(), " last:", d.otime.max())
print("symbols:", d.sym.unique())
print("types:", d.type.value_counts().to_dict())
print("volumes:", d.ovol.value_counts().to_dict())
print("gross profit sum:", round(d.profit.sum(),2), "comm:", round(d.comm.sum(),2), "swap:", round(d.swap.sum(),2))
print("net:", round((d.profit+d.comm+d.swap).sum(),2))
print("win rate:", round((d.profit+d.comm+d.swap > 0).mean()*100,2))

# per-lot pip value: profit / (points * lots).  XAUUSD 100 oz/lot -> $1 per 0.01 move per 0.01 lot? check
d['pts'] = np.where(d.type=='Buy', d.cprice-d.oprice, d.oprice-d.cprice)
d['ppl'] = d.profit/(d.pts*d.ovol*100)
print("\nprofit/(pts*lots*100) ratio (should be ~1.0):", d.ppl.replace([np.inf,-np.inf],np.nan).dropna().describe())

print("\n=== COMMISSION per lot ===")
print((d.comm/d.ovol).describe())

# duration
d['dur']=(d.ctime-d.otime).dt.total_seconds()/60
print("\n=== DURATION (min) ===")
print(d.dur.describe(percentiles=[.1,.25,.5,.75,.9,.95,.99]))

print("\n=== ENTRY SECONDS ===")
print(d.otime.dt.second.value_counts().head())
print("=== EXIT SECONDS (0 vs non-0) ===")
print((d.ctime.dt.second==0).value_counts())

print("\n=== ENTRY MINUTE mod 5 / mod 15 ===")
print("min%5:", d.otime.dt.minute.mod(5).value_counts().sort_index().to_dict())
print("min%15:", d.otime.dt.minute.mod(15).value_counts().sort_index().to_dict())

print("\n=== ENTRY HOUR distribution ===")
print(d.otime.dt.hour.value_counts().sort_index().to_string())

print("\n=== ENTRY WEEKDAY ===")
print(d.otime.dt.dayofweek.value_counts().sort_index().to_dict())

print("\n=== LOT vs DATE ===")
d['ym']=d.otime.dt.to_period('M')
print(d.groupby('ym', observed=True).agg(n=('ovol','size'), lot_min=('ovol','min'), lot_max=('ovol','max'),
      net=('profit','sum')).to_string())

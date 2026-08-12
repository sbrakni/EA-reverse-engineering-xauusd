"""
bt_extract.py - turn an MT5 HTML strategy-tester report into bt_deals.csv.

    python3 bt_extract.py ReportTester.html
"""
import html
import re
import sys

import pandas as pd

src_path = sys.argv[1] if len(sys.argv) > 1 else "ReportTester.html"


def read(path):
    for enc in ("utf-16", "utf-8"):
        try:
            s = open(path, encoding=enc, errors="replace").read()
        except Exception:
            continue
        if "<html" in s.lower():
            return s
    return open(path, encoding="utf-8", errors="replace").read()


def cells(row):
    return [html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
            for c in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", row, flags=re.S)]


def num(s):
    s = str(s).replace(" ", "").replace("\xa0", "").replace(" ", "")
    try:
        return float(s)
    except ValueError:
        return 0.0


src = read(src_path)
rows = re.findall(r"<tr[^>]*>(.*?)</tr>", src, flags=re.S)

# the deals table starts after the row whose header carries both Direction and Profit
start = 0
for i, r in enumerate(rows):
    c = cells(r)
    j = " ".join(c)
    if len(c) > 6 and ("Direction" in j or "Entry" in j) and "Profit" in j:
        start = i + 1
        break

cols = ["time", "deal", "sym", "type", "dir", "vol", "price",
        "order", "comm", "swap", "profit", "bal", "comment"]
data = []
for r in rows[start:]:
    c = cells(r)
    if len(c) < 12:
        continue
    if not re.match(r"\d{4}\.\d{2}\.\d{2}", c[0]):
        continue
    data.append(c[:13])

df = pd.DataFrame(data, columns=cols)
for c in ["vol", "price", "comm", "swap", "profit", "bal"]:
    df[c] = df[c].map(num)
df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M:%S")
df = df[df.sym.str.contains("XAU", na=False)].reset_index(drop=True)
df.to_csv("bt_deals.csv", index=False)
print(f"wrote bt_deals.csv: {len(df)} deals, "
      f"{(df.dir == 'in').sum()} entries / {(df.dir == 'out').sum()} exits")

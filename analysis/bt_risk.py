"""
bt_risk.py - margin survival and stop-loss counterfactuals on the backtest.

Answers the two questions the optimisation rests on:

  1. what position size survives the drawdowns this strategy needs to survive?
  2. would a per-basket stop loss have helped, or would it have cut the winners?

    cd analysis && python3 bt_analyse.py && python3 bt_risk.py

Requires bt_deals.csv (from bt_extract.py). Reconstructs baskets the same way
bt_analyse.py does, but keeps the individual leg prices so the deepest provable
floating drawdown of each basket can be recovered.
"""
import numpy as np
import pandas as pd

LEVERAGE = 100.0        # as configured in the report
STOP_OUT = 50.0         # broker stop-out level, %
CONTRACT = 100.0        # oz per lot

d = pd.read_csv("bt_deals.csv", parse_dates=["time"])
d["slot"] = d.comment.str.extract(r"QQX (\d\d)")

# ---------------------------------------------------------------- baskets
book, baskets, i = {}, [], 0
rows = d.to_dict("records")
while i < len(rows):
    r = rows[i]
    if r["dir"] == "in":
        book.setdefault(r["slot"], []).append(
            dict(t=r["time"], price=r["price"], vol=r["vol"],
                 side=r["type"], comm=r["comm"], bal=r["bal"]))
        i += 1
        continue

    j, cl = i, []
    while (j < len(rows) and rows[j]["dir"] == "out"
           and rows[j]["type"] == r["type"]
           and (rows[j]["time"] - r["time"]).total_seconds() <= 30):
        cl.append(rows[j])
        j += 1

    side = "buy" if r["type"] == "sell" else "sell"
    cands = [s for s, v in book.items() if len(v) == len(cl) and v and v[0]["side"] == side]
    if not cands:
        cands = [s for s, v in book.items() if v and v[0]["side"] == side and len(v) >= len(cl)]
    if cands:
        cv = sum(c["vol"] for c in cl)
        best = min(cands, key=lambda s: abs(sum(p["vol"] for p in book[s][:len(cl)]) - cv))
        legs, book[best] = book[best][:len(cl)], book[best][len(cl):]
        baskets.append(dict(
            slot=best, n=len(legs), side=side,
            t0=min(p["t"] for p in legs), t1=cl[-1]["time"],
            prices=[p["price"] for p in legs], vols=[p["vol"] for p in legs],
            bal0=legs[0]["bal"],
            exitp=sum(c["price"] * c["vol"] for c in cl) / sum(c["vol"] for c in cl),
            net=sum(c["profit"] for c in cl) + sum(c["comm"] for c in cl)
                + sum(p["comm"] for p in legs)))
    i = j

B = pd.DataFrame(baskets)
B["lots"] = B.vols.map(sum)
B["dur"] = (B.t1 - B.t0).dt.total_seconds() / 3600


def deepest_known(r):
    """Floating loss at the deepest point the price is PROVEN to have reached:
    the most adverse fill in the grid (or the exit, for a single-leg basket)."""
    pr, vo = np.array(r.prices), np.array(r.vols)
    p = (pr.min() if r.side == "buy" else pr.max()) if len(pr) > 1 else r.exitp
    sgn = 1 if r.side == "buy" else -1
    return float(((p - pr) * sgn * vo * CONTRACT).sum())


B["mae"] = B.apply(deepest_known, axis=1)
B["mae_pct"] = -B.mae / B.bal0 * 100

print(f"{len(B)} baskets, {(B.net > 0).sum()} profitable "
      f"({(B.net > 0).mean() * 100:.1f}%), total {B.net.sum():.0f}\n")

# ------------------------------------------------------- margin survival
print("=== position size vs margin survival ===")
print("what worst margin level the account reaches at each size\n")
print(f"{'lots/1000':>10} {'worst margin level':>20}   outcome")
for scale in [1.00, 0.75, 0.50, 0.35, 0.25, 0.20]:
    worst, when = 1e9, None
    for _, r in B.iterrows():
        lots = r.lots * scale
        if lots <= 0:
            continue
        margin = lots * CONTRACT * float(np.mean(r.prices)) / LEVERAGE
        lvl = (r.bal0 + r.mae * scale) / margin * 100
        if lvl < worst:
            worst, when = lvl, r.t0.date()
    print(f"{0.01 * scale:10.4f} {worst:19.1f}%   "
          f"{'SURVIVES' if worst > STOP_OUT else 'BLOWS UP'}  ({when})")

# --------------------------------------------------- stop-loss cost/benefit
print("\n=== would a per-basket stop have helped? ===")
print("a grid earns by recovering, so a drawdown stop cuts winners too\n")
print(f"{'stop %':>7} {'fires':>7} {'…that WON':>11} {'resulting total':>17}")
for cap in [1, 2, 3, 5, 7, 10]:
    hit = B.mae_pct >= cap
    v = np.where(hit, -B.bal0 * cap / 100, B.net)
    print(f"{cap:7.1f} {hit.sum():7d} {(hit & (B.net > 0)).sum():11d} {v.sum():17.0f}")
print(f"{'none':>7} {'-':>7} {'-':>11} {B.net.sum():17.0f}")

print("\n=== baskets that recovered from the deepest drawdowns ===")
deep = B[B.mae_pct >= 20].nlargest(8, "mae_pct")
for _, r in deep.iterrows():
    span = max(r.prices) - min(r.prices)
    print(f"  {str(r.t0.date()):>10}  {int(r.n):2d} legs  {r.dur:6.0f}h  "
          f"span {span:6.1f}  peak float {-r.mae_pct:6.1f}% of balance  "
          f"-> {r.net:+9.0f}")

B.drop(columns=["prices", "vols"]).to_csv("bt_risk.csv", index=False)

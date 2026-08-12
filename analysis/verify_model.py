"""
verify_model.py - regression test for the reverse-engineered model.

Re-derives every claim the EA's defaults rest on, straight from positions.csv,
and asserts that the numbers hard-coded in
MQL5/Experts/QuantumQueenX/QuantumQueenX.mq5 still match the data.

    cd analysis && python3 verify_model.py

Exit code 0 = the shipped constants are consistent with the trade record.
"""
import os
import re
import sys

import numpy as np
import pandas as pd

from common import load

EA = os.path.join(os.path.dirname(__file__), "..", "MQL5", "Experts",
                  "QuantumQueenX", "QuantumQueenX.mq5")

failures = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  -- ' + detail) if detail else ''}")
    if not ok:
        failures.append(name)


def baskets(d):
    """Logical basket = same direction, closes chained within 15 s."""
    d = d.sort_values(["type", "ctime"]).reset_index(drop=True)
    gid, out, prev, prevdir = 0, [], None, None
    for _, r in d.iterrows():
        if prev is None or r.type != prevdir or (r.ctime - prev).total_seconds() > 15:
            gid += 1
        out.append(gid)
        prev, prevdir = r.ctime, r.type
    d["lb"] = out
    return d.sort_values("otime").reset_index(drop=True)


def session_of(h, m, side):
    if h in (3, 4):                             return "01"
    if h in (8, 9) and side == "Sell":          return "02"
    if h == 8 and side == "Buy":                return "03"
    if h in (9, 10, 11, 12, 13):                return "04"
    if h == 18:                                 return "05"
    if h in (19, 20):                           return "06"
    if h == 21 and side == "Sell":              return "07"
    if h == 22 and side == "Sell":              return "10"
    if h == 23 and side == "Sell":              return "11"
    if h in (22, 23) and side == "Buy":         return "08" if m % 4 == 0 else "09"
    return "??"


def main():
    d, bal = load()
    print(f"loaded {len(d)} deals, {d.otime.min().date()} .. {d.otime.max().date()}\n")

    # ---------------------------------------------------------------- contract
    print("contract specification")
    ratio = d.profit / (np.where(d.type == "Buy", d.cprice - d.oprice,
                                 d.oprice - d.cprice) * d.ovol * 100)
    ratio = ratio.replace([np.inf, -np.inf], np.nan).dropna()
    check("profit == move x lots x 100  (100 oz contract, 2-digit feed)",
          np.allclose(ratio, 1.0, atol=1e-6), f"max deviation {abs(ratio - 1).max():.2e}")

    # ------------------------------------------------------------ bar-open EAs
    print("\nexecution cadence")
    sec0 = (d.otime.dt.second == 0).mean()
    check("entries land on bar opens (>85% at second 00)", sec0 > 0.85, f"{sec0:.1%}")
    csec0 = (d.ctime.dt.second == 0).mean()
    check("exits are monitored, not resting orders (>70% at second 00)",
          csec0 > 0.70, f"{csec0:.1%}")

    # ------------------------------------------------------------- the baskets
    d = baskets(d)
    nb = d.lb.nunique()
    print("\nbasket structure")
    check("797 logical baskets", nb == 797, f"{nb}")
    multi = d.groupby("lb").filter(lambda g: len(g) > 1)
    same = multi.groupby("lb").cprice.nunique().eq(1).mean()
    check("multi-position baskets close as a unit", same > 0.15,
          f"{same:.1%} share one exact close price")
    gross_losers = int(d.groupby("lb").profit.sum().lt(0).sum())
    net_losers = int(d.assign(net=d.profit + d.comm + d.swap)
                      .groupby("lb").net.sum().lt(0).sum())
    check("19 gross-losing baskets, 23 after costs",
          gross_losers == 19 and net_losers == 23,
          f"gross {gross_losers}, net {net_losers}, of {nb}")

    # ------------------------------------------- timeframe fingerprint per slot
    print("\nsession x timeframe fingerprint (bar-open basket starts)")
    first = d.groupby("lb").head(1)
    first = first[first.otime.dt.second == 0]
    expect = {
        (3, "Buy"): 15, (8, "Sell"): 12, (9, "Sell"): 12,
        (18, "Sell"): 20, (19, "Buy"): 15, (21, "Sell"): 30,
        (22, "Sell"): 30, (23, "Sell"): 10, (13, "Buy"): 12,
    }
    for (h, side), tf in sorted(expect.items()):
        s = first[(first.hour == h) & (first.type == side)]
        if len(s) == 0:
            continue
        frac = float((s.minute % tf == 0).mean())
        check(f"h={h:02d} {side:<4s} -> M{tf}", frac >= 0.95,
              f"n={len(s)} {frac:.1%} on grid, minutes={sorted(int(x) for x in s.minute.unique())}")

    # --------------------------------------------------------- direction locks
    print("\ndirection locks")
    for h, side in [(3, "Buy"), (18, "Sell"), (19, "Buy"), (21, "Sell")]:
        s = first[first.hour == h]
        ok = bool((s.type == side).all()) and len(s) > 0
        check(f"hour {h:02d} is {side}-only", ok, f"{s.type.value_counts().to_dict()}")

    # ------------------------------------------------------- martingale ladder
    print("\ngrid volume ladder")

    def norm(v):
        return round(round(v / 0.01) * 0.01, 2)

    ladders = []
    for _, g in d.groupby("lb"):
        L = list(g.sort_values("otime").ovol.values)
        if len(L) > 1 and len(set(L)) > 1:
            ladders.append([round(x, 2) for x in L])
    n_multi = d.groupby("lb").filter(lambda g: len(g) > 1).lb.nunique()
    flat = 1 - len(ladders) / max(1, n_multi)
    check("most multi-entry baskets are flat volume", flat > 0.85,
          f"{flat:.1%} of {n_multi} multi-entry baskets")

    # the ladders that are pure martingale (no deposit landed mid-basket)
    pure = [l for l in ladders if l in ([0.02, 0.03, 0.04, 0.06, 0.09, 0.14],
                                        [0.03, 0.04, 0.06, 0.09],
                                        [0.03, 0.04, 0.06],
                                        [0.03, 0.04],
                                        [0.02, 0.03, 0.04])]
    good_m = [m for m in np.arange(1.30, 1.70, 0.001)
              if all(np.allclose([norm(l[0] * m ** j) for j in range(len(l))], l)
                     for l in pure)]
    check("raw-compounding ladder solves to m in [1.466,1.468]",
          len(good_m) > 0 and 1.4655 <= min(good_m) and max(good_m) <= 1.4685,
          f"m in [{min(good_m):.4f},{max(good_m):.4f}]" if good_m else "no solution")

    # compounding on the rounded value must be impossible - that is the point
    bad_m = []
    for m in np.arange(1.30, 1.70, 0.001):
        ok = True
        for l in pure:
            p = [l[0]]
            for j in range(1, len(l)):
                p.append(norm(p[-1] * m))
            if not np.allclose(p, l):
                ok = False
                break
        if ok:
            bad_m.append(m)
    check("compounding on the rounded value has no solution", len(bad_m) == 0)

    # ----------------------------------------------- per-slot shipped constants
    print("\nshipped per-slot constants vs the data")
    rows = []
    for _, g in d.groupby("lb"):
        g = g.sort_values("otime").reset_index(drop=True)
        lots = g.ovol.values
        sgn = 1 if g.type.iloc[0] == "Buy" else -1
        wavg = (g.oprice.values * lots).sum() / lots.sum()
        wexit = (g.cprice.values * lots).sum() / lots.sum()
        steps = [(g.oprice[j - 1] - g.oprice[j]) * sgn for j in range(1, len(g))]
        rows.append(dict(
            slot=session_of(g.otime.min().hour, g.otime.min().minute, g.type.iloc[0]),
            n=len(g), price=g.oprice.iloc[0],
            tp_bp=(wexit - wavg) * sgn / g.oprice.iloc[0] * 10000,
            st_bp=(np.median(steps) / g.oprice.iloc[0] * 10000) if steps else np.nan))
    B = pd.DataFrame(rows)

    src = open(EA).read()
    shipped = {}
    for m in re.finditer(
            r'SetSlot\(c\[\d+\],\s*"(\d\d)[^"]*",[^,]+,[^,]+,\s*(PERIOD_\w+),\s*\w+,\s*'
            r'([\d.]+),\s*([\d.]+),\s*(\d+)', src):
        shipped[m.group(1)] = dict(tf=m.group(2), tp=float(m.group(3)),
                                   step=float(m.group(4)), lvl=int(m.group(5)))
    check("all 12 slots parsed from the EA source", len(shipped) == 12, f"{len(shipped)}")

    for slot in sorted(shipped):
        if slot == "12":
            continue
        s = B[B.slot == slot]
        if len(s) == 0:
            check(f"slot {slot} present in the record", False)
            continue
        tp = s.tp_bp.median()
        ok = abs(tp - shipped[slot]["tp"]) < 0.02
        check(f"slot {slot} TP  {shipped[slot]['tp']:.2f} bp", ok,
              f"measured {tp:.2f} bp over {len(s)} baskets")

    for slot in ["01", "02", "03", "04", "06", "08", "09", "10"]:
        s = B[(B.slot == slot) & B.st_bp.notna()]
        ok = abs(s.st_bp.median() - shipped[slot]["step"]) < 0.02
        check(f"slot {slot} step {shipped[slot]['step']:.2f} bp", ok,
              f"measured {s.st_bp.median():.2f} bp over {len(s)} grids")

    # slots 05/07/11 are deliberately clamped - assert the clamp is conservative
    for slot in ["05", "07", "11"]:
        s = B[(B.slot == slot) & B.st_bp.notna()]
        raw = s.st_bp.median()
        ok = shipped[slot]["step"] <= raw
        check(f"slot {slot} step clamped below the noisy estimate", ok,
              f"shipped {shipped[slot]['step']:.2f} <= raw {raw:.2f} bp (n={len(s)})")

    # --------------------------------------------------------- max grid levels
    print("\ngrid depth cap")
    depth = d.groupby("lb").size()
    cov = (depth <= 12).mean()
    check("InpMaxGridLevels=12 covers >=99.8% of baskets", cov >= 0.998, f"{cov:.3%}")

    print()
    if failures:
        print(f"{len(failures)} CHECK(S) FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("all checks passed - shipped constants are consistent with the trade record")
    return 0


if __name__ == "__main__":
    sys.exit(main())

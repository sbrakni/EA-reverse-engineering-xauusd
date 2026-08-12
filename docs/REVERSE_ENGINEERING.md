# Reverse engineering Quantum Queen X MT5

Everything in this document is derived from one artefact: the **1466 closed XAUUSD
deals** published by the vendor's live signal (MQL5 signal `2234595`, IC Markets,
2024-04-30 → 2026-08-11), plus the public product description.

No vendor binary was decompiled and no vendor source was consulted. The
reconstruction is *behavioural*: it reproduces what the account demonstrably did,
and it is explicit about the one component a trade log cannot pin down.

---

## 0. The record at a glance

| Metric | Value |
|---|---|
| Deals | 1466 (1239 buy / 227 sell) |
| Symbol | XAUUSD only |
| Window | 2024-04-30 18:20 → 2026-08-11 09:48 (832 calendar days) |
| Gross profit | 5040.61 |
| Commission / swap | −263.60 / −117.40 |
| Net | 4659.61 |
| Deal win rate | 76.5 % |
| Distinct trading days | **219** of ≈594 weekdays (37 %) |
| Max simultaneous positions | 16 |
| Commission | ≈ 7.00 per lot round turn (RAW/ECN account) |

The profit column reconciles exactly with
`profit = (close − open) × direction × lots × 100`, confirming a 100 oz contract
and a 2-decimal gold feed — consistent with the product's "not compatible with
brokers which offer a 3 decimal price quota for GOLD".

---

## 1. Positions are managed as baskets, not individually

Grouping deals by close-timestamp clusters (same direction, closes within 15 s)
yields **797 baskets**:

| Positions in basket | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 16 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Count | 496 | 161 | 55 | 34 | 16 | 11 | 7 | 9 | 6 | 1 | 1 |

Three independent facts force the basket interpretation:

1. **87 %** of multi-position groups close on a single timestamp.
2. Inside those groups, winners and losers close **together**. On 2026-08-11 the
   03:45 close booked `+10.80, +6.66, +2.36, −0.02` simultaneously. A per-position
   take-profit cannot do that; an aggregate decision can.
3. There is **no fixed take-profit distance**. Measured from the volume-weighted
   entry to the exit, the distance ranges from 0.30 to 34.24 USD with a median of
   1.05. A resting TP order would produce a spike, not a distribution.

Only **19 of 797** baskets closed with a negative gross result (23 once commission
and swap are charged), and the worst was −2.09 USD per 0.01 lot.

---

## 2. The session schedule — the strongest signal in the data

Entry timestamps are extraordinarily structured. **88 %** of all 1466 entries carry
`second == 00`, so the EA acts on **bar opens**, not on ticks.

Restricting to bar-open basket *starts* (691 of them) and grouping by hour and
direction gives an exact timeframe fingerprint — the minute values of each cluster
land on one and only one timeframe grid:

| Server hour | Direction | n | Minutes observed | Timeframe |
|---|---|---|---|---|
| 03 | Buy | 58 | 0, 15, 30, 45 | **M15** |
| 08 | Buy | 8 | 0, 30 | **M30** |
| 08–09 | Sell | 19 | 0, 12, 24, 36, 48 | **M12** |
| 09–13 | Buy | 52 | 0, 12, 24, 36, 48 (+M1 re-entries) | **M12** |
| 18 | Sell | 31 | 0, 20, 40 (one 18:55 outlier) | **M20** |
| 19 | Buy | 94 | 0, 15, 30, 45 | **M15** |
| 21 | Sell | 20 | 0, 30 | **M30** |
| 22 | Sell | 15 | 0, 30 | **M30** |
| 22–23 | Buy | 364 | 0, 4, 8, 12, 16, 20, 24 … and 6, 18, 30, 42, 54 | **M4 ∪ M6** |
| 23 | Sell | 30 | 0, 10, 20, 30, 40 | **M10** |

Two further observations:

* **Direction is locked per session.** Hour 03 produced 75 buy baskets and *zero*
  sells. Hour 18 produced 33 sells and *zero* buys. Hours 10–13 are buy-only.
  The entry filter therefore only ever answers *"trade now?"*, never *"which way?"*.
* **No DST shift.** Splitting the record into Apr–Oct and Nov–Mar leaves the hour
  histogram unchanged, so the sessions are anchored to **broker server time**
  (EET/EEST for IC Markets), not to UTC.
* Hours 01, 02, 04–07, 14, 16, 20 **never start a basket** — they only ever contain
  grid additions and exits spilling out of the 22:00–23:59 and 03:00 sessions.

This yields 11 distinct session × timeframe × direction clusters. The product
advertises *"12 optimized built-in strategies"* with *"9 carefully selected
strategies"* in the default preset — the reconstruction ships 11 measured slots
plus one spare, with 9 enabled by default.

---

## 3. Grid mechanics

**91.7 %** of the 669 non-first entries were placed *against* the open position, so
the grid averages into adverse movement rather than pyramiding.

Spacing measured from the previous entry:

| percentile | 5 % | 10 % | 25 % | 50 % | 75 % | 90 % | 95 % |
|---|---|---|---|---|---|---|---|
| USD | 0.30 | 0.73 | 1.46 | **1.88** | 2.83 | 4.61 | 6.19 |

The absolute spacing grew as gold rallied, but expressed as a **fraction of price
it is stable**:

| Year | Median price | Median spacing | Spacing in bp | TP in bp |
|---|---|---|---|---|
| 2024 | 2506 | 1.34 | 5.33 | 4.06 |
| 2025 | 3373 | 1.92 | 5.39 | 2.66 |
| 2026 | 4642 | 2.10 | 4.60 | 2.69 |

This is why the reconstruction expresses both the grid step and the basket target
in **basis points of price** by default (ATR-relative and fixed-point modes are
also provided).

Grid additions arrive on **M1 cadence** — the modal gap between consecutive entries
is exactly 1 minute (102 occurrences) then exactly 2 minutes (59).

Clean example, basket of 2025-07-14 (session 03:00, M15, buy, flat 0.01 lots):

```
03:45  3372.44      steps: 1.95, 2.61, 2.28, 2.52,
03:48  3370.49             1.53, 2.08, 1.68, 1.88, 1.52
03:51  3367.88
04:07  3365.60      all ten closed together at 09:48 ≈ 3363.5
...
05:42  3354.39
```

Depth reached, over all 797 baskets:

| ≥2 | ≥3 | ≥4 | ≥5 | ≥6 | ≥7 | ≥8 | ≥9 | ≥10 |
|---|---|---|---|---|---|---|---|---|
| 37.8 % | 17.6 % | 10.7 % | 6.4 % | 4.4 % | 3.0 % | 2.1 % | 1.0 % | 0.3 % |

A cap of 12 levels covers 99.9 % of the observed behaviour.

---

## 4. Position sizing

**269 of the 301** multi-entry baskets (89.4 %) use a **flat volume** across the
whole grid, and every basket after 2025-05 does. The default multiplier is
therefore **1.0**.

A martingale phase is visible between 2024-08 and 2025-05, e.g. the 2024-11-11
basket `0.02 → 0.03 → 0.04 → 0.06 → 0.09 → 0.14` and the 2024-08-16 basket
`0.03 → 0.04 → 0.06 → 0.09`.

The ladder compounds on the **raw base volume** and is rounded once at the end:

```
lot(level) = round_to_lot_step( base × m^level )
```

Compounding on the already-rounded previous volume cannot reproduce these ladders
for *any* multiplier: the `0.03 → 0.04` step requires m < 1.5 while `0.09 → 0.14`
requires m ≥ 1.5, an empty intersection. Solving the raw-compounding form against
every observed ladder simultaneously pins the multiplier to **m ∈ [1.466, 1.468]**.

It is exposed as an input rather than baked in, because the account owner clearly
changed the setting mid-history.

**Size tracks the account balance and is recomputed on every order.** The decisive
evidence is the basket opened 2026-07-29 22:18 while three 2000 USD deposits landed
*mid-basket*:

| Deposit time | Balance after | Next grid entry volume |
|---|---|---|
| — | ≈2.1 k | 0.04 |
| 22:33:55 | ≈4.1 k | 0.07 (at 22:34) |
| 22:55:23 | ≈6.1 k | 0.11 (at 22:56) |
| 22:59:26 | ≈8.1 k | 0.15 (at 23:00) |

The median over the whole record is **0.0183 lots per 1000** of balance, so the
default is set to 0.02 per 1000.

---

## 5. The exit

Exits are evaluated on **M1 bar opens** — 76 % of all closes carry `second == 00`.

The distance from the volume-weighted entry to the exit, per basket:

| percentile | 5 % | 25 % | 50 % | 75 % | 95 % | max |
|---|---|---|---|---|---|---|
| USD per 0.01 lot | 0.30 | 0.63 | **1.05** | 1.79 | 4.19 | 34.24 |

Crucially, this distribution is **independent of basket size** (median 1.05 for
single positions, 1.07 for pairs, 0.99 for triples …), which means the target is
proportional to volume — a *price distance from the average entry*, not a fixed
money amount.

Per session the median target differs materially, and those medians are what the
reconstruction ships as defaults:

| Slot | Session | TF | Dir | Baskets | TP (bp) | Step (bp) | Max lvl | Gross |
|---|---|---|---|---|---|---|---|---|
| 01 | 03:00–04:59 | M15 | Buy | 75 | 3.03 | 5.64 | 10 | 463 |
| 02 | 08:00–09:59 | M12 | Sell | 27 | 3.55 | 6.39 | 8 | 332 |
| 03 | 08:00–08:59 | M30 | Buy | 9 | 4.94 | 4.80 | 8 | 121 |
| 04 | 09:00–13:59 | M12 | Buy | 63 | 6.21 | 6.39 | 9 | 633 |
| 05 | 18:00–18:59 | M20 | Sell | 33 | 6.54 | 23.02* | 6 | 234 |
| 06 | 19:00–20:59 | M15 | Buy | 96 | 2.37 | 4.87 | 9 | 409 |
| 07 | 21:00–21:59 | M30 | Sell | 22 | 5.95 | 16.78* | 9 | 211 |
| 08 | 22:00–23:59 | M4 | Buy | 225 | 2.38 | 4.61 | 9 | 1144 |
| 09 | 22:00–23:59 | M6 | Buy | 197 | 2.15 | 4.90 | 16 | 1023 |
| 10 | 22:00–22:59 | M30 | Sell | 16 | 5.40 | 8.19 | 9 | 259 |
| 11 | 23:00–23:59 | M10 | Sell | 34 | 3.68 | 12.01* | 6 | 212 |

\* Slots 05, 07 and 11 seldom built a grid (90th-percentile depth = 2), so their
spacing estimate rests on a handful of samples and has been clamped to 10–12 bp in
the shipped table rather than taken literally.

The right tail (95th percentile 4.19, max 34.24 with a median of 1.05) is the
signature of a **profit trail** rather than a hard target: most baskets close near
the target, a minority run far past it. The reconstruction implements the hard
target as the default and the trail as an option, because the log cannot separate
"trail gave back 30 %" from "the M1 bar opened past the target".

---

## 6. What could **not** be recovered

**The entry filter.** A trade log records the moments the EA decided to trade and
never the moments it looked and declined. With no bundled price series — and no
outbound network access in this environment to reconstruct one — the specific
indicator, period and threshold that gate an entry are not identifiable. Infinitely
many filters fit 219 firing days equally well.

What the log *does* constrain, and what the reconstruction honours exactly:

* entries occur only on bar opens of the slot's timeframe;
* the direction is fixed by the slot, so the filter is a one-bit gate;
* the gate is **selective** — it passed on only 37 % of weekdays;
* within a session, once a basket exists the filter is irrelevant until it closes.

`MQL5/Include/QQX/Signal.mqh` implements a trend + pullback + momentum confluence
gate matching the vendor's own description of an "elite trend-following grid" that
"waits, analyses, and executes when multiple conditions align". Its thresholds are
inputs precisely because they are **inferred, not measured**, and they are the right
place to start if you want to fit the reconstruction to tick data you own.

Also not recoverable from the log: the vendor's four broker-specific presets
(VT Markets/IC Markets medium and low risk, Roboforex ECN, Fusion Zero) — the
signal reflects exactly one of them.

---

## 7. Reproducing the analysis

```bash
pip install pandas numpy
cd analysis
python3 verify_model.py   # re-derives and asserts every constant shipped in the EA
python3 an1.py   # overview, commission, contract size, session histogram
python3 an5.py   # basket reconstruction by close-time clustering
python3 an6.py   # grid spacing and volume ladder
python3 an7.py   # exits, concurrency, day filter
python3 an9.py   # per-strategy parameter table (the shipped defaults)
```

`analysis/positions.csv` is the unmodified signal export.

`verify_model.py` is the important one: it parses the `SetSlot(...)` schedule out of
`QuantumQueenX.mq5` and re-derives all 22 per-slot constants, the timeframe
fingerprints, the direction locks, the volume ladder and the depth cap from the raw
CSV. If a default in the EA ever stops matching the trade record, it fails.

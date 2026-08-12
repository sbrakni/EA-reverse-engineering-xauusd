# Quantum Queen X — MT5 reconstruction

A clean-room MetaTrader 5 Expert Advisor reconstructed by reverse engineering the
**published live trade history** of *Quantum Queen X MT5* (MQL5 signal
[2234595](https://www.mql5.com/en/signals/2234595), IC Markets,
2024-04-30 → 2026-08-11, 1466 XAUUSD deals).

The EA is built entirely from the trade record and the public product page. No
vendor binary was decompiled and no vendor source was used.

**[docs/REVERSE_ENGINEERING.md](docs/REVERSE_ENGINEERING.md) is the substance of
this project** — every default in the code is traced back to a measurement there.

---

## What the trade record actually revealed

The signal export turned out to be far more informative than a trade log usually
is, because this system leaves a very sharp timing fingerprint.

**A multi-session engine, not one strategy.** 88 % of all entries land exactly on
`second == 00`, so the EA acts on bar opens. Grouping basket *starts* by hour and
direction, the minutes of each cluster fall on one and only one timeframe grid —
03:00/15/30/45 is M15, 08:00/12/24/36/48 is M12, 18:00/20/40 is M20, 21:00/30 is
M30, 23:00/10/20/30/40 is M10. Eleven distinct session × timeframe × direction
clusters come out of the data. The product page advertises "12 optimized built-in
strategies" with "9 carefully selected strategies" enabled by default.

**Direction is locked per session.** Hour 03 produced 75 buy baskets and zero
sells; hour 18 produced 33 sells and zero buys. The entry filter only ever decides
*whether* to trade, never *which way*.

**Positions are managed in baskets.** 87 % of multi-position groups close on one
timestamp, and winners and losers close together — on 2026-08-11 the 03:45 close
booked `+10.80, +6.66, +2.36, −0.02` at once. There is no fixed take-profit: the
distance from the volume-weighted entry to the exit spans 0.30 → 34.24 USD.

**The grid averages down on M1 cadence**, spaced ≈5 basis points of price — a
ratio that held steady (5.33 / 5.39 / 4.60 bp) across 2024–2026 even as the
absolute spacing nearly doubled with gold.

**Sizing tracks the balance and is recomputed per order.** Three 2000 USD deposits
landed *mid-basket* on 2026-07-29 and every subsequent grid entry stepped up
immediately: 0.04 → 0.07 → 0.11 → 0.15.

Result: 797 baskets, of which only 19 lost money before costs (23 after).

## What could not be recovered — read this before trading it

**The entry filter is inferred, not measured.** A trade log records when the EA
*did* trade and never when it looked and declined, and no price series ships with
the export (this environment also has no outbound network access to reconstruct
one). Infinitely many filters fit the 219 firing days equally well.

The log does constrain the filter's *shape*, and the code honours all of it: entries
only on the slot timeframe's bar open, direction fixed by the slot, and a gate
selective enough to pass on just 37 % of weekdays. `Signal.mqh` implements a trend +
pullback + momentum confluence gate consistent with the vendor's own "elite
trend-following grid" description, with every threshold exposed as an input —
because that is the part you should fit against tick data you own.

So: the **architecture, schedule, grid, sizing and exit are reproductions**; the
**entry trigger is a plausible stand-in**. Backtest before drawing conclusions.

---

## Install

Copy into your MT5 data folder (*File → Open Data Folder*):

```
MQL5/Experts/QuantumQueenX/QuantumQueenX.mq5   ->  MQL5/Experts/QuantumQueenX/
MQL5/Include/QQX/*.mqh                         ->  MQL5/Include/QQX/
MQL5/Presets/*.set                             ->  MQL5/Presets/
```

Open `QuantumQueenX.mq5` in MetaEditor and press **F7**. Attach to an **XAUUSD**
chart (any timeframe — each slot reads its own series).

Requirements matching the original: hedging account, 2-decimal gold feed,
RAW/ECN spreads, leverage ≥ 1:100, VPS.

## Presets

| Preset | Slots enabled |
|---|---|
| `Default` | 9 slots — 01, 02, 04, 05, 06, 07, 08, 09, 11 |
| `Low risk` | 5 slots — 01, 06, 08, 09, 11 (deepest samples, tightest loss distribution) |
| `All` | all 12 |
| `Custom` | the 12 `InpS01…InpS12` switches (the product's "Custom Mode") |

## The strategy table

| # | Session (server) | TF | Dir | Live baskets | TP (bp) | Step (bp) | Max levels |
|---|---|---|---|---|---|---|---|
| 01 | 03:00–04:59 | M15 | Buy | 75 | 3.03 | 5.64 | 10 |
| 02 | 08:00–09:59 | M12 | Sell | 27 | 3.55 | 6.39 | 8 |
| 03 | 08:00–08:59 | M30 | Buy | 9 | 4.94 | 4.80 | 8 |
| 04 | 09:00–13:59 | M12 | Buy | 63 | 6.21 | 6.39 | 9 |
| 05 | 18:00–18:59 | M20 | Sell | 33 | 6.54 | 12.00 | 6 |
| 06 | 19:00–20:59 | M15 | Buy | 96 | 2.37 | 4.87 | 9 |
| 07 | 21:00–21:59 | M30 | Sell | 22 | 5.95 | 10.00 | 9 |
| 08 | 22:00–23:59 | M4 | Buy | 225 | 2.38 | 4.61 | 9 |
| 09 | 22:00–23:59 | M6 | Buy | 197 | 2.15 | 4.90 | 12 |
| 10 | 22:00–22:59 | M30 | Sell | 16 | 5.40 | 8.19 | 9 |
| 11 | 23:00–23:59 | M10 | Sell | 34 | 3.68 | 12.00 | 6 |
| 12 | spare, disabled | M5 | Both | — | 3.00 | 5.00 | 8 |

Hours are **broker server time** (EET/EEST for IC Markets). The record shows no
DST shift in the hour histogram, so the sessions follow the server clock. On a
broker whose server offset differs from IC Markets', shift every session by the
difference or the schedule will not line up.

Distances default to **basis points of price** because that measure stayed stable
across the whole record; `InpTpScale` / `InpStepScale` also offer ATR-relative and
fixed-point modes.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpPreset` | Default | Strategy set |
| `InpMMMode` | Balance | Fixed lot / per-1000 of balance / of equity |
| `InpLotsPer1000` | 0.02 | Measured median: 0.0183 lots per 1000 |
| `InpGridLotMultiplier` | 1.0 | 89 % of multi-entry baskets are flat-volume; 1.467 reproduces the 2024-08→2025-05 martingale phase exactly |
| `InpMaxGridLevels` | 12 | Covers 99.9 % of observed depth (max seen: 16) |
| `InpGridTimeframe` | M1 | Cadence for grid adds and exit checks |
| `InpUseProfitTrail` | false | Alternative exit; see §5 of the analysis |
| `InpEquityStopPercent` | 0 | Flatten below N % of balance |
| `InpDailyLossStop` | 0 | Stop opening after −N for the day |

The account-protection inputs are **additions**, not reconstructions — the original
shows no evidence of them. They default to off.

## Repository layout

```
MQL5/Experts/QuantumQueenX/QuantumQueenX.mq5   entry point, inputs, strategy table
MQL5/Include/QQX/Defs.mqh                      enums and helpers
MQL5/Include/QQX/Sym.mqh                       contract spec, quotes, normalisation
MQL5/Include/QQX/Money.mqh                     position sizing and the grid ladder
MQL5/Include/QQX/Signal.mqh                    entry filter  <- the inferred part
MQL5/Include/QQX/Basket.mqh                    basket aggregate and bulk close
MQL5/Include/QQX/Strategy.mqh                  one session slot: session/grid/exit
MQL5/Presets/*.set                             ready-made preset files
analysis/verify_model.py                       ties the EA's constants back to the data
analysis/                                      the Python used to derive everything
docs/REVERSE_ENGINEERING.md                    evidence for every default
```

## Reproducing the analysis

```bash
pip install pandas numpy
cd analysis
python3 verify_model.py   # 45 assertions tying the EA's constants to the data
python3 an9.py            # prints the shipped per-strategy table
```

`verify_model.py` parses the `SetSlot(...)` table straight out of
`QuantumQueenX.mq5` and re-derives every constant from `positions.csv`, so the code
and the evidence cannot drift apart silently. It exits non-zero if they do.

---

## Disclaimer

Research and educational reconstruction. It is a **grid/averaging system without a
per-position stop loss** — the same structure that produced the original's smooth
equity curve is what makes it capable of large drawdowns in a sustained one-way
move. The reconstruction's entry filter is not the vendor's. Test on demo, and risk
only capital you can afford to lose.

Trademarks and the original product belong to their author. This repository ships
no vendor code.

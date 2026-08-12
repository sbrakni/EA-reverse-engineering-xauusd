# Why the backtest blew up, and what actually fixes it

Backtest under analysis: `ICMarketsSC-Demo`, XAUUSD, 2026.01.01 → 2026.08.11,
`InpPreset=1` (LowRisk), 10,000 deposit, 1:100 leverage, 59% real-tick quality.

| | |
|---|---|
| Net result | **−11,776.10** |
| Gross profit / loss | 25,645.84 / −37,421.94 (PF **0.69**) |
| Positions | 892, **76.8 % won** |
| Average win / loss | +37.44 / **−179.31** |
| Max consecutive losses | **16 (−11,827.98)** |
| Relative drawdown | **110 %** |
| Margin level at end | **96.40 %** |

---

## 1. The strategy did not lose the money

Rebuilding the 892 deals into baskets gives **445 baskets, 440 of which were
profitable (98.9 %)**. The five that were not cost −31,540 against +20,236 of
wins. Everything else worked.

So the question is not "why does the strategy lose" — it is "what happened to
those five baskets".

## 2. All five were forced exits, not strategy exits

Every one of the five closed in a single burst of simultaneous closes, at a time
with no corresponding profit-target condition. Sorting all multi-position close
events in the run by P&L separates them completely:

```
2026-04-20 01:00:02   16 deals   -11,726.70
2026-03-24 03:39:28    8 deals    -7,076.88
2026-04-02 04:32:00    8 deals    -5,656.14
2026-01-05 10:17:19    6 deals    -4,011.80
2026-01-20 07:58:42    6 deals    -3,032.89
2026-01-21 19:07:00    5 deals       +34.45   <- every other burst looks like this
2026-01-13 20:26:00    4 deals       +44.80
```

Reconstructing the margin level each basket ran at identifies the two distinct
mechanisms:

| Basket | Lots | Balance | Peak floating | Margin level | Killed by |
|---|---|---|---|---|---|
| 2026-04-10 | 1.60 | 9,718 | −13,781 | **−52.7 %** | broker margin call |
| 2026-02-24 | 0.92 | 11,025 | −781 | 215.2 % | `InpEquityStopPercent=60` |
| 2026-03-24 | 1.44 | 17,626 | −4,800 | 202.5 % | `InpEquityStopPercent=60` |
| 2026-01-02 | 0.60 | 10,020 | −1,221 | 336.2 % | `InpEquityStopPercent=60` |
| 2026-01-16 | 0.42 | 7,462 | −1,069 | 327.8 % | `InpEquityStopPercent=60` |

Four of the five baskets had **202–336 % margin level** — they were in no danger
whatsoever. The account equity stop liquidated them anyway, for **−19,802**.
Only the fifth was a genuine margin call, and it cost **−11,738**.

Both causes are settings, not strategy.

## 3. Why a stop loss is the wrong instrument here

The obvious reaction is to cap each basket. The data says otherwise.

Measuring the provable floating drawdown of every basket (the deepest point the
price is *known* to have reached, from the grid's own fill prices, against the
balance at the time) and asking what a per-basket stop would have done:

| Stop | Fires | …of which went on to **win** | Resulting total |
|---|---|---|---|
| 1 % | 105 | 100 | +596 |
| 2 % | 81 | 76 | −3,511 |
| 3 % | 63 | 58 | −4,476 |
| 5 % | 45 | **40** | −8,199 |
| 7 % | 36 | 31 | −10,454 |
| 10 % | 25 | 21 | −14,340 |
| none | — | — | −11,304 |

A 5 % per-basket stop fires 45 times and **40 of those baskets were winners**,
leaving the account worse off than carrying no stop at all.
The edge of this system *is* recovering from deep excursions. Some examples of
baskets that recovered:

| Opened | Legs | Held | Grid span | Peak floating | Result |
|---|---|---|---|---|---|
| 2026-01-20 | 9 | 428 h | 308 USD | −105 % of balance | **+147** |
| 2026-03-16 | 3 | 167 h | 603 USD | −62 % of balance | **+198** |
| 2026-04-01 | 14 | 193 h | 102 USD | −42 % of balance | **+186** |
| 2026-03-10 | 4 | 312 h | 180 USD | −35 % of balance | **+178** |

Any drawdown-triggered exit converts these into losses. That is exactly what the
60 % equity stop did four times.

**Conclusion: do not add stop losses. Remove the one that was already there, and
make the drawdowns survivable instead.**

## 4. Position size is the real constraint

The one genuine margin call needed a floating loss of **137 % of balance**. That
is not survivable at any leverage — but it is entirely a function of size.
Re-running the margin arithmetic over all 445 baskets at different sizes:

| Lots per 1000 | Worst margin level reached | Outcome |
|---|---|---|
| 0.0100 (as tested) | **−52.7 %** | blows up |
| 0.0075 | −10.7 % | blows up |
| 0.0050 | **73.3 %** | survives |
| 0.0035 | **181.3 %** | survives comfortably |
| 0.0020 | 451.4 % | very safe |

**0.0050 lots per 1000 is the survival threshold for this sample; 0.0035 is the
level with real headroom.** The shipped default is now 0.005, and the
`Survivable` preset uses 0.0035.

Note what this means: the account was not oversized by a little. It was oversized
by roughly 2–3×, and that alone accounts for the only unavoidable loss in the run.

## 5. What changed in the code

| Change | Why | Default |
|---|---|---|
| Equity stop → **two-stage brake** | Liquidating at max adverse excursion cost −19,802. The soft brake stops opening and stops averaging instead of realising. | soft 70 %, hard flatten off |
| **Margin-level guard** | The instrument that actually protects a grid: refuse new risk below a margin level, so the broker never picks the exit. | `InpMinMarginLevel=400` |
| **Default size halved** | 0.0100 margin-called; 0.0050 survives. | `InpLotsPer1000=0.005` |
| **Geometric grid spacing** | Constant ~4.9 bp gives 8 levels only ~16 USD of coverage; ×1.35 gives ~48 USD. Costs 8.5 % of winner profit. | `InpGridStepMult=1.35` |
| **HTF trend guard on adds** | Stops the grid averaging into a one-way move; freezes the ladder instead of deepening it. | on, H1 EMA50, 0.12 ATR/bar |
| **Volatility regime gate** | Skips new baskets when ATR is >2.2× its own average. | on |
| **Staged recovery** | Aged baskets relax their target (full → 0.35× → break-even) so they leave at the first bounce instead of sitting for weeks. Never forces a loss. | 4 h / 24 h |
| **Pair de-risk** | Closes a losing leg funded by winning legs, shedding exposure with no realised loss. The direct answer to "fewer stop-outs". | on |
| **Per-side lot cap** | Nine of eleven slots are long gold; a sell-off loads them all at once. | off, `InpMaxLotsPerSide` |
| Per-basket % stop | Kept, but **off by default** — §3 shows it destroys the edge. | `InpBasketMaxLossPct=0` |
| Give-up exit | Kept, but **off by default** — aged baskets recover. | `InpGiveUpHours=0` |

The EA now prints a startup warning if `InpEquityStopPercent`,
`InpBasketMaxLossPct` or an oversized `InpLotsPer1000` is configured, quoting the
measured consequence of each.

## 6. Honest limits of this analysis

* **Nothing here is a re-run.** MetaTrader is not available in this environment,
  so these are counterfactuals computed from the deal log, not new backtests.
  Re-run the tester with `QQX_Survivable.set` before trusting any of it.
* **The recovery and trend-guard changes cannot be simulated from a deal log** —
  they depend on the intra-basket price path, which the report does not contain.
  Their justification is mechanical (they attack the signature every losing
  basket shares), not measured.
* **Five events.** The size and stop conclusions rest on five liquidations in
  seven months. They are consistent and mechanically explainable, but five is a
  small sample and 2026 was an exceptionally trending year for gold.
* **The entry filter is still the inferred one**, not the vendor's. A better
  entry filter would reduce how often baskets go deep in the first place, and is
  where the remaining upside lives.
* This remains a **grid system with no per-position stop**. Made survivable, not
  made safe. A long enough one-way move still ends it.

## 7. Reproducing

```bash
cd analysis
python3 bt_extract.py   # parse the report into bt_deals.csv
python3 bt_analyse.py   # baskets, slot P&L, loss concentration
python3 bt_risk.py      # margin survival and stop-loss counterfactuals
```

---

# Run 2 post-mortem — and a design error of mine

Second report: same period, `InpPreset=0` (9 slots), `InpLotsPer1000=0.02`,
`InpMaxGridLevels=12`, `InpEquityStopPercent=0`. Net **−9,282**, account down to
**717 in ten days**, margin level **0.09 %**, tester stopped after 141 bars.

## The build was not the one from the risk commit

All 18 inputs added by the risk work are **absent** from the report's settings
block — `InpGridStepMult`, `InpMinMarginLevel`, `InpSoftBrakePercent`,
`InpRecoveryHours`, `InpPairDeRisk` and the rest. The `.mq5` was not recompiled,
so none of the changes were in play.

What *was* in play was the half of the advice that is dangerous on its own:
`InpEquityStopPercent` had been set to 0, removing the circuit breaker, while the
size stayed at `0.02` lots per 1000 — **four times** the new default — across
**nine** slots and **twelve** grid levels.

Entry volumes in the run were **0.20–0.25 lots**. Everything ran normally for ten
days (balance 10,000 → 12,845), then one three-leg basket met a ~184 USD gold
move and lost **−12,128** in a single close.

## My design error

Reviewing my own risk commit against this: several of the guards I added
(`gridTrendGuard`, the margin guard, the soft brake) blocked **grid additions**.
That is wrong, and it would have made things worse in a different way.

Averaging down *is* this system's recovery mechanism — §3 above shows 37 of the
42 deeply-underwater baskets recovered, and they did it by pulling their average
price toward the market. Freezing a grid strands it at the worst average it ever
had, with no way out. I had built the thing that produces the losses I was
diagnosing.

Fixed: those guards now gate **new baskets only**. A committed ladder always
completes. The one exception is a floor that keeps an add from walking into the
broker's stop-out (`InpAddMarginFloor`, 150 %).

## The correct answer: budget the ladder before opening it

Both failures were fully computable before the first trade. If the grid's
geometry is known — levels, spacing, spacing growth, volume ladder — then the
floating loss of a *fully deployed* basket is arithmetic:

```
D_0 = 0 ,  D_i = D_(i-1) + step · m^(i-1)
worst-case loss = Σ_i  lot_i · (D_last − D_i) · value_per_price
```

So instead of choosing a lot and hoping, `QQX_MM_GRID_BUDGET` (now the default
sizing mode) solves for the lot such that the worst case equals a budget, subject
to a second ceiling that the full ladder's margin fits an allowance. The budget
is divided by the number of enabled slots, because they can all be live at once —
nine slots each risking 25 % of balance is 225 % of balance, which is how run 2
ended.

What that yields on a 10,000 account at gold ≈4400, 1:100:

| Slots | Levels | Span covered | Lot | Worst-case DD | Margin |
|---|---|---|---|---|---|
| 9 | 12 | 161 USD | — | — | **infeasible** |
| 9 | 8 | 44 USD | — | — | **infeasible** |
| **9** | **6** | 21 USD | **0.01** | 6.9 % | 23.8 % |
| **5** | **8** | 44 USD | **0.02** | 22.6 % | 35.2 % |
| 3 | 8 | 44 USD | 0.03 | 20.4 % | 31.7 % |

"Infeasible" means the budget implies **less than the broker's minimum lot**. The
EA now **refuses to trade that slot** rather than rounding 0.002 up to 0.01 —
rounding up is a silent 5× risk multiplier, and it is precisely what happened.

Run 2 traded 0.20–0.25 lots where the feasible size was 0.01: **roughly 22×
oversized**.

## Also new: the risk report

`OnInit` now prints, before the first trade, each slot's base lot, total ladder
volume, span covered, worst-case floating loss and margin — plus the resulting
margin level with everything fully deployed:

```
QQX  ALL SLOTS FULLY DEPLOYED: 0.54 lots, floating -691 (6.9% of balance), margin 2376
QQX  margin level in that state: 391%  (broker stop-out is typically 50%)
```

and, when the arithmetic does not work:

```
QQX  *** THIS CONFIGURATION CANNOT SURVIVE ITS OWN GRID. ***
```

Both blown runs would have printed that line before placing a single trade.

## Changed defaults

| Input | Was | Now | Why |
|---|---|---|---|
| `InpMMMode` | Balance | **GRID_BUDGET** | size solved from the ladder, not guessed |
| `InpMaxGridLevels` | 12 | **6** | 12 is infeasible for 9 slots on a 10k account |
| `InpGridTrendGuard` | true | **false** | freezing a grid strands it |
| `InpMaxBasketDDPercent` | — | 25 | worst case across all slots |
| `InpMaxMarginPercent` | — | 30 | the binding constraint on small accounts |
| `InpAddMarginFloor` | — | 150 | adds stop only near the broker's stop-out |

## To reproduce run 2's diagnosis

```bash
cd analysis
python3 bt_extract.py /path/to/ReportTester.html
python3 bt_risk.py
```

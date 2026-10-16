# Doji risk limits from Bitcoin price history

Doji lends MUSD against locked Bitcoin. This page sets four numbers: how much a borrower can take, the line where a loan goes to auction, how low the auction price may fall, and how long the auction runs. Each number comes from real Bitcoin prices, through one script anyone can re-run: `python -I analysis/btc_drawdowns.py`. The script's exact output is pasted at the bottom of this page.

## The recommendation

| Setting | Value | The one number behind it |
| --- | --- | --- |
| Borrow limit (maxLTV) | 40% | 59.3%, the worst fall of Bitcoin inside any 35 days since 2017. A 40% loan is only underwater after a 60% fall. |
| Liquidation line (liqLTV) | 65% | 35 points of room left above the debt at the line, against 28.1%, the 95th percentile of 35-day falls. |
| Auction floor | 70% of the start value | 28.1%, the same 95th percentile: a buyer who holds up to 35 days needs about that discount, and 70% gives 30%. |
| Auction duration | 72 hours | 15.9%, the 99th percentile of 3-day falls, while the auction itself drops 30 points in those 72 hours. |

Three honest notes before the detail. The limits are set on the whole record since August 2017, not on the calm last four years, because the contracts cannot be upgraded and a lender should be covered through a repeat of 2018 or 2020. The floor and the duration are the weakest of the four: price history can bound them, but only real buyers can tell us how fast they show up. And 40% leaves a thin margin: it never loses on closing prices, but it does lose in three episodes if the lender has to take the lowest price of a day (details below).

## Words used on this page

- **LTV** (loan to value) is the debt divided by the Bitcoin value of the locked position. At 40% LTV, a borrower with $100 of Bitcoin takes $40 of MUSD.
- **maxLTV** is the most a borrower can take when the loan opens. **liqLTV** is the debt share at which the position goes to auction.
- **Cushion** is how far the Bitcoin value can fall after the loan opens before the line is crossed: `1 - maxLTV / liqLTV`. At 40% and 65% it is 38.5%.
- **Room** is how far the value can fall after the line is crossed before it equals the debt: `1 - liqLTV`. At 65% it is 35%.
- **Breach** means the debt goes above the liquidation line.
- **Lender loss** means the Bitcoin value falls below the debt before the sale or settlement is finished. In this model lenders lose money in no other way.
- **Percentile** means "in this share of cases the number was this or smaller". A 99th percentile fall of 25.5% (7-day windows, all history) means that in 99 of 100 windows the fall was 25.5% or less.

## The data

Daily Bitcoin prices from Binance's public API (BTCUSDT, one candle per UTC day, no key needed). The file is `analysis/data/btc_daily.csv`. It holds 3,347 daily rows from 2017-08-17 to 2026-10-15, with no missing days, fetched on 2026-10-16. The unfinished day of the fetch is left out. Binance quotes Bitcoin in USDT, a dollar stablecoin, so these are USDT prices and not USD prices. The script can fetch again with `--fetch`, and falls back to Kraken's public API if Binance cannot be reached (Kraken only serves the latest 720 days, so that file would be too short for this study).

The record starts in August 2017 because that is when this market opens. It covers the 2018 bear market, the March 2020 crash, the 2022 collapse, and the fall from January 2026. It does not cover 2011 to mid-2017.

## The method

The script prints seven numbered parts. This page calls them Table 1 to Table 7.

1. **How far Bitcoin falls.** For every start day, the script looks at every window of N days (a window of N days has N+1 daily closes) and records the biggest fall from a closing peak to a later low point inside it. It does this for 1 to 5 days (auction length) and for 7, 14, 21, 28 and 35 days, plus 63 days (a 28-day loan followed by a 35-day exit). It prints the worst window and the 99.9th, 99th and 95th percentiles, over all history and over the last four years (windows that start on or after 2022-10-15). Table 1 uses the daily close as the low point. Table 2 is a stress case that uses each later day's intraday low. Table 3 is the net fall from one close to the close N days later, which is what a buyer holding a position for N days would have lost.
2. **Loan simulation.** For every day since 2017 the script opens a loan at maxLTV, with the debt fixed at that day's close times maxLTV. It follows the loan for 28 days. If the debt goes above the liquidation line it records a breach. It then follows the Bitcoin value for 35 more days from the breach and records a lender loss if the value drops below the debt. A second version assumes the borrower does not repay at maturity (day 28) even when there was no breach, and checks the 35 days after that. These are the `loss` and `loss+d` columns. The 63-day span is the worst case from loan start to cash: 28 days of loan plus 35 days of exit.
3. **Sensitivity.** The script repeats the loan simulation with the exit stretched to 38 and 42 days (Table 7), and for the stress case with intraday lows (Table 5).

The borrow limits tested run from 35% to 60%. The 35% row is there because 40% turned out to sit close to the edge. Liquidation lines tested are 55% to 75%.

Consecutive windows overlap, so 3,284 simulated loans are not 3,284 independent events. They come from about nine years and a handful of crashes. When this page says a loss happens in 0.12% of loans, that is 4 loans opened on four consecutive days, one episode.

## What the price history says

The checks against known history hold. The single worst day is 12 March 2020 (close to close, $7,935 to $4,800, a 39.5% fall). The worst windows from 7 to 28 days are all the March 2020 crash (47.4% to 53.6%). The worst 35-day and 63-day windows are the fall from the December 2017 peak into February 2018: 59.3% (6 January to 5 February 2018, $17,070 to $6,940) and 63.7% (16 December 2017 to 5 February 2018). The 2022 collapse never sets the worst window at any horizon the script prints. The biggest one-day fall in the last four years is 14.1% on 9 November 2022. The worst window in the last four years is 35.1%, from $96,952 on 14 January 2026 to $62,910 on 5 February 2026.

How far Bitcoin falls inside a window (Table 1, daily closes):

| Window | All history: worst | 99.9th | 99th | 95th | Last 4 years: worst | 99th | 95th |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 3 days | 39.5% | 24.6% | 15.9% | 10.6% | 23.8% | 10.6% | 7.0% |
| 7 days | 47.4% | 40.2% | 25.5% | 16.2% | 25.7% | 17.6% | 10.8% |
| 14 days | 47.4% | 47.4% | 37.7% | 23.8% | 29.8% | 25.2% | 15.4% |
| 28 days | 53.6% | 53.4% | 47.4% | 34.6% | 35.1% | 29.8% | 21.6% |
| 35 days | 59.3% | 59.3% | 50.3% | 39.5% | 35.1% | 34.2% | 25.3% |
| 63 days | 63.7% | 63.7% | 59.3% | 47.5% | 35.1% | 35.1% | 29.8% |

The stress case with intraday lows is harsher: the worst 35-day fall becomes 64.9% (all history) and 38.1% (last four years), and the worst 63-day fall 68.6%.

What it means for loans (Tables 4 and 5, liquidation line at 65%; "all history" columns):

| maxLTV | Cushion | Breach within 28 days | Lender loss, closes | Loss incl. unpaid at maturity, closes | Lender loss, intraday lows | Loss incl. unpaid, lows |
| --- | --- | --- | --- | --- | --- | --- |
| 35% | 46.2% | 0.97% | 0.00% | 0.00% | 0.03% | 0.15% |
| 40% | 38.5% | 2.65% | 0.00% | 0.12% | 0.64% | 1.13% |
| 45% | 30.8% | 4.75% | 0.18% | 0.46% | 1.40% | 2.34% |
| 50% | 23.1% | 10.78% | 1.31% | 1.86% | 2.59% | 4.08% |

The last four years show 0.00% lender loss for every pair in the grid, up to a 60% loan with a 75% line. That is the trap in short history. The last four years contain no 35-day fall bigger than 35.1% on closes (38.1% on lows), so any limit looks safe. The years before them contain a 35-day fall of 59.3% on closes and 64.9% on lows.

## Why each number

### Borrow limit: 40%

Lenders lose only if the Bitcoin value drops below the debt before the sale or settlement is finished. For a 40% loan that takes a 60% fall from the opening value. The worst fall inside any 35 days since 2017 is 59.3%, and inside any 63 days it is 63.7%. On closing prices, none of the 3,284 simulated loans at 40% with a 65% line leaves lenders short after a breach (0.00%). If the borrower also walks away at maturity, 4 loans end short (0.12%), all opened between 15 and 18 December 2017, with the worst shortfall at 9.2% of the debt.

One step up, 45%, loses in 0.18% of loans (0.46% with non-payment), in two episodes, worst shortfall 12.1% of the debt. At 50% the loss is 1.31% (1.86%) over four episodes (two around the December 2017 peak, one in late 2018, one in early 2020), and the worst shortfall is 18.7% of the debt. So 40% is the highest value in the grid that never loses on closing prices.

The margin is thin and the stress case shows it. If a lender had to take the lowest price of the day instead of the close, 40% loses in 0.64% of loans (1.13% with non-payment), in three episodes (loans opened in December 2017, in early January 2018, and from late January to February 2020), with a worst shortfall of 14.5% of the debt. At 35% with a 65% line the stress loss falls to 0.03% (0.15%): 5 loans opened 15 to 19 December 2017, worst shortfall 10.3%. The only pair in the grid with zero loss under stress is 35% with a 55% line, and it breaches in 4.81% of loans on lows. If lenders must be covered against intraday spikes as well, choose 35%. I recommend 40% because it is the highest borrow limit with no loss on closing prices, and it is still a real loan: $40 of MUSD per $100 of Bitcoin.

If the contract allows the settings to move inside hard limits, the tables above suggest a ceiling of 45% for maxLTV. At 50% lenders lose in 1.31% of historical loans across four separate episodes.

### Liquidation line: 65%

At 65%, a position that hits the line is worth about 1.54 times its debt, and its value can still fall 35% before it equals the debt. The number to compare with is 28.1%: in 95 of 100 historical 35-day periods the net fall from the first close to the last was 28.1% or less (Table 3, all history). So after a trigger, lenders usually have enough room to wait out an ordinary bad month. At 70% the room is 30%, which clears that figure narrowly. At 75% the room is 25%, below it, so 75% is out.

The cost falls on borrowers. A loan opened at 40% with the line at 65% is liquidated within its 28 days in 2.65% of simulated loans over all history (about one in 38), and in 0.00% of the last four years. At 70% the all-history figure is 1.40%. At 60% it is 4.02% (and 0.36% in the last four years). I chose 65% over 70% because of the floor: the floor has to sit above the line with room for a penalty, and a buyer's needed discount caps how high the floor can go (next section). A line at 70% with the same 5 points of room would need a floor of 75%, a 25% discount, which is less than the 28.1% that buyers needed in 95% of months.

If the contract allows the settings to move inside hard limits, the tables above suggest a ceiling of 70% for the line.

### Auction floor: 70% of the start value

A buyer of a locked position cannot turn it into Bitcoin quickly: Doji's design puts it at up to about five weeks (the auction, one weekly vote reset and up to 28 days of lock). Over 35 days the net fall of Bitcoin was 28.1% or less in 95% of historical periods, and 18.6% or less in the last four years (Table 3). A floor of 70% gives the buyer a 30% discount, enough to be ahead after 35 days in at least 95 of 100 historical periods, before the buyer's own costs. A floor above about 72% (100% minus 28.1%) would sit above that discount, and buyers would often hold off. A floor much below 70% hands the borrower's leftover value to the buyer without helping lenders.

At the liquidation line the debt is 65% of the position's value, so a floor at 70% pays lenders in full and leaves 5 points (7.7% of the debt) for the penalty and the borrower. The penalty itself is not set in this study. The contract's protected-auction rule (the floor never drops below the debt while the Bitcoin still covers it, recorded in `DECISIONS.md`) lifts the price further when an auction starts lower down.

### Auction duration: 72 hours

During an auction the price falls from the start value to the floor. At 70% over 72 hours that is 30 points, 10 points a day. The risk during the auction is that Bitcoin falls faster than the auction price does, which leaves buyers with no reason to bid. In 99 of 100 historical 3-day windows the Bitcoin fall was 15.9% or less (10.6% in the last four years), so the auction falls about twice as far as the market in all but the most violent 1% of cases. The same check at 7 days gives 25.5%, still under 30 points. At 14 days it gives 37.7%, over. So the auction should not run much longer than a week.

Below that ceiling, the length is a judgement that price history cannot settle. Seventy-two hours is long enough to cover a weekend and for a buyer to arrange MUSD, and short enough that lenders are not waiting. Treat it as a starting value to test on testnet with the keeper.

A single day can move further than the room. On 12 March 2020 the close-to-close fall was 39.5%, against 35 points of room at a 65% line. No auction length helps with that. Protection against a gap comes from the borrow limit: a 40% loan stays covered unless Bitcoin falls 60% from the opening value.

## What this study does not cover

- Years before August 2017. Bitcoin's market was smaller and rougher then. A repeat of that era could be worse than anything tested here.
- USDT prices, not USD prices. A break in the USDT peg would move every number.
- Moves inside a day. Daily closes miss them, so the stress case uses each later day's low. Those lows come from one exchange, and a spike on one exchange may not show on another or in the oracle.
- Interest. The debt is held fixed at the opening amount, so the real margin is a little thinner than shown. The rate and the liquidation penalty are not set here.
- Oracle delay, a keeper that is late, and the MUSD price itself. Only Bitcoin's price is modelled.
- Auction behaviour. No history exists for sales of locked veBTC positions, so the floor and the duration are bounded by price data but not tested against real buyers.
- Timing. The 28-day loan, the 35-day exit and the 63-day total come from Doji's design. If the contracts allow longer, Table 7 shows the effect of 38 and 42 days: at 40% with a 65% line nothing changes (0.00% and 0.12% on closes), but at 45% the loss grows from 0.18% to 0.27%, and at 50% from 1.31% to 2.23% (42 days).
- Independence. Overlapping windows mean a handful of crashes drive every extreme percentile. The 99.9th percentile of the 35-day falls equals the worst window because the top windows are all the same fall, from the 6 January 2018 close to the 5 February 2018 close.

## Re-running it

```
python -I analysis/btc_drawdowns.py          reads analysis/data/btc_daily.csv and prints everything below
python -I analysis/btc_drawdowns.py --fetch  downloads the daily prices again and replaces the file
```

Python 3.12, standard library only. A fresh fetch adds days to the end of the record, so the numbers shift a little and a crash inside the new days would show.

Table 6 lists the episodes behind each lender loss for four pairs: 35/65, 40/65, 45/65 and 50/65 (maxLTV / liqLTV).

## Exact output

Output of `python -I analysis/btc_drawdowns.py` on the file fetched 2026-10-16 09:24 UTC:

```
BTC drawdown study for Doji
data file : btc_daily.csv
source    : Binance spot public API, BTCUSDT, 1d candles in UTC, no API key
fetched   : 2026-10-16 09:24 UTC
range     : 2017-08-17 to 2026-10-15, 3347 daily closes, no missing days
last 4 yrs: windows and loans that start on or after 2022-10-15
A window of N days spans N+1 daily closes. Percentiles use nearest rank over all windows.
Consecutive windows overlap, so the extreme percentiles describe a handful of episodes.

1. Peak-to-trough drop of the daily close inside any window of N days
 days |           ALL HISTORY           |          LAST 4 YEARS          
      |   worst  99.9th    99th    95th |   worst  99.9th    99th    95th
------+---------------------------------+--------------------------------   auction length
    1 |   39.5%   15.4%    9.7%    5.3% |   14.1%   14.0%    6.1%    3.5%
    2 |   39.5%   23.4%   13.5%    8.1% |   22.7%   17.0%    8.7%    5.3%
    3 |   39.5%   24.6%   15.9%   10.6% |   23.8%   22.7%   10.6%    7.0%
    4 |   40.2%   39.5%   19.5%   12.6% |   25.2%   23.8%   12.7%    8.4%
    5 |   46.0%   39.5%   22.7%   14.2% |   25.2%   25.2%   13.8%    9.4%
------+---------------------------------+--------------------------------   loan and exit
    7 |   47.4%   40.2%   25.5%   16.2% |   25.7%   25.3%   17.6%   10.8%
   14 |   47.4%   47.4%   37.7%   23.8% |   29.8%   29.8%   25.2%   15.4%
   21 |   51.7%   51.7%   41.3%   29.6% |   34.2%   34.2%   25.9%   20.1%
   28 |   53.6%   53.4%   47.4%   34.6% |   35.1%   35.1%   29.8%   21.6%
   35 |   59.3%   59.3%   50.3%   39.5% |   35.1%   35.1%   34.2%   25.3%
------+---------------------------------+--------------------------------   longest loan plus exit
   63 |   63.7%   63.7%   59.3%   47.5% |   35.1%   35.1%   35.1%   29.8%
windows per horizon: (days in file - horizon) for all history; those starting on or after the cutoff for 4 years
  example, 35 days: all history 3312, last 4 years 1427
worst windows found:
   1d all history : peak close 2020-03-11 $7,935 -> trough 2020-03-12 $4,800 (39.5%)
   1d last 4 years: peak close 2022-11-08 $18,547 -> trough 2022-11-09 $15,923 (14.1%)
   2d all history : peak close 2020-03-11 $7,935 -> trough 2020-03-12 $4,800 (39.5%)
   2d last 4 years: peak close 2022-11-07 $20,591 -> trough 2022-11-09 $15,923 (22.7%)
   3d all history : peak close 2020-03-11 $7,935 -> trough 2020-03-12 $4,800 (39.5%)
   3d last 4 years: peak close 2022-11-06 $20,906 -> trough 2022-11-09 $15,923 (23.8%)
   4d all history : peak close 2020-03-08 $8,033 -> trough 2020-03-12 $4,800 (40.2%)
   4d last 4 years: peak close 2022-11-05 $21,299 -> trough 2022-11-09 $15,923 (25.2%)
   5d all history : peak close 2020-03-07 $8,887 -> trough 2020-03-12 $4,800 (46.0%)
   5d last 4 years: peak close 2022-11-05 $21,299 -> trough 2022-11-09 $15,923 (25.2%)
   7d all history : peak close 2020-03-06 $9,132 -> trough 2020-03-12 $4,800 (47.4%)
   7d last 4 years: peak close 2026-01-29 $84,650 -> trough 2026-02-05 $62,910 (25.7%)
  14d all history : peak close 2020-03-06 $9,132 -> trough 2020-03-12 $4,800 (47.4%)
  14d last 4 years: peak close 2026-01-23 $89,600 -> trough 2026-02-05 $62,910 (29.8%)
  21d all history : peak close 2020-02-23 $9,936 -> trough 2020-03-12 $4,800 (51.7%)
  21d last 4 years: peak close 2026-01-15 $95,605 -> trough 2026-02-05 $62,910 (34.2%)
  28d all history : peak close 2020-02-14 $10,344 -> trough 2020-03-12 $4,800 (53.6%)
  28d last 4 years: peak close 2026-01-14 $96,952 -> trough 2026-02-05 $62,910 (35.1%)
  35d all history : peak close 2018-01-06 $17,070 -> trough 2018-02-05 $6,940 (59.3%)
  35d last 4 years: peak close 2026-01-14 $96,952 -> trough 2026-02-05 $62,910 (35.1%)
  63d all history : peak close 2017-12-16 $19,103 -> trough 2018-02-05 $6,940 (63.7%)
  63d last 4 years: peak close 2026-01-14 $96,952 -> trough 2026-02-05 $62,910 (35.1%)

2. Same, but the trough is a later day's intraday low (stress case)
 days |           ALL HISTORY           |          LAST 4 YEARS          
      |   worst  99.9th    99th    95th |   worst  99.9th    99th    95th
------+---------------------------------+--------------------------------   auction length
    1 |   44.4%   29.3%   14.9%    7.8% |   16.6%   16.2%    8.1%    5.1%
    2 |   52.3%   33.3%   19.6%   11.6% |   24.3%   19.3%   12.4%    7.4%
    3 |   52.3%   36.6%   24.0%   14.4% |   25.4%   24.3%   14.5%    9.4%
    4 |   52.3%   45.1%   26.3%   17.0% |   26.8%   25.4%   17.2%   11.0%
    5 |   52.9%   52.3%   28.8%   18.8% |   26.8%   26.8%   18.7%   11.9%
------+---------------------------------+--------------------------------   loan and exit
    7 |   58.6%   52.3%   33.5%   22.3% |   28.8%   26.8%   23.8%   14.1%
   14 |   58.6%   58.6%   44.2%   28.2% |   33.0%   32.8%   28.2%   18.7%
   21 |   61.9%   60.8%   49.5%   34.4% |   37.2%   36.9%   29.1%   23.8%
   28 |   63.4%   62.8%   53.1%   41.7% |   38.1%   38.1%   33.0%   27.1%
   35 |   64.9%   64.9%   58.6%   44.2% |   38.1%   38.1%   37.2%   28.1%
------+---------------------------------+--------------------------------   longest loan plus exit
   63 |   68.6%   68.6%   64.9%   52.8% |   38.1%   38.1%   38.1%   33.0%
windows per horizon: (days in file - horizon) for all history; those starting on or after the cutoff for 4 years
  example, 35 days: all history 3312, last 4 years 1427
worst windows found:
  35d all history : peak close 2018-01-06 $17,070 -> trough 2018-02-06 $6,000 (64.9%)
  35d last 4 years: peak close 2026-01-14 $96,952 -> trough 2026-02-06 $60,000 (38.1%)
  63d all history : peak close 2017-12-16 $19,103 -> trough 2018-02-06 $6,000 (68.6%)
  63d last 4 years: peak close 2026-01-14 $96,952 -> trough 2026-02-06 $60,000 (38.1%)

3. Net fall from one close to the close N days later (what a buyer who holds a bought position for N days would lose)
 days |           ALL HISTORY           |          LAST 4 YEARS          
      |   worst  99.9th    99th    95th |   worst  99.9th    99th    95th
------+---------------------------------+--------------------------------   auction length
    1 |   39.5%   15.4%    9.7%    5.3% |   14.1%   14.0%    6.1%    3.5%
    2 |   39.2%   23.4%   12.6%    7.3% |   22.7%   17.0%    8.5%    5.0%
    3 |   39.5%   24.2%   15.6%    9.3% |   23.8%   20.1%   10.2%    6.0%
    4 |   40.2%   29.7%   18.0%   10.5% |   25.2%   18.3%   11.5%    7.2%
    5 |   46.0%   32.5%   19.3%   11.6% |   24.7%   20.1%   12.7%    7.8%
------+---------------------------------+--------------------------------   loan and exit
    7 |   47.0%   38.3%   24.0%   13.1% |   25.7%   21.9%   14.7%    8.9%
   14 |   45.6%   40.1%   31.1%   18.4% |   29.8%   24.9%   20.0%   12.5%
   21 |   50.0%   46.4%   34.9%   22.3% |   34.2%   27.2%   22.7%   14.5%
   28 |   53.4%   49.0%   39.9%   25.1% |   30.9%   30.8%   24.1%   17.6%
   35 |   50.9%   50.0%   40.8%   28.1% |   31.4%   30.2%   24.9%   18.6%
------+---------------------------------+--------------------------------   longest loan plus exit
   63 |   53.1%   50.1%   46.5%   36.4% |   31.7%   28.4%   26.8%   22.3%

4. Loan simulation on daily closes
loans simulated: all history 3284, last 4 years 1399 (one loan opened per day)
breach = share of loans opened at maxLTV whose debt goes above the liquidation line within 28 days
loss   = breach, then the BTC value is below the debt within 35 days of the breach
loss+d = loss, or no breach but the borrower leaves the loan unpaid at day 28 and the value
         is below the debt within the 35 days after that
maxLTV  liq cushion |       ALL HISTORY       |      LAST 4 YEARS      
                    |  breach    loss  loss+d |  breach    loss  loss+d
   35%  55%   36.4% |   3.14%   0.00%   0.00% |   0.00%   0.00%   0.00%
   35%  60%   41.7% |   1.46%   0.00%   0.00% |   0.00%   0.00%   0.00%
   35%  65%   46.2% |   0.97%   0.00%   0.00% |   0.00%   0.00%   0.00%
   35%  70%   50.0% |   0.43%   0.00%   0.00% |   0.00%   0.00%   0.00%
   35%  75%   53.3% |   0.09%   0.00%   0.00% |   0.00%   0.00%   0.00%
   40%  55%   27.3% |   6.49%   0.00%   0.00% |   1.50%   0.00%   0.00%
   40%  60%   33.3% |   4.02%   0.00%   0.03% |   0.36%   0.00%   0.00%
   40%  65%   38.5% |   2.65%   0.00%   0.12% |   0.00%   0.00%   0.00%
   40%  70%   42.9% |   1.40%   0.00%   0.12% |   0.00%   0.00%   0.00%
   40%  75%   46.7% |   0.94%   0.00%   0.12% |   0.00%   0.00%   0.00%
   45%  55%   18.2% |  17.94%   0.09%   0.09% |   8.29%   0.00%   0.00%
   45%  60%   25.0% |   8.37%   0.21%   0.33% |   2.07%   0.00%   0.00%
   45%  65%   30.8% |   4.75%   0.18%   0.46% |   0.71%   0.00%   0.00%
   45%  70%   35.7% |   3.35%   0.12%   0.55% |   0.00%   0.00%   0.00%
   45%  75%   40.0% |   1.89%   0.09%   0.55% |   0.00%   0.00%   0.00%
   50%  55%    9.1% |  39.01%   1.52%   1.58% |  26.95%   0.00%   0.00%
   50%  60%   16.7% |  20.74%   1.31%   1.71% |  10.51%   0.00%   0.00%
   50%  65%   23.1% |  10.78%   1.31%   1.86% |   3.15%   0.00%   0.00%
   50%  70%   28.6% |   5.88%   1.31%   2.47% |   1.43%   0.00%   0.00%
   50%  75%   33.3% |   4.02%   1.07%   2.68% |   0.36%   0.00%   0.00%
   55%  60%    8.3% |  41.81%   2.50%   3.29% |  30.74%   0.00%   0.00%
   55%  65%   15.4% |  23.45%   2.25%   3.41% |  12.58%   0.00%   0.00%
   55%  70%   21.4% |  13.15%   2.59%   4.05% |   4.07%   0.00%   0.00%
   55%  75%   26.7% |   6.85%   2.47%   4.63% |   1.50%   0.00%   0.00%
   60%  65%    7.7% |  44.43%   3.93%   5.45% |  33.74%   0.00%   0.00%
   60%  70%   14.3% |  25.37%   4.42%   6.33% |  13.80%   0.00%   0.00%
   60%  75%   20.0% |  14.92%   4.48%   7.13% |   5.50%   0.00%   0.00%

5. Loan simulation on intraday lows (a loan opens at a day's close, any later low counts)
loans simulated: all history 3284, last 4 years 1399 (one loan opened per day)
breach = share of loans opened at maxLTV whose debt goes above the liquidation line within 28 days
loss   = breach, then the BTC value is below the debt within 35 days of the breach
loss+d = loss, or no breach but the borrower leaves the loan unpaid at day 28 and the value
         is below the debt within the 35 days after that
maxLTV  liq cushion |       ALL HISTORY       |      LAST 4 YEARS      
                    |  breach    loss  loss+d |  breach    loss  loss+d
   35%  55%   36.4% |   4.81%   0.00%   0.00% |   0.36%   0.00%   0.00%
   35%  60%   41.7% |   3.38%   0.03%   0.06% |   0.00%   0.00%   0.00%
   35%  65%   46.2% |   1.95%   0.03%   0.15% |   0.00%   0.00%   0.00%
   35%  70%   50.0% |   1.31%   0.00%   0.15% |   0.00%   0.00%   0.00%
   35%  75%   53.3% |   0.97%   0.00%   0.15% |   0.00%   0.00%   0.00%
   40%  55%   27.3% |  10.41%   0.55%   0.82% |   2.57%   0.00%   0.00%
   40%  60%   33.3% |   6.27%   0.58%   0.97% |   0.79%   0.00%   0.00%
   40%  65%   38.5% |   4.32%   0.64%   1.13% |   0.00%   0.00%   0.00%
   40%  70%   42.9% |   2.92%   0.52%   1.22% |   0.00%   0.00%   0.00%
   40%  75%   46.7% |   1.89%   0.49%   1.22% |   0.00%   0.00%   0.00%
   45%  55%   18.2% |  24.15%   1.40%   2.13% |  12.79%   0.00%   0.00%
   45%  60%   25.0% |  13.19%   1.40%   2.22% |   4.22%   0.00%   0.00%
   45%  65%   30.8% |   7.70%   1.40%   2.34% |   1.50%   0.00%   0.00%
   45%  70%   35.7% |   4.99%   1.31%   2.95% |   0.43%   0.00%   0.00%
   45%  75%   40.0% |   3.93%   1.22%   3.01% |   0.00%   0.00%   0.00%
   50%  55%    9.1% |  48.39%   2.92%   3.87% |  37.74%   0.00%   0.00%
   50%  60%   16.7% |  26.43%   2.74%   3.99% |  14.87%   0.00%   0.00%
   50%  65%   23.1% |  16.23%   2.59%   4.08% |   6.22%   0.00%   0.00%
   50%  70%   28.6% |   9.35%   2.71%   4.63% |   1.86%   0.00%   0.00%
   50%  75%   33.3% |   6.27%   2.62%   5.21% |   0.79%   0.00%   0.00%
   55%  60%    8.3% |  51.52%   4.45%   5.54% |  41.60%   0.00%   0.00%
   55%  65%   15.4% |  29.05%   4.23%   5.85% |  16.94%   0.00%   0.00%
   55%  70%   21.4% |  18.51%   4.17%   6.39% |   7.79%   0.00%   0.00%
   55%  75%   26.7% |  11.02%   4.14%   6.97% |   3.07%   0.00%   0.00%
   60%  65%    7.7% |  54.32%   6.36%   7.95% |  45.03%   0.00%   0.00%
   60%  70%   14.3% |  32.00%   6.49%   8.59% |  19.59%   0.00%   0.00%
   60%  75%   20.0% |  20.80%   6.52%   9.50% |  10.08%   0.00%   0.00%

6. Episodes behind the lender losses, for the pairs discussed in docs/risk/parameters.md
 on daily closes:
  maxLTV 35%, liq 65%: no window with a lender loss
  maxLTV 40%, liq 65%: 4 losing loans in 1 episodes
    opened 2017-12-15 to 2017-12-18: 4 loans, worst shortfall 9.2% of the debt
  maxLTV 45%, liq 65%: 15 losing loans in 2 episodes
    opened 2017-12-07 to 2017-12-27: 12 loans, worst shortfall 12.1% of the debt
    opened 2018-01-05 to 2018-01-07: 3 loans, worst shortfall 9.7% of the debt
  maxLTV 50%, liq 65%: 61 losing loans in 4 episodes
    opened 2017-12-08 to 2017-12-13: 4 loans, worst shortfall 13.4% of the debt
    opened 2017-12-21 to 2018-01-13: 15 loans, worst shortfall 18.7% of the debt
    opened 2018-10-15 to 2018-11-13: 24 loans, worst shortfall 5.0% of the debt
    opened 2020-02-05 to 2020-02-24: 18 loans, worst shortfall 7.2% of the debt
 on intraday lows:
  maxLTV 35%, liq 65%: 5 losing loans in 1 episodes
    opened 2017-12-15 to 2017-12-19: 5 loans, worst shortfall 10.3% of the debt
  maxLTV 40%, liq 65%: 37 losing loans in 3 episodes
    opened 2017-12-07 to 2017-12-27: 12 loans, worst shortfall 14.5% of the debt
    opened 2018-01-04 to 2018-01-07: 4 loans, worst shortfall 12.1% of the debt
    opened 2020-01-30 to 2020-02-24: 21 loans, worst shortfall 8.6% of the debt
  maxLTV 45%, liq 65%: 77 losing loans in 3 episodes
    opened 2017-12-06 to 2017-12-10: 3 loans, worst shortfall 10.5% of the debt
    opened 2017-12-21 to 2018-01-15: 22 loans, worst shortfall 21.9% of the debt
    opened 2020-01-14 to 2020-03-07: 52 loans, worst shortfall 18.8% of the debt
  maxLTV 50%, liq 65%: 134 losing loans in 5 episodes
    opened 2017-12-06 to 2017-12-06: 1 loans, worst shortfall 11.4% of the debt
    opened 2017-12-16 to 2018-01-20: 27 loans, worst shortfall 29.7% of the debt
    opened 2018-10-05 to 2018-11-13: 38 loans, worst shortfall 6.6% of the debt
    opened 2020-01-10 to 2020-03-11: 62 loans, worst shortfall 26.9% of the debt
    opened 2021-04-11 to 2021-04-17: 6 loans, worst shortfall 5.6% of the debt

7. Lender loss if the exit takes longer than 35 days (38 = a 3 day auction before the 35 day path, 42 = a further week)
   loss+d as in section 4. Loans simulated differ slightly because later exits need more history.
maxLTV  liq  exit |   CLOSES, ALL   |  CLOSES, 4 YRS  |    LOWS, ALL    |   LOWS, 4 YRS  
                  |    loss  loss+d |    loss  loss+d |    loss  loss+d |    loss  loss+d
   35%  65%   35d |   0.00%   0.00% |   0.00%   0.00% |   0.03%   0.15% |   0.00%   0.00%
   35%  65%   38d |   0.00%   0.00% |   0.00%   0.00% |   0.03%   0.15% |   0.00%   0.00%
   35%  65%   42d |   0.00%   0.00% |   0.00%   0.00% |   0.03%   0.15% |   0.00%   0.00%
   40%  65%   35d |   0.00%   0.12% |   0.00%   0.00% |   0.64%   1.13% |   0.00%   0.00%
   40%  65%   38d |   0.00%   0.12% |   0.00%   0.00% |   0.64%   1.13% |   0.00%   0.00%
   40%  65%   42d |   0.00%   0.12% |   0.00%   0.00% |   0.64%   1.13% |   0.00%   0.00%
   45%  65%   35d |   0.18%   0.46% |   0.00%   0.00% |   1.40%   2.34% |   0.00%   0.00%
   45%  65%   38d |   0.27%   0.55% |   0.00%   0.00% |   1.89%   2.83% |   0.00%   0.00%
   45%  65%   42d |   0.27%   0.61% |   0.00%   0.00% |   1.98%   3.05% |   0.00%   0.00%
   50%  65%   35d |   1.31%   1.86% |   0.00%   0.00% |   2.59%   4.08% |   0.00%   0.00%
   50%  65%   38d |   1.68%   2.32% |   0.00%   0.00% |   3.29%   5.03% |   0.00%   0.00%
   50%  65%   42d |   2.23%   3.17% |   0.00%   0.00% |   3.81%   5.89% |   0.00%   0.00%
```

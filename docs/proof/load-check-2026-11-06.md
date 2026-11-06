# Load check on a fork of Mezo testnet, 6 November 2026

The faucet hands out enough to open far more loans and offers than Doji had seen, so this run filled a private fork of Mezo testnet well past today's traffic and measured what happened. It is threat model [C81](../security/threat-model.md#c81). Nothing here touched the live chain.

The fork held 300 wallets, 300 offers, 300 loans across the four open Thursdays and 100 live auctions, on top of the real state. That is about a week of the faucet's 40 claims a day, and as much as its test BTC can fund.

Run it yourself with `bash packages/contracts/script/load-fork.sh`. Seeding takes about an hour.

## The keeper

| Run | Finished in | Exit | What it did |
| --- | --- | --- | --- |
| 304 open loans, none due | 107 s, on the run before this one | 5 | Read 150 due first per pair, every resolution job before any harvest, 0 loans missed, 154 past the bound and named |
| 100 of them overdue | 38.5 s, on the run before this one | 5 | Stopped at its 10 writes for the run, then said it left 141 loans, 95 of them past their date, and 6 dates |
| 100 auctions open | 47.0 s | 5 | Planned 4 auction starts, 1 settle and 1 harvest, 0 refused |

Exit 5 turns the scheduled run red. That is the point: a run past its bound now tells the repository's owner, where before it stayed green. A backlog of 100 overdue loans clears in about 5 hours at 10 writes per 30-minute run, and harvests wait until it has.

A separate fork run with 15 older loan dates than the keeper reads also exited 5.

## The app's reads

| Read | Result | Seconds on the fork | Node calls | Explorer calls |
| --- | --- | --- | --- | --- |
| `scanOpenOffers` | 307 offers | 5.72 | 2 | 0 |
| `readOpenAuctions` | 101 auctions | 0.04 | 9 | 4 |
| `readAllProgress` | 309 wallets, complete | 1.09 | 2 | 20 |

None comes near the explorer's limit of about 300 calls a minute. The explorer cannot see a fork's logs, so a stand-in answered with the same pages and caps the real one uses.

## The pages

Each page opened in headless Chrome with its reads pointed at the fork, at 1440 and at 375 pixels wide. Every one had 0 console errors and no sideways scroll.

| Page | 1440 | 375 | What showed |
| --- | --- | --- | --- |
| `/borrow` | 0.72 s | 0.79 s | 3 date cards, 3,180 MUSD on offer |
| `/lend` | 0.89 s | 0.99 s | 205 offers |
| `/` | 1.15 s | 0.88 s | 101 auctions on the chart |
| `/quests/<a seeded wallet>` | 1.76 s | 1.68 s | The whole ledger |

205 offers show because the fork's clock had passed 12 November, so the 100 offers due that day had expired, as they should. The landing page then listed all 101 auctions, about 2,300 pixels on a phone, so it now lists 6 and offers the rest.

## Gas, at the fork's stand-ins

| Call | Gas |
| --- | --- |
| `lockAndBorrow` | 729,051 |
| `startAuction` | 116,966 |
| `postOffer` | 94,949 |
| `setRewardOperator` | 61,196 |

## What this does not prove

- Real speed. Seconds are a dev server on a fork, so trust the call counts over the clock. The real explorer's rate limits were not exercised.
- A month of full claims. The faucet's test BTC cannot fund that many.
- Auctions being bought or settled at this size, and harvests paying anything: the 50 positions with PayDown held no rewards, so this proves the budget caps the run and no more.
- Wallets and writes through the website. The pages were read, not used.
- The keeper's normal path. It ran with the explorer down on purpose, the worst case, so the 20-calls-per-event bound was not reached.
- Mezo's own precompiles. A fork cannot run them, so BTC and the oracle were stand-ins, and the oracle was never stale.
- `/api/leaderboard`, the share image and `/api/faucet`, which read the real testnet from the server and were not opened here.
- Several server copies scanning at once. The limit of one scan a minute is per copy (C73).

The page check at full size ran by hand on the held fork after a font fetch failed its dev server for an unrelated reason. Every other step ran in the script, and the page check also passed in the script on a 5-wallet run.

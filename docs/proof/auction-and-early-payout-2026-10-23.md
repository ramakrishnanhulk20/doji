# An auction sale, an early payout and a roll on Mezo testnet, 2026-10-22 and 2026-10-23

Demo loans 387 and 388 were left unpaid on purpose. Each owed 28.506382 MUSD on Thursday 22 October 2026 against 0.001 BTC locked as veBTC. This page follows loan 388 from the missed date to a sale, and the lender of that date to an early payout, with every step checked on chain. Contracts: LoanManager 0x983F2cD6e30492962104fc4dde8dbb5bd9d05Cfa, CreditMarkets 0x62cBa75f2fAA834ddCa4bF012258368D17Bbb2de (code at commit 09e20c3).

## 1. The keeper starts the auctions

The keeper on GitHub Actions makes the calls anyone may make. Nothing in them needs a role.

| Loan | Call | Transaction | When |
|---|---|---|---|
| 387 | `startAuction(387)`, overdue since 22 Oct 00:00 UTC | [0x8befbb16...8369](https://explorer.test.mezo.org/tx/0x8befbb168add2761c5091c988e6b2a4693a7940327713b5e51363d08f50b8369) | 22 Oct 00:06 UTC, block 16,288,964 |
| 388 | `startAuction(388)` | [0xc9e384b8...83dd](https://explorer.test.mezo.org/tx/0xc9e384b821407a9d80451b7be75f06ef391f7f2b04f401e880dc1794b3c283dd) | 22 Oct 05:10 UTC, block 16,292,772 |

The first pass started 387, then its second send, for 388, was rejected because a lagging node reported an old nonce. The next pass started 388. The keeper now uses a nonce manager so this cannot repeat (commit c953e08).

## 2. A buyer buys loan 388 through the website

The loan page at `/loans/388` was used with a test wallet (buyer 0x56B9c9418BaEfDEDef6da0aB2af450842b776B79). Before anything was signed it showed the price, the floor of 57.93 MUSD, the cap of 75.17 MUSD (the price plus 1%, because the price can rise within a block) and the split: lenders 28.51, protocol 1.43, borrower 44.50 (44.49 by the time of the sale).

| Step | What the page did | Transaction | Checked on chain |
|---|---|---|---|
| 1 | Approve the cap in MUSD | [0x7e5e70cd...5a86](https://explorer.test.mezo.org/tx/0x7e5e70cd45ab94df23d6fad967a785aa3dcfe116361e2b0c62ad01cc7b315a86) | 23 Oct 05:21:15 UTC, block 16,312,480, success |
| 2 | `purchase(388, cap, deadline)`; the page showed "veBTC #388 is yours." | [0x23840d02...e9ff](https://explorer.test.mezo.org/tx/0x23840d022a37686237266c95366240f7d432a553273e42c38186160aa72fe9ff) | 23 Oct 05:21:26 UTC, block 16,312,483, success |

The `Purchased` event of step 2:

| | MUSD |
|---|---|
| Price paid | 74.424258 |
| To the 22 October market (the whole debt) | 28.506382 |
| To the treasury (5% of the debt) | 1.425319 |
| To the borrower, as a claimable | 44.492557 |

After the sale `veBTC.ownerOf(388)` is the buyer, the buyer's MUSD went from 205.180000 to 130.755742, `claimableMusd` of the borrower (0xb164F15b59DFd9eb7eac60A364ce3F0f6721A5Ef) is 44.492557, and the 22 October market shows 28.506382 MUSD collected with one loan, 387, still open. The borrower got back 44.49 MUSD, about 60% of the price, because the auction sells from the full value down rather than at a liquidation discount.

## 3. The lender takes its share before the date closes

The deployer wallet (0xd338Ad588D6c3aE127FD5eEC6843A468d3a7aa6e) was the only lender for 22 October and held all 57.012764 units. Loan 387 was still in auction, so the date could not be finalized. `withdrawCollected` pays a holder its share of what has been collected so far.

| Step | Call | Transaction | Result |
|---|---|---|---|
| 1 | `claimUnits(1792627200)` | [0xd909a13f...d5f9](https://explorer.test.mezo.org/tx/0xd909a13fa7d81f60f1055ccd01000668ab3821e6829c6f357089186af1b9d5f9) | 23 Oct 05:23:15 UTC, 57.012764 units minted |
| 2 | `withdrawCollected(1792627200, 57.012764 units)` | [0x72708d2a...2377](https://explorer.test.mezo.org/tx/0x72708d2a08c05704700489ee1333f40fdeef51d0274d91158a8ea4fd8b792377) | 23 Oct 05:30:42 UTC, 28.506382 MUSD paid |

The lender's MUSD went from 271.780609 to 300.286990. `claimOf(lender, 1792627200)` now reads 57.012764 units, 28.506382 MUSD paid, 0 BTC paid, and `paidOutOf(1792627200)` reads 28.506382 MUSD. When loan 387 ends, the same claim pays the rest without paying any of this twice.

## 4. The demo loan rolls to a later Thursday through the website

Demo loan 389 owed 24.458896 MUSD on 29 October, and its lock ended the same day. On My loans, with the borrower's test wallet (0x92DcCb70C33300848Da555eDe8597d3F7037AE2b), "Roll to a later date" offered 5 and 12 November. For 12 November it showed a new principal of 24.46 MUSD from offer 5 at 7.00%, 24.55 MUSD owed on 12 November, and two steps.

| Step | What the page did | Transaction | Checked on chain |
|---|---|---|---|
| 1 | Extend the lock to Thu 12 Nov | [0x72ebf54a...4c5d](https://explorer.test.mezo.org/tx/0x72ebf54afdae7da6b2e94cdb8bdd062f18eb41647ff9628aa9a7d25732644c5d) | 23 Oct 05:39:26 UTC, block 16,312,743, lock end now 1794441600 (12 Nov 00:00 UTC) |
| 2 | `roll` to 12 November; the page showed "veBTC #389 rolled to Thu 12 Nov." | [0xdc1ce964...96b3](https://explorer.test.mezo.org/tx/0xdc1ce96480bdba552321fc44736812dae0b35e6219b7ee1c09f2a9e9d79396b3) | 23 Oct 05:39:41 UTC, block 16,312,746, `owedOf(389)` 24.552713 MUSD, not overdue, not unsafe |

After the roll My loans showed the same position with its two pool votes still counting. The Bitcoin never left the lock and the loan moved without a repayment from the borrower's wallet.

## What this does not cover

- These two steps were sent with `cast` from a script, not from the Lend page's buttons. The Lend page reads the same `claimOf` and `paidOutOf` views.
- Loan 387 reaches its floor price on 25 October at 00:06 UTC and can be settled after that, because its lock ended on 22 October. Its settle, the date's `finalize` and the lender's BTC share are not shown here.
- The buyer and the lender are test wallets controlled by the builder, and test MUSD and test BTC have no value.

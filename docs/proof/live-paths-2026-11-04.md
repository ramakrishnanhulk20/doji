# Live on Mezo testnet, 4 November 2026: a veBTC from outside Doji, fresh offers, lender payouts

All transactions below went to the contracts deployed on 20 October 2026 (LoanManager 0x983F2cD6e30492962104fc4dde8dbb5bd9d05Cfa, CreditMarkets 0x62cBa75f2fAA834ddCa4bF012258368D17Bbb2de), from Doji's own test wallets, between 05:11 and 05:13 UTC. Each was simulated against the live chain before it was sent, and each succeeded.

## A veBTC locked directly on Mezo, then deposited into Doji

Every earlier loan was opened with `lockAndBorrow`, which creates the lock inside Doji. This run starts from a position made on Mezo's own veBTC contract, the way an existing veBTC holder would arrive.

| Step | Transaction |
| --- | --- |
| Approve 0.0005 BTC to veBTC | [0x7382312f...](https://explorer.test.mezo.org/tx/0x7382312fa6c6cfb092b84acd609cada4238ea7447a69b1af21904fb690f251eb) |
| `veBTC.createLockFor`: 0.0005 BTC for 21 days, veBTC #410, lock ends Thu 19 Nov | [0xf13bb417...](https://explorer.test.mezo.org/tx/0xf13bb4172f4c5e958b6816e77fa80dce7bedbed5bac50014a745f5af069799bd) |
| Approve Doji for #410 | [0x986a9b11...](https://explorer.test.mezo.org/tx/0x986a9b115ae478ccfbf5964b9c0a4dfdebe1e4c76ffde18d66edd14a20d0d7a9) |
| `LoanManager.deposit(410)` | [0xe1e46a08...](https://explorer.test.mezo.org/tx/0xe1e46a081f24aaf9489b8e09074e49929ca8efadfa0e37c9bd8c84352274228b) |
| `borrow`: 10 MUSD from offer 9 at 6% to Thu 12 Nov; 10.0128 MUSD owed | [0xdbf8832a...](https://explorer.test.mezo.org/tx/0xdbf8832a2b2788bf5211a48895c6aae54c95c059d3198fb289bff1af56a2ad51) |
| Approve the repay | [0x5fe31fc3...](https://explorer.test.mezo.org/tx/0x5fe31fc3b541de7688cb781b272eecdea7093438fd59f2e65a2521cf382a7f20) |
| `repay` in full | [0xe304bf0b...](https://explorer.test.mezo.org/tx/0xe304bf0bdc5704f4ba399a2d3089b5553b2c1910b57d7f0f9bde48e08ae6819c) |
| `withdrawCollateral`: #410 back to its owner | [0x11ec4250...](https://explorer.test.mezo.org/tx/0x11ec42507d8f30d9626089b592d6f15b3add4326224d13886ea09d008477b5d4) |

## Fresh offers for the next three Thursdays

| Offer | Transaction |
| --- | --- |
| Approve 120 MUSD to CreditMarkets | [0x825b567d...](https://explorer.test.mezo.org/tx/0x825b567d6dc5c2fabda16529fafbccd3f72a3dc400da50440da92611f03e197d) |
| Offer 9: 40 MUSD at 6.00% to Thu 12 Nov | [0xd2bed794...](https://explorer.test.mezo.org/tx/0xd2bed794d12568842462dd446dbadefa1914f6e5241891685dbc9cd8b0331f0f) |
| 40 MUSD at 6.50% to Thu 19 Nov | [0x78430f0e...](https://explorer.test.mezo.org/tx/0x78430f0ec33f2e007a3a4bccb27ef3c29dbc8e7b67eb9b419667d9bc644fb5cc) |
| 40 MUSD at 7.00% to Thu 26 Nov | [0x6f023bb4...](https://explorer.test.mezo.org/tx/0x6f023bb4d612198d27972a4001ff8a1a35daf9ca30eb1698500daccd99433c4c) |

## A lender paid out after settles

Loans 405 and 406 (due 29 Oct) found no buyer in auction; the keeper settled both on 1 Nov and finalized the 29 Oct market. Loan 387's settle had added Bitcoin to the 22 Oct market after its lender's early payout.

| Step | Transaction |
| --- | --- |
| Claim the lender's 74.51 units for 29 Oct | [0x27a92c90...](https://explorer.test.mezo.org/tx/0x27a92c90afb460f09ffd71b734cee7c888a34dba6036e0c7c4959da4e2981009) |
| Redeem them for the 29 Oct market's MUSD and BTC | [0x8c8aa407...](https://explorer.test.mezo.org/tx/0x8c8aa4079d402c1d8929f0cfc36cda93d210f2bf59ee5358128a4ead911d94bf) |
| `withdrawCollected` on 22 Oct: the 0.000354608 BTC the settle added after the early payout, and nothing more | [0x65d36e32...](https://explorer.test.mezo.org/tx/0x65d36e3204f6a69630879801be247f33a113a984214ce6edaa976a404013f1cd) |

## What did not run, and why

`claimRewards` for loan 389 was refused in simulation, before anything was sent: `TokenNotWhitelisted(MUSD)`. Loan 389 votes for the MUSD/BTC pool 0xd16A5Df8, whose incentive contract holds 0.000266 MUSD for it. Mezo's reward contracts pay a pool's own two tokens whether or not they are on PoolsVoter's whitelist, but the 20 October contracts accept only whitelisted tokens, and Mezo's testnet whitelists neither MUSD nor BTC (mainnet whitelists both, which is why the mainnet fork tests passed). This is finding F36 in the [threat model](../security/threat-model.md): the next version accepts a token when the gauge's own reward contract lists it.

This page does not cover `claimRebase` (Mezo's testnet fee distributor has not been funded since 12 November 2025, so every position Doji holds has nothing to claim) or `prepareSettle` (it runs only for an unsold loan whose position still holds votes).

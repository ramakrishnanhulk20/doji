# Doji keeper

The keeper moves Doji loans along when their time comes. Every 30 minutes it looks at every loan and every loan date on Mezo testnet and makes the one call each is ready for: it starts an auction on a loan that is overdue or unsafe, cancels an auction on a loan that is safe again, prepares and settles a position nobody bought, and finalizes a loan date once all of its loans are closed, so lenders can redeem.

Anyone can run it. Every call it makes is open to any wallet, and the contracts re-check every condition themselves, so a keeper that is wrong, late or hostile can waste its own gas but cannot move anyone's money. The keeper wallet has no role in the contracts, gives no approvals and never holds MUSD. It only needs a little test BTC for gas.

## What one pass does

1. Reads `packages/contracts/deployments/31611.json` and refuses to run unless the RPC is Mezo testnet (chain 31611) and LoanManager, CreditMarkets and veBTC on chain match the record and each other. It then reads the owner, pending owner and guardian of both contracts and the CreditMarkets treasury: if the keeper key is any of them, a live pass stops before it simulates or sends anything, and a dry run prints a warning.
2. Works out which loans are open now from LoanManager's `Borrowed` and `LoanClosed` events since the deployment block. A position is open when its latest `Borrowed` comes after its latest `LoanClosed`, counting the order inside a block (a roll closes the old loan and opens the new one in the same transaction), and its due date is the one in that `Borrowed`. The events come from the Mezo block explorer's API (1,000 per call, at most 20 calls per event), and the RPC reads from the block after the explorer's newest indexed block, or at least the newest 10,000 blocks, up to head. If the explorer fails, or is more than 64 pages of 10,000 blocks behind, the RPC alone reads the last 64 pages (about 35 days) and the pass prints a warning that older loans are not seen this run. The events are only hints: each loan is read from the contracts before anything is decided, and one pass reads at most 150 open loans, the ones due first, so a pass stays near 4 minutes inside the 10-minute job. An RPC request that is rate limited or times out is retried once; if it fails again the pass stops, because acting on a partial list would quietly skip loans.
3. For each open loan it reads the loan, its auction, `isOverdue` and `isUnsafe` from the contracts, and picks at most one action, in this order:

   | Action | When |
   |---|---|
   | `startAuction` | the loan is Active and overdue or unsafe |
   | `cancelAuction` | the loan is in an auction that began on or before its due date, and it is safe again |
   | `prepareSettle` | unsold past floor time, overdue or unsafe, the position has a standing vote or a permanent lock, and the epoch's first hour has passed (Mezo refuses vote resets in that hour) |
   | `settle` | unsold past floor time, overdue or unsafe, the lock has ended and there is no vote |

   If `isUnsafe` reverts (the oracle price is unavailable), the loan is skipped and logged.
4. Checks the 32 most recent weekly loan dates, from the first Thursday 00:00 UTC after deployment to the furthest date a new loan can pick (now plus CreditMarkets' `maxTermSeconds`). For each date it compares the chain's own count of open loans, `marketOf(date).openLoans` read at the scanned block, with the open loans the scan found there. If the chain has more, it prints `warning: <date> has <n> open loans on chain but the scan found <k>; loans are being missed`, acts on what it found, and ends with exit code 2 so the run shows red. It calls `finalize` on a date once the date has passed, the date had loans, none is still open and it is not final yet.
5. Every call is simulated first and sent only if the simulation passes. A refused simulation is logged with its revert reason and skipped. The pass stops after `MAX_ACTIONS` writes and the next run carries on.

It prints one line per decision:

```
loan 383               startAuction   overdue since 2026-10-22 00:00 UTC | <tx hash> https://explorer.test.mezo.org/tx/<tx hash>
loan 385               none           active, due 2026-10-29 00:00 UTC, safe at the live price | -
market 2026-10-22      finalize       matured and every loan closed | simulated
```

The exit code is 0 when the pass finished, even if some simulations were refused. It is 1 when a setting is missing, the record or chain does not check out, a live pass finds the keeper key holds a role, or a transaction that was sent failed, and 2 when a checked date has more open loans on chain than the scan found or cannot be read. A dry run exits 2 the same way. If both 1 and 2 apply, the exit code is 1.

## Run it on your machine

Needs Node 20.12 or newer.

```bash
cd packages/keeper
npm ci
npm run keeper:dry   # one pass that only simulates; needs no key and sends nothing
npm run keeper       # one pass that sends; needs KEEPER_PRIVATE_KEY
```

Settings come from the environment. Any setting not in the environment is read from `packages/contracts/.env` if that file exists; nothing else from that file is loaded.

| Setting | Default | What it is |
|---|---|---|
| `KEEPER_PRIVATE_KEY` | none, required unless dry | Private key of a wallet that holds a little test BTC for gas. Give it nothing else. |
| `MEZO_TESTNET_RPC` | `https://rpc.test.mezo.org` | Mezo testnet RPC URL. |
| `MEZO_TESTNET_EXPLORER_API` | `https://api.explorer.test.mezo.org/api` | Mezo testnet block explorer API, used to list `Borrowed` and `LoanClosed` events and read how far it has indexed. |
| `DEPLOYMENT_FILE` | `../contracts/deployments/31611.json` | Deployment record to act on, relative to this folder. |
| `MAX_ACTIONS` | `10` | Most transactions one pass sends, 1 to 50. |

`npm run typecheck` checks the code without running it.

## Run it on GitHub

`.github/workflows/keeper.yml` runs one pass every 30 minutes and whenever you start it by hand. It only runs on a schedule or by hand, never for a pull request, so code from someone else's branch never sees the key. A manual run started from any branch other than `main` is skipped, so only code on `main` runs with the key.

1. On GitHub, open the repository, then Settings, Secrets and variables, Actions, New repository secret.
2. Name it `KEEPER_PRIVATE_KEY` and paste the keeper wallet's private key. Save.
3. Optional: a secret named `MEZO_TESTNET_RPC` replaces the public RPC.
4. To run it now: Actions, keeper, Run workflow.

Each run is billed as at least one minute. Every 30 minutes is 1,440 runs a month, which fits inside the 2,000 free minutes of a private repository only while each run takes under a minute. Public repositories run free.

## Gas

Measured on a fork of Mezo testnet, priced at the 172 wei per gas testnet charged on 2026-10-19:

| Action | Gas | Test BTC |
|---|---|---|
| `startAuction` | about 119,000 | about 0.00000000002 |
| `cancelAuction` | about 71,000 | about 0.00000000001 |
| `prepareSettle` | about 301,000 | about 0.00000000005 |
| `settle` | 410,000 to 614,000 | about 0.0000000001 |
| `finalize` | about 76,000 | about 0.00000000001 |

## What it does not do

It does not buy auctioned positions, write off loans whose position left custody, mint or redeem credit units, or claim anything; those are for the people they belong to. It has no power the contracts do not give every wallet, and its uptime is best effort: if it is down, anyone can make the same calls.

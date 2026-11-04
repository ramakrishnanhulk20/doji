# Doji keeper

The keeper moves Doji loans along when their time comes. Each pass looks at every loan and every loan date on Mezo testnet and makes the one call each is ready for: it starts an auction on a loan that is overdue or unsafe, cancels an auction on a loan that is safe again, prepares and settles a position nobody bought, and finalizes a loan date once all of its loans are closed, so lenders can redeem. It does this for the 20 October contracts and the Wave 2 contracts side by side, checks every pass that Mezo's sMUSD vault would hand back the lender money parked in it, and turns the weekly pool rewards of positions that opted into PayDown into loan repayments.

Anyone can run it. Every call it makes is open to any wallet, and the contracts re-check every condition themselves, so a keeper that is wrong, late or hostile can waste its own gas but cannot move anyone's money. The keeper wallet has no role in the contracts, gives no approvals and never holds MUSD: a harvest pays the borrower's loan and sends the rest to the borrower, never to the caller. It only needs a little test BTC for gas.

## Two pairs, never mixed

A pair is one LoanManager and its CreditMarkets, plus PayDown and UnitMarket from Wave 2 on. Each pair has its own deployment record, and the keeper reads the list in `DEPLOYMENT_FILES`: by default `31611.json` (20 October) and `31611-wave2.json` (Wave 2, deployed 4 November 2026), which is read whenever that file exists. Old and new pairs share maturities and position ids, so the keeper never identifies a loan, market or harvest by its id alone: every object is read from and written to the contracts of the record it came from, and every line it prints starts with that record's name. The run header lists each record's chain id and contract addresses. Two records that name the same Doji contract stop the run before anything is read.

## What one pass does

1. Reads every record in `DEPLOYMENT_FILES` and refuses to run unless the RPC is Mezo testnet (chain 31611) and, for each pair, LoanManager, CreditMarkets and veBTC on chain match the record and each other, PayDown (when the record has one) serves that LoanManager, UnitMarket (when the record has one) lists that CreditMarkets' units, and the savings vault the record names is the one CreditMarkets reports. It then reads the owner, pending owner and guardian of every LoanManager, CreditMarkets, PayDown and UnitMarket in every record, and the treasury of every CreditMarkets and UnitMarket: if the keeper key holds any of these roles, a live pass stops before it simulates or sends anything, and a dry run prints a warning. Mezo's own contracts in a record (veBTC, PoolsVoter, the vault, the Router) give the keeper nothing, so they are not read.
2. Checks the vault for each pair whose CreditMarkets parks lender money in Mezo's sMUSD vault and has more than zero parked: it simulates, as CreditMarkets itself, a vault `withdraw` of the whole `parkedPrincipal`, which sends nothing and costs nothing. If the vault would refuse, or the check cannot be made, it prints a line starting `VAULT ALERT:` with the reason, finishes every other job, prints the alert again at the end and exits 3. This runs before anything that could stop the pass.
3. For each pair in turn, works out which loans are open now from LoanManager's `Borrowed` and `LoanClosed` events since the deployment block. A position is open when its latest `Borrowed` comes after its latest `LoanClosed`, counting the order inside a block (a roll closes the old loan and opens the new one in the same transaction), and its due date is the one in that `Borrowed`. The events come from the Mezo block explorer's API (1,000 per call, at most 20 calls per event), and the RPC reads from the block after the explorer's newest indexed block, or at least the newest 10,000 blocks, up to head. If the explorer fails, or is more than 64 pages of 10,000 blocks behind, the RPC alone reads the last 64 pages (about 35 days) and the pass prints a warning that older loans are not seen this run. The events are only hints: each loan is read from the contracts before anything is decided, and one pass reads at most 150 open loans, the ones due first, so a pass stays near 4 minutes inside the 10-minute job. An RPC request that is rate limited or times out is retried once; if it fails again that pair's jobs stop, because acting on a partial list would quietly skip loans. The other pairs still run, harvests are skipped, and the pass exits 1.
4. For each open loan it reads the loan, its auction, `isOverdue` and `isUnsafe` from the contracts, and picks at most one action, in this order:

   | Action | When |
   |---|---|
   | `startAuction` | the loan is Active and overdue or unsafe |
   | `cancelAuction` | the loan is in an auction that began on or before its due date, and it is safe again |
   | `prepareSettle` | unsold past floor time, overdue or unsafe, the position has a standing vote or a permanent lock, and the epoch's first hour has passed (Mezo refuses vote resets in that hour) |
   | `settle` | unsold past floor time, overdue or unsafe, the lock has ended and there is no vote |

   If `isUnsafe` reverts (the oracle price is unavailable), the loan is skipped and logged.
5. Checks the 32 most recent weekly loan dates of the pair, from the first Thursday 00:00 UTC after its deployment to the furthest date a new loan can pick (now plus CreditMarkets' `maxTermSeconds`). For each date it compares the chain's own count of open loans, `marketOf(date).openLoans` read at the scanned block, with the open loans the scan found there. If the chain has more, it prints `warning: <date> has <n> open loans on chain but the scan found <k>; loans are being missed`, acts on what it found, and ends with exit code 2 so the run shows red. It calls `finalize` on a date once the date has passed, the date had loans, none is still open and it is not final yet.
6. Every call is simulated first and sent only if the simulation passes. A refused simulation is logged with its revert reason and skipped. `MAX_ACTIONS` is one budget for the loan and market calls of every pair, because they share one gas wallet: once it is spent, the pass stops these calls and the next run carries on.
7. Harvests, only after every pair's loan and market jobs have run. If a pair's jobs stopped, or `MAX_ACTIONS` ran out, it skips every harvest this pass and says why, so rewards never take gas the loan jobs still need. For each pair whose record has a PayDown (the 20 October pair never does, and says so):
   - It reads PayDown's pause switch, the MUSD and BTC tokens and the BTC price from MUSD's price feed. A paused PayDown or an unavailable price skips the pair with a line saying so.
   - It finds the positions that opted in from LoanManager's `RewardOperatorSet` events since the pair's deployment block, listed the same way as the loan events above, and keeps those whose latest event names this pair's PayDown. Each is read again with `positionOf`, and a position whose current operator is not PayDown, or that LoanManager no longer holds, is skipped with that reason.
   - One pass reads at most `HARVEST_MAX_POSITIONS` positions across all pairs. With more candidates than that, the window it reads moves along every 30 minutes, so later runs reach the rest.
   - For each position it reads the pools it votes for from PoolsVoter, each pool's gauge and the gauge's fee and incentive reward contracts, and on each side lists only MUSD and BTC, only where that contract records the token as a reward, and only when it has something earned for this position. PayDown measures a token once however many sides list it. A claim lists at most 16 tokens, so extra gauges wait for the next harvest.
   - It skips the position, and says so, when its earned MUSD plus its earned BTC valued at the price feed is below `HARVEST_MIN_MUSD`. Otherwise it simulates `PayDown.harvest` and sends it only if the simulation passes, as with every other call. PayDown sells only the BTC the debt still needs, with the oracle floor, repays the loan and sends everything else to the borrower.

   Pool rewards arrive once a week when the epoch turns, and a harvested position reads zero earned until the next one, so the harvest runs every pass but acts about once a week per position.

It prints one line per decision, starting with the name of the record the object belongs to:

```
31611       loan 383               startAuction   overdue since 2026-10-22 00:00 UTC | <tx hash> https://explorer.test.mezo.org/tx/<tx hash>
31611       market 2026-10-22      finalize       matured and every loan closed | simulated
31611-wave2 vault check            simulate       simulated withdraw of 10 MUSD parked principal by CreditMarkets <address> from vault <address> | succeeds
31611-wave2 harvest 412            skip           0.004 MUSD and 0 BTC earned, worth 0.004 MUSD, below HARVEST_MIN_MUSD 0.01 | -
31611-wave2 harvest 415            harvest        2.5 MUSD and 0.00001 BTC earned, worth 3.28 MUSD, 4 token(s) from 1 gauge(s) | simulated
```

The exit code is 0 when the pass finished, even if some simulations were refused. It is 1 when a setting is missing, a record or the chain does not check out, a live pass finds the keeper key holds a role, a pair's jobs stopped, or a transaction that was sent failed; 3 when a vault check raised a `VAULT ALERT`; and 2 when a checked date has more open loans on chain than the scan found or cannot be read. A dry run exits 2 and 3 the same way. When more than one applies, 1 wins over 3, and 3 over 2.

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
| `MEZO_TESTNET_EXPLORER_API` | `https://api.explorer.test.mezo.org/api` | Mezo testnet block explorer API, used to list `Borrowed`, `LoanClosed` and `RewardOperatorSet` events and read how far it has indexed. |
| `DEPLOYMENT_FILES` | `../contracts/deployments/31611.json`, plus `../contracts/deployments/31611-wave2.json` when that file exists | Comma-separated deployment records to act on, one per pair, relative to this folder, at most 4. A record that is named but missing stops the run. The old single-record setting `DEPLOYMENT_FILE` is refused with a message to rename it. |
| `MAX_ACTIONS` | `10` | Most loan and market transactions one pass sends across all pairs, 1 to 50. |
| `HARVEST_MAX_POSITIONS` | `10` | Most opted-in positions one pass reads for a harvest across all pairs, each harvested at most once, 0 to 20. 0 turns harvests off. |
| `HARVEST_MIN_MUSD` | `0.01` | A position is harvested only when its earned MUSD plus its earned BTC, valued at the price feed, is worth at least this many MUSD. |
| `VAULT_CHECK_OVERRIDE` | none | Test hook, read from the environment only and never from the `.env` file. Points the vault check at another contract so you can watch the alert fire. Never set it on GitHub. |

`npm run typecheck` checks the code without running it.

To see the vault alert fire without touching the vault, point the check at the MUSD token, which has no `withdraw`:

```bash
DEPLOYMENT_FILES=../contracts/deployments/31611.json,../contracts/deployments/31611-slice-savings.json \
VAULT_CHECK_OVERRIDE=0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503 npm run keeper:dry; echo "exit $?"
```

It prints a `VAULT ALERT:` line for the pair with parked money and ends with exit 3.

## Run it on GitHub

`.github/workflows/keeper.yml` asks for one pass every 30 minutes and runs one whenever you start it by hand. GitHub starts scheduled jobs late on a quiet repository, so from 19 to 22 October 2026 the scheduled passes came 2.3 to 5.9 hours apart (median 4.7). A call that cannot wait, such as starting the auction of a loan that turned unsafe, can be made by anyone at once from the loan's page. It only runs on a schedule or by hand, never for a pull request, so code from someone else's branch never sees the key. A manual run started from any branch other than `main` is skipped, so only code on `main` runs with the key.

1. On GitHub, open the repository, then Settings, Secrets and variables, Actions, New repository secret.
2. Name it `KEEPER_PRIVATE_KEY` and paste the keeper wallet's private key. Save.
3. Optional: a secret named `MEZO_TESTNET_RPC` replaces the public RPC.
4. To run it now: Actions, keeper, Run workflow.

The workflow passes both records in `DEPLOYMENT_FILES`, so it needs `31611-wave2.json` on `main`; until then every run stops at the missing record.

A `VAULT ALERT` makes the run fail, and a failed run is how GitHub tells you. For a scheduled workflow GitHub emails the person who created it, or whoever last changed its `cron` line, and only if that person has workflow emails on: on GitHub, your picture (top right), Settings, Notifications, then under System, Actions, tick Email and choose "Only notify for failed workflows". The email links to the run, and the alert is the last line of its log.

Each run is billed as at least one minute. If GitHub ran every scheduled pass, that would be 1,440 runs a month, which fits inside the 2,000 free minutes of a private repository only while each run takes under a minute. Public repositories run free.

## Gas

Measured on a fork of Mezo testnet, priced at the 172 wei per gas testnet charged on 2026-10-19:

| Action | Gas | Test BTC |
|---|---|---|
| `startAuction` | about 119,000 | about 0.00000000002 |
| `cancelAuction` | about 71,000 | about 0.00000000001 |
| `prepareSettle` | about 301,000 | about 0.00000000005 |
| `settle` | 410,000 to 614,000 | about 0.0000000001 |
| `finalize` | about 76,000 | about 0.00000000001 |

The vault check is a simulation, not a transaction, so it costs no gas. A harvest has not been measured from the keeper yet. PayDown went live on testnet on 4 November 2026 (`31611-wave2.json`), and the first rewards it can claim, for loan 411, are paid only once their epoch ends on Thursday 5 November 00:00 UTC. PayDown's own fork test logs it (`test/fork/PayDownFork.t.sol`), and its code comment gives the two big parts: a claim of the most a harvest can list, 16 tokens, is about 1.0 million gas, and the one BTC sale on the real pool is 276,000 to 321,000. A usual keeper harvest lists 4 tokens (MUSD and BTC on both sides of one gauge), so it claims far less than the 16-token figure. Even 1.4 million gas would be about 0.0000000002 test BTC at 172 wei per gas.

## What it does not do

It does not buy auctioned positions, write off loans whose position left custody, mint or redeem credit units, or claim anything for itself; those are for the people they belong to. Its harvest claims only MUSD and BTC, only from the pools a position votes for now: other reward tokens, and rewards from pools the position voted for earlier, are left for the borrower to claim, or to sell with their own minimums through `harvestAndSwap`. It never sells anything itself; PayDown decides what is sold and at what floor. It has no power the contracts do not give every wallet, and its uptime is best effort: if it is down, anyone can make the same calls.

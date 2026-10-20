import { createPublicClient, formatUnits, http, isAddress, type Address } from "viem";
import { addressBook } from "../src/lib/addresses";
import { groupOffersByDate } from "../src/lib/borrow";
import { readBorrowSettings } from "../src/lib/borrow-reads";
import { mezoTestnetChain } from "../src/lib/chains";
import { explainError } from "../src/lib/errors";
import {
  anyoneActions,
  approveMusdCall,
  auctionLineFor,
  btcText,
  describeLoan,
  formatCountdown,
  formatDateTime,
  lineUsedBps,
  maxPayFor,
  musdText,
  quoteRoll,
  readClaimables,
  readMarket,
  readMusdWallet,
  readOpened,
  readPositionViews,
  readWalletPositionIds,
  repaySteps,
  rollCall,
  rollDates,
  rollProblem,
  rollSteps,
  shortAddress,
  splitSale,
  standingOf,
  BORROWED_TOPIC,
  DEPOSITED_TOPIC,
  type PositionView,
} from "../src/lib/loans";
import { formatApr, formatDate, scanOpenOffers } from "../src/lib/stats";

// Read-only: every call below is a view, an eth_call or an explorer lookup. No key is involved and nothing is sent.
const owner = process.env.CHECK_ADDRESS;
if (!owner || !isAddress(owner)) {
  console.error("Set CHECK_ADDRESS to the wallet address to check, for example CHECK_ADDRESS=0x92Dc... npx tsx scripts/check-loans.ts");
  process.exit(1);
}
const wallet: Address = owner;

const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const book = addressBook[31611];
const now = Math.floor(Date.now() / 1000);

console.log(`topics: Deposited ${DEPOSITED_TOPIC}`);
console.log(`        Borrowed  ${BORROWED_TOPIC}`);

function line(view: PositionView): string {
  const used = lineUsedBps(view);
  const floor = view.auction ? view.auction.startTime + view.auction.duration : null;
  return [
    `veBTC #${view.id}`,
    `state ${standingOf(view)} (loan state ${view.loan.state})`,
    view.loan.state === 0 ? "owes nothing" : `owed ${musdText(view.owed)} MUSD, due ${formatDate(view.loan.maturity)}`,
    `collateral ${view.lock ? btcText(view.lock.amount) : "?"} BTC worth ${view.value === null ? "unavailable" : `${musdText(view.value)} MUSD`}`,
    used === null ? "limit used n/a" : `limit used ${(used / 100).toFixed(1)}% of the auction line`,
    view.loan.state === 0 ? "" : `auction line at BTC ${auctionLineFor(view) === null ? "n/a" : musdText(auctionLineFor(view) as bigint)} MUSD`,
    view.lock ? `lock ${view.lock.isPermanent ? "permanent" : `ends ${formatDate(view.lock.end)}`}` : "lock unavailable",
    `votes ${view.voted === null ? "unavailable" : view.voted ? "still counting" : "yours to cast"}`,
    `rewards ${view.rewards === null ? "unavailable" : view.rewards > 0n ? `${btcText(view.rewards)} BTC waiting` : "none due yet"}`,
    view.auction && view.auctionPrice !== null
      ? `auction price ${musdText(view.auctionPrice)} MUSD, floor ${musdText(view.auction.floorPrice)}, floor time ${formatDateTime(floor as number)}`
      : "",
  ]
    .filter(Boolean)
    .join(" | ");
}

console.log(`\n== My loans for ${wallet}`);
const ids = await readWalletPositionIds(client, wallet);
console.log(`positions in Doji (live check on positionOf): ${ids.map((id) => `#${id}`).join(", ") || "none"}`);
const views = await readPositionViews(client, ids);
for (const view of views) console.log(line(view));

const claimables = await readClaimables(client, wallet);
console.log(`claimables: ${musdText(claimables.musd)} MUSD and ${btcText(claimables.btc)} BTC${claimables.musd > 0n || claimables.btc > 0n ? " (the Claim strip shows)" : " (no strip)"}`);

const wantedId = 389n;
const loan = views.find((view) => view.id === wantedId);
if (!loan) {
  console.log(`\nveBTC #${wantedId} is not held by this wallet, so the repay and roll checks are skipped`);
} else {
  const wallet20 = await readMusdWallet(client, wallet);
  console.log(`\n== Repay veBTC #${loan.id}`);
  console.log(`wallet MUSD ${musdText(wallet20.balance)}, allowance to LoanManager ${formatUnits(wallet20.allowance, 18)}`);
  console.log(`owed in full (exact) ${formatUnits(loan.owed, 18)} MUSD`);
  console.log(`steps: ${repaySteps(loan.owed, wallet20.allowance).map((step, index) => `${index + 1}. ${step.label}`).join("  ")}`);
  console.log(`steps with a zero allowance: ${repaySteps(loan.owed, 0n).map((step, index) => `${index + 1}. ${step.label}`).join("  ")}`);
  try {
    const call = approveMusdCall(loan.owed);
    await client.simulateContract({
      account: wallet,
      address: addressBook[31611][call.target],
      abi: call.abi,
      functionName: call.functionName,
      args: call.args,
    } as never);
    console.log(`approve(LoanManager, ${formatUnits(loan.owed, 18)}) on MUSD ${book.musd}: simulation ok`);
  } catch (error) {
    console.log(`approve(LoanManager, owed): simulation failed, ${(error as Error).message.split("\n")[0]}`);
  }

  console.log(`\n== Roll veBTC #${loan.id}`);
  const [settings, openOffers] = await Promise.all([readBorrowSettings(client), scanOpenOffers()]);
  const groups = groupOffersByDate(openOffers);
  const dates = rollDates(loan, settings.maxTermSeconds, now);
  console.log(
    `dates the roll sheet offers (later than ${formatDate(loan.loan.maturity)}, inside the lock or the longest term): ${dates.map(formatDate).join(", ") || "none"}`,
  );
  console.log(
    `lock ${loan.lock?.isPermanent ? "is permanent" : `ends ${loan.lock ? formatDate(loan.lock.end) : "?"}`}; longest term ${settings.maxTermSeconds / 86_400} days; borrows ${settings.borrowsPaused ? "paused" : "open"}`,
  );

  // The next later Thursday with offers, whether or not the lock allows it, so the quote and the contract's verdict show.
  const target = groups.find((group) => group.maturity > loan.loan.maturity);
  if (!target) {
    console.log("no later Thursday has open offers, so there is no roll quote");
  } else {
    // The default principal is what is owed, rounded down to the cent.
    const principal = (loan.owed / 10n ** 16n) * 10n ** 16n;
    const quote = await quoteRoll(client, { view: loan, group: target, principal });
    console.log(
      `roll to ${formatDate(target.maturity)} (${target.offers.length} offers, ${musdText(target.available)} MUSD, best ${formatApr(target.bestAprBps / 100)}), the sheet would list it: ${dates.includes(target.maturity) ? "yes" : "no"}`,
    );
    console.log(`  new principal ${musdText(principal)} MUSD (exact ${formatUnits(principal, 18)})`);
    console.log(`  offers used: ${quote.selection.offerIds.map((id, i) => `#${id} ${musdText(quote.selection.amounts[i] ?? 0n)} MUSD at ${formatApr((quote.selection.aprs[i] ?? 0) / 100)}`).join(", ")}; maxAprBps ${quote.selection.maxAprBps}`);
    console.log(`  new face ${musdText(quote.face)} MUSD, weighted rate ${formatApr(quote.aprBps / 100)} a year`);
    console.log(`  top-up ${formatUnits(quote.topUp, 18)} MUSD, paid out ${formatUnits(quote.excess, 18)} MUSD`);
    console.log(`  steps: ${rollSteps(quote.topUp, wallet20.allowance).map((step, index) => `${index + 1}. ${step.label}`).join("  ")}`);
    console.log(
      `  button check: ${rollProblem({ view: loan, settings, group: target, principal, quote, musdBalance: wallet20.balance }) ?? "all checks pass"}`,
    );
    try {
      const call = rollCall(loan.id, target.maturity, quote.selection, quote.topUp);
      await client.simulateContract({
        account: wallet,
        address: addressBook[31611][call.target],
        abi: call.abi,
        functionName: call.functionName,
        args: call.args,
      } as never);
      console.log("  roll simulated from the borrower's address: would go through");
    } catch (error) {
      console.log(`  roll simulated from the borrower's address: refused, "${explainError(error, { phase: "simulate" }).detail}"`);
    }
  }
}

console.log("\n== Public loan pages");
for (const id of [387n, 388n, 389n]) {
  const [view] = await readPositionViews(client, [id]);
  if (!view) continue;
  const opened = await readOpened(id).catch(() => "unavailable" as const);
  const hadLoan = opened !== null && opened !== "unavailable";
  console.log(`/loans/${id}`);
  console.log(`  title: Loan on veBTC #${id}`);
  console.log(`  subtitle: ${describeLoan(view, now, hadLoan)}`);
  console.log(`  borrower: ${view.borrower ? shortAddress(view.borrower) : "none"}`);
  console.log(
    `  opened: ${opened === "unavailable" ? "unavailable" : opened === null ? "no Borrowed log" : `${musdText(opened.principal)} MUSD, ${formatDateTime(opened.timestamp)}, tx ${opened.hash}`}`,
  );
  console.log(`  ${line(view)}`);
  if (view.loan.state !== 0) {
    console.log(
      `  terms: limit ${view.loan.maxLtvBps / 100}%, auction line ${view.loan.liqLtvBps / 100}%, floor ${view.loan.auctionFloorBps / 100}%, auction ${+(view.loan.auctionDuration / 3600).toFixed(2)}h, penalty ${view.loan.penaltyBps / 100}%`,
    );
    const market = await readMarket(client, view.loan.maturity);
    console.log(`  market: ${formatDate(view.loan.maturity)} market: ${musdText(market.lent)} MUSD lent, ${market.openLoans} open loans`);
  }
  if (view.auction && view.auctionPrice !== null) {
    const split = splitSale(view.auctionPrice, view.owed, view.auction.penaltyBps);
    const maxPay = maxPayFor(view.auctionPrice);
    const floorTime = view.auction.startTime + view.auction.duration;
    console.log(`  buy card: price ${musdText(view.auctionPrice)} MUSD, floor ${musdText(view.auction.floorPrice)}, ${now >= floorTime ? "at the floor" : `floor in ${formatCountdown(floorTime - now)}`}`);
    console.log(`  split: Lenders get ${musdText(split.toMarket)} MUSD · protocol ${musdText(split.toTreasury)} MUSD · borrower keeps ${musdText(split.toBorrower)} MUSD`);
    console.log(`  maxPay ${musdText(maxPay)} MUSD (price plus 1%); steps: ${[`Approve ${formatUnits(maxPay, 18)} MUSD`, "Buy"].join(", ")}`);
  }
  const actions = anyoneActions(view, now);
  console.log(`  anyone can run: ${actions.length === 0 ? "nothing right now" : actions.map((action) => `${action.label} (${action.why})`).join(" | ")}`);
}

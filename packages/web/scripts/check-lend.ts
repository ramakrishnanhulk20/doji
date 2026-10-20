import { createPublicClient, formatUnits, http, isAddress, parseUnits, type Address } from "viem";
import { addressBook } from "../src/lib/addresses";
import { thursdaysWithin } from "../src/lib/borrow";
import { mezoTestnetChain } from "../src/lib/chains";
import {
  OFFER_CANCELLED_TOPIC,
  OFFER_POSTED_TOPIC,
  approveMusdCall,
  claimUnitsCall,
  dateState,
  fmtBtcAmount,
  fmtPerUnit,
  offerStatus,
  quoteOffer,
  readCreditUnits,
  readLendSettings,
  readMusdWallet,
  readMyOffers,
  redeemAmounts,
  unitValue,
  withdrawalAmounts,
  type LendCall,
} from "../src/lib/lend";
import { formatApr, formatDate, formatMusd, readThursdayBoard } from "../src/lib/stats";

// Read-only: every call below is a view or an eth_call, and no key is involved.
const owner = process.env.CHECK_ADDRESS;
if (!owner || !isAddress(owner)) {
  console.error("Set CHECK_ADDRESS to the wallet address to check, for example CHECK_ADDRESS=0xd338... npx tsx scripts/check-lend.ts");
  process.exit(1);
}
const account: Address = owner;

const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const musd = (value: bigint) => formatMusd(Number(formatUnits(value, 18)));
const now = Math.floor(Date.now() / 1000);

console.log(`OfferPosted topic ${OFFER_POSTED_TOPIC}`);
console.log(`OfferCancelled topic ${OFFER_CANCELLED_TOPIC}`);

const settings = await readLendSettings(client);
console.log(
  `minimum offer ${musd(settings.minOffer)} MUSD, highest rate ${settings.maxAprBps / 100}%, protocol fee ${settings.feeShareBps / 100}% of the interest, longest term ${settings.maxTermSeconds / 86_400} days, offers ${settings.offersPaused ? "paused" : "open"}`,
);

const board = await readThursdayBoard(now);
for (const card of board) {
  console.log(
    `${formatDate(card.maturity)}: ${card.offerCount} open offers, ${formatMusd(card.musdOnOffer)} MUSD on offer, best ${card.bestAprBps === null ? "none" : formatApr(card.bestAprBps / 100)}, ${formatMusd(card.lent)} MUSD lent, ${card.openLoans} open loans`,
  );
}

const wallet = await readMusdWallet(client, account);
console.log(`wallet MUSD balance ${musd(wallet.balance)}, allowance to CreditMarkets ${musd(wallet.allowance)}`);

const offers = await readMyOffers(client, account);
console.log(`offers posted by this wallet: ${offers.length}`);
for (const offer of offers) {
  console.log(
    `  #${offer.id} due ${formatDate(offer.maturity)} at ${formatApr(offer.aprBps / 100)}: posted ${musd(offer.posted)}, left ${musd(offer.remaining)}, ${offerStatus(offer, now)}${offer.cancelled ? " (cancel log found)" : ""}`,
  );
}

const unitRows = await readCreditUnits(client, account, now, settings.maxTermSeconds);
console.log(`credit-unit dates with something for this wallet: ${unitRows.length}`);
for (const row of unitRows) {
  const state = dateState(row.market, row.maturity, now);
  const perUnit = unitValue(row.market);
  const withdraw = withdrawalAmounts(row.market, row.claim, row.balance);
  console.log(
    `  ${formatDate(row.maturity)} (${state}): holds ${musd(row.balance)} units, pending ${musd(row.pending)}, claim ${musd(row.claim.units)} units (paid ${musd(row.claim.musdPaid)} MUSD, ${fmtBtcAmount(row.claim.btcPaid)} BTC)`,
  );
  console.log(
    `    market: lent ${musd(row.market.faceTotal)}, collected ${musd(row.market.collectedMusd)} MUSD and ${fmtBtcAmount(row.market.collectedBtc)} BTC, open loans ${row.market.openLoans}, final ${row.market.isFinal}, paid out ${musd(row.paidOut.musd)} MUSD and ${fmtBtcAmount(row.paidOut.btc)} BTC`,
  );
  console.log(
    `    one unit now: ${fmtPerUnit(perUnit.musd)} MUSD + ${fmtPerUnit(perUnit.btc)} BTC; withdrawing all held units would pay ${musd(withdraw.musd)} MUSD and ${fmtBtcAmount(withdraw.btc)} BTC; redeeming them (if final) would pay ${musd(redeemAmounts(row.market, row.balance).musd)} MUSD`,
  );
}

const dates = thursdaysWithin(now, settings.maxTermSeconds);
const latest = dates[dates.length - 1];
if (latest === undefined) {
  console.log("no Thursday is open for new offers");
} else {
  const amount = parseUnits("20", 18);
  const quote = await quoteOffer(client, amount, 600, latest);
  console.log(
    `quote for 20 MUSD at 6.00% to ${formatDate(latest)}: face ${musd(quote.face)}, maker units ${musd(quote.makerUnits)}, treasury units ${musd(quote.treasuryUnits)}`,
  );
}

async function simulate(label: string, call: LendCall) {
  try {
    await client.simulateContract({
      account,
      address: call.address,
      abi: call.abi,
      functionName: call.functionName,
      args: call.args,
    } as never);
    console.log(`${label}: simulation ok`);
  } catch (error) {
    console.log(`${label}: simulation failed, ${(error as Error).message.split("\n")[0]}`);
  }
}

await simulate(`approve(CreditMarkets, 20 MUSD) from ${account}`, approveMusdCall(parseUnits("20", 18)));
const withPending = unitRows.find((row) => row.pending > 0n);
if (withPending) {
  await simulate(`claimUnits(${formatDate(withPending.maturity)}) with ${musd(withPending.pending)} pending`, claimUnitsCall(withPending.maturity));
} else {
  console.log("claimUnits: this wallet has no pending units on any date, so there is nothing to simulate");
}
console.log(`CreditMarkets ${addressBook[31611].creditMarkets}`);

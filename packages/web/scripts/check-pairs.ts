import { createPublicClient, formatUnits, http, isAddressEqual, parseAbi, type Address, type PublicClient } from "viem";
import { addressBook, legacyPair, wave2Pair, type PairKey } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import { readMyOffers } from "../src/lib/lend";
import { readLoanPair, readPositionViews, readWalletPositionIds, shortAddress } from "../src/lib/loans";
import { formatApr, formatDate, formatMusd, readOpenAuctions, scanPairOffers } from "../src/lib/stats";
import { buildClaimRewardsArgs, readVoterAddresses, readVotes, type ClaimPlan } from "../src/lib/votes";

// Read-only: every call below is a view or an explorer lookup. No key is involved and nothing is sent. Checks that
// depend on how the two pairs are told apart fail the run; lines marked "note" depend on live state that may move.
const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) }) as PublicClient;
const book = addressBook[31611];
const DEPLOYER: Address = "0xd338Ad588D6c3aE127FD5eEC6843A468d3a7aa6e";
const DEMO_BORROWER: Address = "0x92DcCb70C33300848Da555eDe8597d3F7037AE2b";
// The gauges of the MUSD/mT and mcbBTC/BTC pools that #411 votes for.
const EXPECTED_GAUGES: readonly Address[] = [
  "0x0DCFb9d7cc59F5Ac8bdB947963405e14d3CEdB8c",
  "0x7b30d8f43FBD957839edd707b5FD12B504faA4Cb",
];
const poolReads = parseAbi(["function symbol() view returns (string)", "function gauges(address pool) view returns (address)"]);
const keys: readonly PairKey[] = ["wave2", "legacy"];

let failures = 0;
const check = (ok: boolean, text: string) => {
  if (!ok) failures += 1;
  console.log(`  ${ok ? "ok" : "FAIL"}: ${text}`);
};
const note = (ok: boolean, text: string) => console.log(`  ${ok ? "note, as expected" : "note, differs"}: ${text}`);
const musd = (wei: bigint) => formatMusd(Number(formatUnits(wei, 18)));

console.log(`Wave 2 pair: LoanManager ${wave2Pair.loanManager}, CreditMarkets ${wave2Pair.creditMarkets}, from block ${wave2Pair.fromBlock}`);
console.log(`20 October pair: LoanManager ${legacyPair.loanManager}, CreditMarkets ${legacyPair.creditMarkets}, from block ${legacyPair.fromBlock}`);

for (const key of keys) {
  const offers = await scanPairOffers(key);
  console.log(`\n== Open offers on the ${key} pair: ${offers.length}`);
  for (const offer of offers) {
    console.log(`  #${offer.id} [${offer.pair}] ${formatDate(offer.maturity)} at ${formatApr(offer.aprBps / 100)}, ${musd(offer.remaining)} MUSD left`);
  }
  check(offers.every((offer) => offer.pair === key), `every offer is tagged ${key}`);
  const ids = offers.map((offer) => offer.id).join(", ");
  if (key === "wave2") {
    note(ids === "1, 2, 3", `Wave 2 open offer ids are ${ids || "none"} (expected 1, 2, 3)`);
    const two = offers.find((offer) => offer.id === 2n);
    note(two?.remaining === 30n * 10n ** 18n, `Wave 2 offer #2 has ${two ? musd(two.remaining) : "no"} MUSD left (expected 30.00)`);
  } else {
    note(ids === "8, 9, 10, 11", `20 October open offer ids are ${ids || "none"} (expected 8 to 11 while still open)`);
  }
}

console.log("\n== Loan-page pair lookup (veBTC.ownerOf)");
const lookups: [bigint, PairKey | null][] = [
  [411n, "wave2"],
  [401n, "legacy"],
  [1n, null],
];
for (const [id, expected] of lookups) {
  const pair = await readLoanPair(client, id);
  check((pair?.key ?? null) === expected, `#${id} is held by ${pair ? `the ${pair.key} LoanManager` : "neither LoanManager"} (expected ${expected ?? "neither"})`);
}

console.log("\n== readPositionViews");
const [view411, view401] = await readPositionViews(client, [
  { id: 411n, pair: "wave2" },
  { id: 401n, pair: "legacy" },
]);
for (const view of [view411, view401]) {
  if (!view) continue;
  console.log(
    `  #${view.id} [${view.pair}] borrower ${view.borrower ?? "none"}, reward operator ${view.rewardOperator ?? "none"}, loan state ${view.loan.state}, owed ${musd(view.owed)} MUSD, due ${formatDate(view.loan.maturity)}`,
  );
}
check(view411?.pair === "wave2", "#411 is tagged wave2");
check(
  view411?.rewardOperator !== null && view411?.rewardOperator !== undefined && isAddressEqual(view411.rewardOperator, book.payDown),
  `#411 names PayDown ${book.payDown} as its reward operator`,
);
check(view401?.pair === "legacy", "#401 is tagged legacy");
check(view401?.rewardOperator === null, "#401 has no reward operator (the 20 October record has none)");

console.log(`\n== My loans for the demo borrower ${shortAddress(DEMO_BORROWER)}`);
const refs = await readWalletPositionIds(client, DEMO_BORROWER);
console.log(`  ${refs.map((ref) => `#${ref.id} [${ref.pair}]`).join(", ") || "none"}`);
check(refs.some((ref) => ref.id === 411n && ref.pair === "wave2"), "#411 is listed on the wave2 pair");

console.log(`\n== readMyOffers for the Wave 2 deployer ${shortAddress(DEPLOYER)}`);
const mine = await readMyOffers(client, DEPLOYER);
for (const offer of mine) {
  console.log(
    `  [${offer.pair}] #${offer.id}${offer.parked ? " parked" : ""} ${formatDate(offer.maturity)} at ${formatApr(offer.aprBps / 100)}: posted ${musd(offer.posted)}, left ${musd(offer.remaining)}${offer.cancelled ? ", cancelled" : ""}`,
  );
}
check(mine.some((offer) => offer.pair === "wave2"), "offers from the wave2 pair are listed");
check(mine.some((offer) => offer.pair === "legacy"), "offers from the legacy pair are listed");
check(mine.filter((offer) => offer.pair === "legacy").every((offer) => !offer.parked), "no 20 October offer reads as parked");

console.log("\n== Open auctions on both pairs");
const auctions = await readOpenAuctions();
for (const auction of auctions) console.log(`  #${auction.tokenId} [${auction.pair}] at ${formatMusd(auction.price)} MUSD`);
if (auctions.length === 0) console.log("  none");
const auction401 = auctions.find((auction) => auction.tokenId === 401n);
note(auction401?.pair === "legacy", `#401 ${auction401 ? `is in auction on the ${auction401.pair} pair` : "is not in auction"} (expected legacy while its auction runs)`);
if (view401) check((view401.loan.state === 2) === (auction401 !== undefined), "the auction list agrees with #401's own loan state");

function printPlan(plan: ClaimPlan, label: string) {
  console.log(`  ${label}: ${plan.gauges.length} gauges${plan.truncated ? ", cut at 16 tokens" : ""}`);
  const symbols = new Map(plan.tokens.map((token) => [token.token.toLowerCase(), token.symbol]));
  const name = (token: Address) => symbols.get(token.toLowerCase()) ?? shortAddress(token);
  for (const [index, gauge] of plan.gauges.entries()) {
    console.log(
      `    gauge ${gauge}: fee tokens [${(plan.feeTokens[index] ?? []).map(name).join(", ")}], incentive tokens [${(plan.bribeTokens[index] ?? []).map(name).join(", ")}]`,
    );
  }
}

console.log("\n== Wave 2 claim plan for #411");
const voter = await readVoterAddresses(client);
const votes = await readVotes(client, voter.poolsVoter, voter.maxVotes, 411n);
const pools = votes.pools.map((entry) => entry.pool);
const symbols = await Promise.all(
  pools.map((pool) => client.readContract({ address: pool, abi: poolReads, functionName: "symbol" }).catch(() => "?")),
);
const gaugesOf = await Promise.all(
  pools.map((pool) => client.readContract({ address: voter.poolsVoter, abi: poolReads, functionName: "gauges", args: [pool] })),
);
pools.forEach((pool, index) => console.log(`  votes on pool ${symbols[index]} ${pool} (gauge ${gaugesOf[index]})`));
const wave2Plan = await buildClaimRewardsArgs(client, voter.poolsVoter, pools, "wave2");
printPlan(wave2Plan, "isReward rule (Wave 2)");
const legacyRulePlan = await buildClaimRewardsArgs(client, voter.poolsVoter, pools, "legacy");
printPlan(legacyRulePlan, "whitelist rule (20 October), for contrast");

check(wave2Plan.pair === "wave2", "the plan is built for the wave2 pair");
for (const expected of EXPECTED_GAUGES) {
  const index = gaugesOf.findIndex((gauge) => isAddressEqual(gauge, expected));
  const listed = wave2Plan.gauges.some((planned) => isAddressEqual(planned, expected));
  check(listed, `the plan claims from gauge ${expected} (${index >= 0 ? `pool ${symbols[index]}` : "no voted pool has it"})`);
}
const incentives = wave2Plan.bribeTokens.flat();
check(incentives.some((token) => isAddressEqual(token, book.musd)), "MUSD is among the incentive tokens");
check(incentives.some((token) => isAddressEqual(token, book.btc)), "BTC is among the incentive tokens");

console.log(`\n${failures === 0 ? "every pair check passed" : `${failures} pair checks failed`}`);
process.exit(failures === 0 ? 0 : 1);

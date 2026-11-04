import { createPublicClient, http } from "viem";
import { addressBook } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import {
  buildPayDownPlan,
  fixedText,
  harvestAndSwapCall,
  harvestedLine,
  ledgerShares,
  nextThursday,
  quoteHarvest,
  quoteSale,
  readHarvests,
  readOtherRewards,
  readPayDownState,
  saleSwaps,
  slippageText,
  soldLine,
  sumRepaid,
  tokenFixedText,
} from "../src/lib/paydown";
import { formatDate } from "../src/lib/stats";

// Read-only: every call below is a view, an eth_call, a dry run or an explorer lookup. No key is involved and nothing is sent.
const tokenId = BigInt(process.env.CHECK_TOKEN_ID ?? "411");
const zero = "0x0000000000000000000000000000000000000000";

const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const book = addressBook[31611];
const now = Math.floor(Date.now() / 1000);

console.log(`PayDown ${book.payDown}, position #${tokenId}`);

console.log("\n== readPayDownState");
const state = await readPayDownState(client, tokenId);
console.log(state);
console.log(`slippage line: ${slippageText(state.slippageBps)}%`);

console.log("\n== readHarvests");
const harvests = await readHarvests(client, tokenId);
console.log(`${harvests.length} harvest${harvests.length === 1 ? "" : "s"}${harvests.length === 0 ? " (none has run yet)" : ""}`);
for (const harvest of harvests) {
  console.log(
    `${formatDate(harvest.timestamp)} | ${fixedText(harvest.musdRepaid, 4)} MUSD repaid | ${fixedText(harvest.btcSold, 8)} BTC sold for ${fixedText(harvest.musdFromBtc, 4)} MUSD | caller ${harvest.caller} | tx ${harvest.hash}`,
  );
}
const total = sumRepaid(harvests);
console.log(`repaid by rewards: ${fixedText(total, 2)} MUSD`);
console.log(`ledger shares for a 100 MUSD face, 30 MUSD repaid: ${JSON.stringify(ledgerShares(100n * 10n ** 18n, 30n * 10n ** 18n, total))}`);
console.log(`sample done line: ${harvestedLine(tokenId, { musdRepaid: 12_345_678_000_000_000_000n, btcSold: 1_234_500_000_000_000n, musdFromBtc: 3_000_000_000_000_000_000n })}`);
console.log(`next harvest day: ${formatDate(nextThursday(now))}`);

console.log("\n== quoteHarvest from the zero address");
const quote = await quoteHarvest(client, tokenId, zero);
console.log(quote.kind === "ready" ? { kind: quote.kind, repaid: `${fixedText(quote.repaid, 4)} MUSD` } : quote);

// Fees and incentives count in `earned` only after their week finishes, so before Thu 5 Nov 00:00 UTC these lists can be empty.
console.log("\n== readOtherRewards");
for (const id of [412n, 411n]) {
  const plan = await buildPayDownPlan(client, id);
  const others = await readOtherRewards(client, id, plan);
  console.log(`#${id}: ${others.length} other reward token${others.length === 1 ? "" : "s"}${others.length === 0 ? " (none earned yet)" : ""}`);
  for (const reward of others) {
    console.log(`  ${tokenFixedText(reward.amount, reward.decimals, 4)} ${reward.symbol} (${reward.token})`);
  }
}

console.log("\n== quoteSale, 0.1 mT");
const mT = "0xdd8Bf5ACa0579bEE7e6cd20AC7683E279a5f7d48";
const sale = await quoteSale(client, mT, 100_000_000_000_000_000n);
if (sale === null) {
  console.log("no route pays anything");
} else {
  const hops = sale.routes.map((route) => `${route.from} -> ${route.to} (${route.stable ? "stable" : "volatile"}, factory ${route.factory})`);
  console.log(`route: ${hops.join(" then ")}`);
  console.log(`quoted ${fixedText(sale.quotedOut, 4)} MUSD, minimum ${fixedText(sale.amountOutMin, 4)} MUSD (${sale.amountOutMin} wei)`);
  const plan = await buildPayDownPlan(client, 412n);
  const call = harvestAndSwapCall(412n, plan, [sale]);
  console.log(`harvestAndSwap call: ${call.functionName}, ${call.args.length} arguments, ${(call.args[4] as unknown[]).length} swap`);
  const key = mT.toLowerCase();
  const raised = saleSwaps([sale], new Map([[key, sale.amountOutMin + 1n]]))[0];
  const kept = saleSwaps([sale], new Map([[key, sale.amountOutMin - 1n]]))[0];
  console.log(
    `saleSwaps: a higher minimum on screen is sent ${raised?.amountOutMin === sale.amountOutMin + 1n}, a lower one keeps the fresh minimum ${kept?.amountOutMin === sale.amountOutMin}, a token not on screen is left out ${saleSwaps([sale], new Map()).length === 0}`,
  );
  console.log(
    `sample done line: ${soldLine(412n, { musdRepaid: 12_345_678_000_000_000_000n, btcSold: 0n, musdFromBtc: 0n }, [{ token: mT, symbol: "mT", decimals: 18, amountIn: 100_000_000_000_000_000n, musdOut: sale.quotedOut }])}`,
  );
}

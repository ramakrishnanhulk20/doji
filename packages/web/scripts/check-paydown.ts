import { createPublicClient, http } from "viem";
import { addressBook } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import {
  fixedText,
  harvestedLine,
  ledgerShares,
  nextThursday,
  quoteHarvest,
  readHarvests,
  readPayDownState,
  slippageText,
  sumRepaid,
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

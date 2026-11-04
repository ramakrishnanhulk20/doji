import { createPublicClient, formatUnits, http, parseAbi } from "viem";
import { addressBook } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import { readHarvests, readRepaidByRewards, slippageText, sumRepaid } from "../src/lib/paydown";
import { formatMusd } from "../src/lib/stats";

// Read-only: the three numbers the landing page's Mezo section shows, read the way the page reads them.
const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const book = addressBook[31611];
const tokenId = BigInt(process.env.CHECK_TOKEN_ID ?? "411");

const musd = (wei: bigint) => `${formatMusd(Number(formatUnits(wei, 18)))} MUSD`;

const parked = await client.readContract({
  address: book.creditMarkets,
  abi: parseAbi(["function parkedPrincipal() view returns (uint256)"]),
  functionName: "parkedPrincipal",
});
console.log(`parkedPrincipal (Wave 2 CreditMarkets ${book.creditMarkets}): ${parked} wei = ${musd(parked)}`);

const slippageBps = await client.readContract({
  address: book.payDown,
  abi: parseAbi(["function slippageBps() view returns (uint16)"]),
  functionName: "slippageBps",
});
console.log(`slippageBps (PayDown ${book.payDown}): ${slippageBps} -> sentence says "${slippageText(slippageBps)}%"`);

const repaid = await readRepaidByRewards(client);
console.log(`readRepaidByRewards: ${repaid} wei = ${musd(repaid)}`);

// The per-position reader and the all-positions reader share one log source, so one position can never exceed the total.
const own = sumRepaid(await readHarvests(client, tokenId));
console.log(`position #${tokenId} alone: ${own} wei (${own <= repaid ? "within the total" : "ABOVE THE TOTAL, a bug"})`);

import {
  decodeEventLog,
  hexToBigInt,
  hexToNumber,
  pad,
  parseAbiItem,
  toEventSelector,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { addressBook, wave2Pair } from "./addresses";

// Kept apart from paydown.ts so the landing page can total harvests without loading the contract ABIs and the error
// decoder the loan page needs.

const book = addressBook[31611];

const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_MAX_CALLS = 20;
/** The testnet RPC refuses a log window wider than 10,000 blocks, so one block is left spare. */
const RPC_LOG_WINDOW = 9_999n;

export const harvestedEvent = parseAbiItem(
  "event Harvested(uint256 indexed tokenId, address indexed caller, uint256 musdRepaid, uint256 btcSold, uint256 musdFromBtc)",
);
export const HARVESTED_TOPIC = toEventSelector(harvestedEvent);

export const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();
export const tokenWord = (tokenId: bigint): Hex => pad(toHex(tokenId), { size: 32 });

export type Harvest = {
  hash: Hex;
  timestamp: number;
  caller: Address;
  musdRepaid: bigint;
  btcSold: bigint;
  musdFromBtc: bigint;
};

type HarvestRow = Harvest & { block: bigint; index: number };

type RawLog = {
  address: string;
  blockNumber: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  timeStamp: Hex;
  data: Hex;
  topics: (Hex | null)[];
};

const logKey = (hash: string, index: number) => `${hash.toLowerCase()}:${index}`;

/**
 * Every Harvested log PayDown emitted, from the explorer: for one position when a token is given, for all of them when
 * not. The explorer is asked for PayDown's address (and the token), and each log it returns is checked against the same
 * again, so a wrong answer is dropped, never counted.
 */
async function fetchExplorerHarvests(tokenId?: bigint): Promise<HarvestRow[]> {
  const word = tokenId === undefined ? null : tokenWord(tokenId);
  const seen = new Set<string>();
  const rows: HarvestRow[] = [];
  let start = wave2Pair.fromBlock;

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", book.payDown);
    url.searchParams.set("topic0", HARVESTED_TOPIC);
    if (word !== null) {
      url.searchParams.set("topic1", word);
      url.searchParams.set("topic0_1_opr", "and");
    }

    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as RawLog[]) : [];

    for (const raw of page) {
      if (typeof raw.address !== "string" || !sameAddress(raw.address, book.payDown)) continue;
      const [topic0, topic1] = raw.topics;
      if (!topic0 || topic0.toLowerCase() !== HARVESTED_TOPIC.toLowerCase()) continue;
      if (word !== null && (!topic1 || topic1.toLowerCase() !== word.toLowerCase())) continue;

      const block = hexToBigInt(raw.blockNumber);
      if (block > start) start = block;
      const index = hexToNumber(raw.logIndex);
      const key = logKey(raw.transactionHash, index);
      if (seen.has(key)) continue;
      seen.add(key);

      const topics = raw.topics.filter((topic): topic is Hex => topic !== null);
      const event = decodeEventLog({ abi: [harvestedEvent], data: raw.data, topics: topics as [Hex, ...Hex[]] });
      rows.push({
        hash: raw.transactionHash,
        timestamp: hexToNumber(raw.timeStamp),
        caller: event.args.caller,
        musdRepaid: event.args.musdRepaid,
        btcSold: event.args.btcSold,
        musdFromBtc: event.args.musdFromBtc,
        block,
        index,
      });
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
  }
  return rows;
}

/**
 * Every harvest PayDown ran for this position, newest first. The explorer gives the whole history from the Wave 2
 * deploy block; one node request over the newest blocks adds what the explorer has not indexed yet. A harvest that
 * both return is kept once.
 */
export async function readHarvests(client: PublicClient, tokenId: bigint): Promise<Harvest[]> {
  const latest = await client.getBlockNumber();
  const windowStart = latest > RPC_LOG_WINDOW ? latest - RPC_LOG_WINDOW : 0n;
  const [indexed, recent] = await Promise.all([
    fetchExplorerHarvests(tokenId),
    client.getLogs({
      address: book.payDown,
      event: harvestedEvent,
      args: { tokenId },
      fromBlock: windowStart > wave2Pair.fromBlock ? windowStart : wave2Pair.fromBlock,
      toBlock: latest,
    }),
  ]);

  const known = new Set(indexed.map((row) => logKey(row.hash, row.index)));
  const fresh = recent.filter(
    (log) =>
      sameAddress(log.address, book.payDown) &&
      log.transactionHash !== null &&
      log.blockNumber !== null &&
      !known.has(logKey(log.transactionHash, log.logIndex ?? 0)),
  );

  // The node's logs carry no time, so each new block is asked once.
  const blocks = [...new Set(fresh.map((log) => log.blockNumber as bigint))];
  const stamps = await Promise.all(blocks.map((blockNumber) => client.getBlock({ blockNumber })));
  const timeOf = new Map(blocks.map((block, position) => [block, Number(stamps[position]?.timestamp ?? 0n)]));

  const rows: HarvestRow[] = [
    ...indexed,
    ...fresh.map((log) => ({
      hash: log.transactionHash as Hex,
      timestamp: timeOf.get(log.blockNumber as bigint) ?? 0,
      caller: log.args.caller as Address,
      musdRepaid: log.args.musdRepaid as bigint,
      btcSold: log.args.btcSold as bigint,
      musdFromBtc: log.args.musdFromBtc as bigint,
      block: log.blockNumber as bigint,
      index: log.logIndex ?? 0,
    })),
  ];
  rows.sort((a, b) => (a.block === b.block ? b.index - a.index : a.block > b.block ? -1 : 1));
  return rows.map(({ block: _block, index: _index, ...harvest }) => harvest);
}

/**
 * How much MUSD harvests have repaid across every loan since the Wave 2 deploy. It reads the same two sources as
 * readHarvests, with no position filter, and counts a log that both return once.
 */
export async function readRepaidByRewards(client: PublicClient): Promise<bigint> {
  const latest = await client.getBlockNumber();
  const windowStart = latest > RPC_LOG_WINDOW ? latest - RPC_LOG_WINDOW : 0n;
  const [indexed, recent] = await Promise.all([
    fetchExplorerHarvests(),
    client.getLogs({
      address: book.payDown,
      event: harvestedEvent,
      fromBlock: windowStart > wave2Pair.fromBlock ? windowStart : wave2Pair.fromBlock,
      toBlock: latest,
    }),
  ]);

  const counted = new Set<string>();
  let total = 0n;
  for (const row of indexed) {
    const key = logKey(row.hash, row.index);
    if (counted.has(key)) continue;
    counted.add(key);
    total += row.musdRepaid;
  }
  for (const log of recent) {
    if (!sameAddress(log.address, book.payDown) || log.transactionHash === null) continue;
    const key = logKey(log.transactionHash, log.logIndex ?? 0);
    if (counted.has(key)) continue;
    counted.add(key);
    total += log.args.musdRepaid as bigint;
  }
  return total;
}

/** The allowance in percent for the card's sentence: 100 basis points read "1", 125 read "1.25". */
export const slippageText = (slippageBps: number): string => String(Number((slippageBps / 100).toFixed(2)));

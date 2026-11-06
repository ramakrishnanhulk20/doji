import { decodeEventLog, pad, toHex, type Address, type Hex } from "viem";
import { parseAddress } from "../address";
import { CONTRACTS, FROM_BLOCK, QUEST_EVENTS, eventAt, topicOf, type EventName, type QuestEvent } from "./table";

// One log shape and one decoder, whichever source supplied the log (C67). The explorer's decoded fields and labels are
// never read, so its answer can only ever be raw topics and data checked here.

// Hosts are constants, so nothing a caller or a reply says can point a request anywhere else (C72).
const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const RPC_URL = "https://rpc.test.mezo.org";

const REQUEST_TIMEOUT_MS = 10_000;
/** A full page of 1,000 logs measured 573 KB on the live explorer. */
const MAX_REPLY_BYTES = 4_000_000;
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_MAX_PAGES = 20;
/** The testnet RPC refuses a window wider than 10,000 blocks. Both ends are numbers, as nodes behind it differ by a few blocks. */
const RPC_WINDOW_SPAN = 9_999;
/** New blocks asked for their time in one read. Past this the read is incomplete rather than slow. */
const MAX_STAMPED_BLOCKS = 64;

export const MAX_CONCURRENT = 4;

export type NormalizedLog = {
  emitter: Address;
  topics: readonly Hex[];
  data: Hex;
  blockNumber: number;
  logIndex: number;
  hash: Hex;
  timestamp: number;
};

/** Logs with their completeness, kept together so an incomplete read cannot lose the flag on its way to EXP (C70). */
export type LogRead = { logs: readonly NormalizedLog[]; complete: boolean };

export type DecodedArgs = Record<string, Address | bigint | number | boolean>;
export type DecodedLog = { name: EventName; args: DecodedArgs; log: NormalizedLog };

const WORD = /^0x[0-9a-f]{64}$/;
const HEX_BYTES = /^0x([0-9a-f]{2})*$/;
const QUANTITY = /^0x[0-9a-f]+$/;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** A block number, index or time from a reply. Anything but a plain hex number is refused, so a URL cannot be a cursor. */
function quantity(value: unknown): number | null {
  if (typeof value !== "string" || !QUANTITY.test(value.toLowerCase())) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function word(value: unknown): Hex | null {
  if (typeof value !== "string") return null;
  const lower = value.toLowerCase();
  return WORD.test(lower) ? (lower as Hex) : null;
}

/**
 * The one log normaliser, for explorer, RPC and receipt logs alike. Returns null for a removed log or any field that is
 * not what it should be. `timestamp` is given for RPC logs: the node's own blockTimestamp reads 0x0 on Mezo, so the
 * block is asked instead.
 */
export function normalizeLog(raw: unknown, timestamp?: number): NormalizedLog | null {
  if (!isRecord(raw) || (raw.removed !== undefined && raw.removed !== false)) return null;
  const emitter = parseAddress(raw.address);
  const blockNumber = quantity(raw.blockNumber);
  const logIndex = quantity(raw.logIndex);
  const time = timestamp ?? quantity(raw.timeStamp);
  const hash = word(raw.transactionHash);
  const data = typeof raw.data === "string" ? raw.data.toLowerCase() : "";
  // The explorer pads unused topics with null, and only a null may be left out.
  const rawTopics = Array.isArray(raw.topics) ? raw.topics.filter((topic) => topic !== null) : [];
  const topics = rawTopics.map(word);
  if (emitter === null || blockNumber === null || logIndex === null || time === null || hash === null) return null;
  if (!HEX_BYTES.test(data) || topics.length === 0 || topics.length > 4 || topics.includes(null)) return null;
  return { emitter, topics: topics as Hex[], data: data as Hex, blockNumber, logIndex, hash, timestamp: time };
}

/**
 * The one decoder and the C67 gate: null unless the emitter and first topic are a table event at or after the deploy
 * block and the log decodes against that event's ABI. Every address field comes out in the C66 form.
 */
export function decodeQuestLog(log: NormalizedLog): DecodedLog | null {
  const event = eventAt(log.emitter, log.topics[0]);
  if (event === undefined || log.blockNumber < FROM_BLOCK) return null;
  try {
    const decoded = decodeEventLog({ abi: [event.abi], topics: log.topics as [Hex, ...Hex[]], data: log.data });
    const args: DecodedArgs = {};
    for (const [field, value] of Object.entries(decoded.args as Record<string, Address | bigint | number>)) {
      const address = typeof value === "string" ? parseAddress(value) : null;
      if (typeof value === "string" && address === null) return null;
      args[field] = address ?? value;
    }
    return { name: event.name, args, log };
  } catch {
    return null;
  }
}

/** Runs `work` over `items`, at most `limit` at a time, keeping the order of `items`. */
export async function mapLimit<T, R>(items: readonly T[], limit: number, work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = [];
  let next = 0;
  const runner = async () => {
    while (next < items.length) {
      const at = next;
      next += 1;
      results[at] = await work(items[at] as T);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, runner));
  return results;
}

const logKey = (log: NormalizedLog) => `${log.hash}:${log.logIndex}`;

/** All the logs, each once with the first copy kept, and complete only when every read was. */
export function mergeReads(reads: readonly LogRead[]): LogRead {
  const logs = new Map<string, NormalizedLog>();
  for (const read of reads) {
    for (const log of read.logs) if (!logs.has(logKey(log))) logs.set(logKey(log), log);
  }
  return { logs: [...logs.values()], complete: reads.every((read) => read.complete) };
}

/** The logs of `read` that `known` does not hold. */
export function unseenLogs(read: LogRead, known: LogRead): NormalizedLog[] {
  const seen = new Set(known.logs.map(logKey));
  return read.logs.filter((log) => !seen.has(logKey(log)));
}

/** The body of a reply, refused past the size cap before all of it is held in memory (C72). */
async function cappedText(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (reader === undefined) throw new Error("the reply has no body");
  const decoder = new TextDecoder();
  let text = "";
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return text + decoder.decode();
    size += value.length;
    if (size > MAX_REPLY_BYTES) {
      await reader.cancel();
      throw new Error("the reply is too large");
    }
    text += decoder.decode(value, { stream: true });
  }
}

/** Every outbound call goes through here: a redirect is an error, and time and size are capped (C72). */
async function fetchJson(url: URL | string, init: RequestInit = {}): Promise<unknown> {
  const response = await fetch(url, { ...init, redirect: "error", signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  if (!response.ok) throw new Error(`upstream answered ${response.status}`);
  return JSON.parse(await cappedText(response));
}

async function rpc(method: string, params: readonly unknown[]): Promise<unknown> {
  const reply = await fetchJson(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!isRecord(reply) || reply.error !== undefined || !("result" in reply)) throw new Error("the node refused the call");
  return reply.result;
}

type Match = { field: string; wallet: Address } | { field: string; id: bigint };

/** One event's logs, narrowed by at most one indexed wallet or id, or to one block. A query cannot carry free text. */
export type ExplorerQuery = { event: QuestEvent; match?: Match; block?: number };

function matchWord(match: Match): Hex {
  if ("id" in match) return pad(toHex(match.id), { size: 32 });
  const wallet = parseAddress(match.wallet);
  if (wallet === null) throw new Error("only a parsed address reaches an upstream URL");
  return pad(wallet.toLowerCase() as Hex, { size: 32 });
}

function explorerUrl({ event, match, block }: ExplorerQuery, fromBlock: number): URL {
  const url = new URL(EXPLORER_API);
  url.searchParams.set("module", "logs");
  url.searchParams.set("action", "getLogs");
  url.searchParams.set("fromBlock", fromBlock.toString());
  url.searchParams.set("toBlock", block === undefined ? "latest" : block.toString());
  url.searchParams.set("address", CONTRACTS[event.contract]);
  url.searchParams.set("topic0", event.topic0);
  if (match !== undefined) {
    const topic = topicOf(event, match.field);
    url.searchParams.set(`topic${topic}`, matchWord(match));
    url.searchParams.set(`topic0_${topic}_opr`, "and");
  }
  return url;
}

async function explorerPage(query: ExplorerQuery, fromBlock: number): Promise<unknown[]> {
  const reply = await fetchJson(explorerUrl(query, fromBlock));
  if (!isRecord(reply)) throw new Error("the explorer reply is not an object");
  if (Array.isArray(reply.result)) {
    if (reply.result.length > EXPLORER_PAGE_LOGS) throw new Error("the explorer page is over its size");
    return reply.result;
  }
  if (reply.message === "No logs found") return [];
  throw new Error("the explorer log listing failed");
}

/** True when a log is what the query asked for. Anything else means the reply fails C67. */
function answers(log: NormalizedLog, { event, match, block }: ExplorerQuery, fromBlock: number): boolean {
  if (log.emitter !== CONTRACTS[event.contract] || log.topics[0] !== event.topic0 || log.blockNumber < fromBlock) return false;
  if (block !== undefined && log.blockNumber !== block) return false;
  if (match !== undefined && log.topics[topicOf(event, match.field)] !== matchWord(match)) return false;
  return decodeQuestLog(log) !== null;
}

/**
 * Every log for one query since the deploy block, paged the way src/lib/harvests.ts does: the explorer returns 1,000
 * logs at most, oldest first, so the next page starts at the newest block seen, and a log both pages return is kept
 * once. The only value taken from a reply for paging is a block number checked as one, and no reply can name a URL.
 * A log that fails C67 is dropped and an error, timeout, redirect, bad log, page cap or passed `deadline` ends the read
 * as incomplete (C70, C72).
 */
export async function readExplorerLogs(query: ExplorerQuery, deadline = Number.POSITIVE_INFINITY): Promise<LogRead> {
  const logs: NormalizedLog[] = [];
  let start = query.block ?? FROM_BLOCK;

  for (let page = 0; page < EXPLORER_MAX_PAGES; page++) {
    if (Date.now() > deadline) return mergeReads([{ logs, complete: false }]);
    let rows: unknown[];
    try {
      rows = await explorerPage(query, start);
    } catch {
      return mergeReads([{ logs, complete: false }]);
    }

    let newest = start;
    for (const raw of rows) {
      const log = normalizeLog(raw);
      if (log === null || !answers(log, query, start)) return mergeReads([{ logs, complete: false }]);
      logs.push(log);
      if (log.blockNumber > newest) newest = log.blockNumber;
    }
    if (rows.length < EXPLORER_PAGE_LOGS) return mergeReads([{ logs, complete: true }]);
    // A full page inside one block cannot move the cursor, so the logs after it could never be reached.
    if (newest === start) break;
    start = newest;
  }
  return mergeReads([{ logs, complete: false }]);
}

/** The newest block the explorer has indexed, or null when it will not say. A reply supplies this one checked number. */
async function explorerHeight(): Promise<number | null> {
  try {
    const reply = await fetchJson(`${EXPLORER_API}/v2/blocks?type=block`);
    const newest: unknown = isRecord(reply) && Array.isArray(reply.items) ? reply.items[0] : undefined;
    const height = isRecord(newest) ? newest.height : undefined;
    return typeof height === "number" && Number.isSafeInteger(height) && height >= 0 ? height : null;
  } catch {
    return null;
  }
}

const NOT_READ: LogRead = { logs: [], complete: false };

/**
 * One node request for every table event over the newest 9,999 blocks, for what the explorer has not indexed yet (C70).
 * Topics cannot say "this wallet in whichever position", so it covers all wallets and the caller keeps what it needs.
 * Logs come back with timestamp 0, because their blocks are only worth asking about once a caller keeps them. No call
 * starts past `deadline`, so a scan lands within one timeout of it.
 */
export async function readRecentLogs(deadline = Number.POSITIVE_INFINITY): Promise<LogRead> {
  try {
    if (Date.now() > deadline) return NOT_READ;
    const latest = quantity(await rpc("eth_blockNumber", []));
    if (latest === null || Date.now() > deadline) return NOT_READ;
    // One after the other, because a wallet read gives this function a single one of its four slots.
    const height = await explorerHeight();
    if (Date.now() > deadline) return NOT_READ;
    const rows = await rpc("eth_getLogs", [
      {
        address: Object.values(CONTRACTS),
        topics: [QUEST_EVENTS.map((event) => event.topic0)],
        fromBlock: toHex(Math.max(latest - RPC_WINDOW_SPAN, FROM_BLOCK)),
        toBlock: toHex(latest),
      },
    ]);
    if (!Array.isArray(rows)) return NOT_READ;
    const logs: NormalizedLog[] = [];
    // Past that gap the two sources no longer meet, so logs between them cannot be seen.
    let complete = height !== null && height >= latest - RPC_WINDOW_SPAN;
    for (const raw of rows) {
      const log = normalizeLog(raw, 0);
      if (log !== null && decodeQuestLog(log) !== null) logs.push(log);
      else complete = false;
    }
    return { logs, complete };
  } catch {
    return NOT_READ;
  }
}

/**
 * True when the all-wallets scan could return this log. The node window cannot narrow by a `scan` field, so without this
 * a stranger's vote on Mezo's PoolsVoter looks like a log the explorer missed, and enough of them would fail every scan.
 */
export function inTheScan(log: NormalizedLog): boolean {
  const scan = eventAt(log.emitter, log.topics[0])?.scan;
  return scan === undefined || decodeQuestLog(log)?.args[scan.field] === scan.wallet;
}

async function blockTime(blockNumber: number): Promise<number | null> {
  try {
    const block = await rpc("eth_getBlockByNumber", [toHex(blockNumber), false]);
    return isRecord(block) ? quantity(block.timestamp) : null;
  } catch {
    return null;
  }
}

/**
 * The same logs with their block's time. A log whose block could not be read, or was not reached before `deadline`, is
 * left out and the read is incomplete.
 */
export async function stampLogs(logs: readonly NormalizedLog[], deadline = Number.POSITIVE_INFINITY): Promise<LogRead> {
  if (Date.now() > deadline) return NOT_READ;
  const blocks = [...new Set(logs.map((log) => log.blockNumber))];
  if (blocks.length > MAX_STAMPED_BLOCKS) return NOT_READ;
  const times = await mapLimit(blocks, MAX_CONCURRENT, async (block) => (Date.now() > deadline ? null : blockTime(block)));
  const timeOf = new Map(blocks.map((block, at) => [block, times[at] ?? null]));
  const stamped = logs.flatMap((log) => {
    const timestamp = timeOf.get(log.blockNumber) ?? null;
    return timestamp === null ? [] : [{ ...log, timestamp }];
  });
  return { logs: stamped, complete: stamped.length === logs.length };
}

/** The table-event logs in one transaction's receipt. A receipt also holds logs of other contracts, and those are skipped. */
export async function readReceiptLogs(hash: Hex, timestamp: number): Promise<LogRead> {
  try {
    const receipt = await rpc("eth_getTransactionReceipt", [hash]);
    if (!isRecord(receipt) || word(receipt.transactionHash) !== hash || !Array.isArray(receipt.logs)) {
      return { logs: [], complete: false };
    }
    const logs: NormalizedLog[] = [];
    for (const raw of receipt.logs) {
      const log = normalizeLog(raw, timestamp);
      if (log === null || log.hash !== hash) return { logs, complete: false };
      if (decodeQuestLog(log) !== null) logs.push(log);
    }
    return { logs, complete: true };
  } catch {
    return { logs: [], complete: false };
  }
}

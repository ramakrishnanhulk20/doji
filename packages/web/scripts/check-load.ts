import { registerHooks } from "node:module";
import { toEventSelector, toHex, type Hex } from "viem";
import { pairs } from "../src/lib/addresses";
import { mapLimit } from "../src/lib/quests/logs";
import { CONTRACTS, QUEST_EVENTS } from "../src/lib/quests/table";

// Times the app's full reads on the anvil fork that packages/contracts/script/load-fork.sh fills, for threat model C21
// and C81. Prints one `measure: <name> <value>` line per number. Run from packages/web with the fork up:
//   FORK_RPC_URL=http://127.0.0.1:8547 npx tsx scripts/check-load.ts
//
// The app's hosts are constants (C72), so the swap sits at the fetch boundary, as in check-quests.ts: the node's traffic
// goes to the fork, and explorer getLogs is answered here from the fork's logs, because the real explorer cannot see
// them. The explorer's height call answers the fork's head. The real URL builders, pagers, normaliser and decoders all run.
//
// What it does NOT measure: the real explorer's speed or its rate limiting, so seconds are fork seconds, and the call
// counts and pages are the numbers to rely on; the app's caching, so each count is one uncached read. scanOpenOffers
// filters on the computer's clock, not the fork's, so offers due 12 Nov still count as open after the time jump. Sends
// nothing.

const ALLOWED_FORK = "http://127.0.0.1:8547";
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_LIMIT_PER_MINUTE = 300;
const MINUTE_MS = 60_000;
/** The testnet node behind the fork refuses a wider window. */
const WINDOW_BLOCKS = 10_000;
const FORK_CONCURRENCY = 4;
/** The same budget as the leaderboard route's scan. */
const SCAN_BUDGET_MS = 45_000;
const FORK_TRIES = 5;
const FORK_RETRY_MS = 3_000;

const forkUrl = process.env.FORK_RPC_URL ?? "";
if (forkUrl !== ALLOWED_FORK) {
  console.error(`refusing to run: FORK_RPC_URL must be ${ALLOWED_FORK}`);
  process.exit(1);
}

// read-all.ts refuses to load outside a Next server build. tsx has no such swap, and the package is not installed.
registerHooks({
  resolve: (specifier, context, next) =>
    specifier === "server-only" ? { url: "data:text/javascript,", shortCircuit: true } : next(specifier, context),
});
const { readAllProgress } = await import("../src/lib/quests/read-all");
const { readOpenAuctions, scanOpenOffers } = await import("../src/lib/stats");

const realFetch = globalThis.fetch;
const out = (name: string, value: string | number) => console.log(`measure: ${name} ${value}`);

/** anvil passes what it does not hold to the testnet node, whose gateway answered a 502 page on 2026-11-06. */
async function throughFork(body: BodyInit | null): Promise<string> {
  for (let attempt = 1; ; attempt += 1) {
    const response = await realFetch(forkUrl, { method: "POST", headers: { "content-type": "application/json" }, body });
    const text = await response.text();
    if (!text.includes("Fork Error") || attempt === FORK_TRIES) return text;
    await new Promise((resolve) => setTimeout(resolve, FORK_RETRY_MS));
  }
}

async function fork(method: string, params: readonly unknown[]): Promise<unknown> {
  const text = await throughFork(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }));
  const reply = JSON.parse(text) as { result?: unknown; error?: unknown };
  if (reply.error !== undefined) throw new Error(`${method}: ${JSON.stringify(reply.error).slice(0, 500)}`);
  return reply.result;
}

type RpcLog = { address: string; topics: Hex[]; data: Hex; blockNumber: Hex; logIndex: Hex; transactionHash: Hex };
type ExplorerRow = RpcLog & { timeStamp: Hex };

/** Every log either read can ask the explorer for, loaded before any clock starts so the reads pay only for their own work. */
async function loadForkLogs(): Promise<ExplorerRow[]> {
  const head = Number(await fork("eth_blockNumber", []));
  const start = Math.min(...pairs.map((pair) => Number(pair.fromBlock)));
  const address = [...new Set([...Object.values(CONTRACTS), ...pairs.map((pair) => pair.loanManager)].map((a) => a.toLowerCase()))];
  const topic0s = [
    ...new Set([
      ...QUEST_EVENTS.map((event) => event.topic0),
      toEventSelector("Borrowed(uint256,address,uint64,uint256,uint256)"),
      toEventSelector("LoanClosed(uint256,uint64)"),
    ]),
  ];

  const windows: number[] = [];
  for (let from = start; from <= head; from += WINDOW_BLOCKS) windows.push(from);
  const pages = await mapLimit(windows, FORK_CONCURRENCY, async (from) => {
    const filter = { address, topics: [topic0s], fromBlock: toHex(from), toBlock: toHex(Math.min(from + WINDOW_BLOCKS - 1, head)) };
    return (await fork("eth_getLogs", [filter])) as RpcLog[];
  });
  const logs = pages.flat();

  const blocks = [...new Set(logs.map((log) => log.blockNumber))];
  const times = await mapLimit(blocks, FORK_CONCURRENCY, async (block) => {
    const read = (await fork("eth_getBlockByNumber", [block, false])) as { timestamp: Hex };
    return read.timestamp;
  });
  const timeOf = new Map(blocks.map((block, at) => [block, times[at] as Hex]));

  return logs
    .map((log) => ({
      address: log.address.toLowerCase(),
      topics: log.topics,
      data: log.data,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      transactionHash: log.transactionHash,
      timeStamp: timeOf.get(log.blockNumber) as Hex,
    }))
    .sort((a, b) => Number(a.blockNumber) - Number(b.blockNumber) || Number(a.logIndex) - Number(b.logIndex));
}

type Traffic = {
  nodeCalls: number;
  explorerCalls: number;
  heightCalls: number;
  explorerStamps: number[];
  explorerRows: number;
  fullPages: number;
  pagesPerQuery: Map<string, number>;
  largestNodeReply: number;
};

const freshTraffic = (): Traffic => ({
  nodeCalls: 0,
  explorerCalls: 0,
  heightCalls: 0,
  explorerStamps: [],
  explorerRows: 0,
  fullPages: 0,
  pagesPerQuery: new Map(),
  largestNodeReply: 0,
});

let traffic = freshTraffic();

/** One page, oldest first, capped as the real explorer caps it, so the app's pager runs for real. */
function explorerReply(rows: readonly ExplorerRow[], url: URL): Response {
  const from = Number(url.searchParams.get("fromBlock"));
  const to = url.searchParams.get("toBlock");
  const address = url.searchParams.get("address")?.toLowerCase();
  const wanted = [0, 1, 2, 3].map((topic) => url.searchParams.get(`topic${topic}`)?.toLowerCase() ?? null);
  const page = rows
    .filter((row) => row.address === address && Number(row.blockNumber) >= from && (to === "latest" || Number(row.blockNumber) <= Number(to)))
    .filter((row) => wanted.every((topic, at) => topic === null || row.topics[at]?.toLowerCase() === topic))
    .slice(0, EXPLORER_PAGE_LOGS);

  const query = `${address}:${wanted.join(":")}`;
  traffic.pagesPerQuery.set(query, (traffic.pagesPerQuery.get(query) ?? 0) + 1);
  traffic.explorerRows += page.length;
  if (page.length === EXPLORER_PAGE_LOGS) traffic.fullPages += 1;
  return Response.json(page.length === 0 ? { message: "No logs found", result: [], status: "0" } : { message: "OK", result: page, status: "1" });
}

const SEND_METHODS = new Set(["eth_sendRawTransaction", "eth_sendTransaction"]);

/** Anything but the node and explorer hosts, and any send, is refused rather than passed on. */
function standOnFork(rows: readonly ExplorerRow[]) {
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.host === "api.explorer.test.mezo.org") {
      traffic.explorerCalls += 1;
      traffic.explorerStamps.push(Date.now());
      if (url.pathname === "/api/v2/blocks") {
        traffic.heightCalls += 1;
        return Response.json({ items: [{ height: Number(await fork("eth_blockNumber", [])) }] });
      }
      if (url.searchParams.get("module") !== "logs" || url.searchParams.get("action") !== "getLogs") {
        return Response.json({ message: "not answered on the fork", status: "0" }, { status: 404 });
      }
      return explorerReply(rows, url);
    }
    if (url.host === "rpc.test.mezo.org") {
      const body = JSON.parse(String(init?.body)) as { method: string } | { method: string }[];
      const calls = Array.isArray(body) ? body : [body];
      if (calls.some((call) => SEND_METHODS.has(call.method))) throw new Error("a read tried to send a transaction");
      traffic.nodeCalls += calls.length;
      const text = await throughFork(init?.body ?? null);
      traffic.largestNodeReply = Math.max(traffic.largestNodeReply, text.length);
      return new Response(text, { status: 200, headers: { "content-type": "application/json" } });
    }
    throw new Error(`a read tried to reach ${url.host}`);
  }) as typeof fetch;
}

function busiestMinute(stamps: readonly number[]): number {
  let most = 0;
  let oldest = 0;
  stamps.forEach((stamp, at) => {
    while ((stamps[oldest] as number) <= stamp - MINUTE_MS) oldest += 1;
    most = Math.max(most, at - oldest + 1);
  });
  return most;
}

function reportTraffic(name: string, seconds: number) {
  out(`${name}_seconds`, seconds.toFixed(2));
  out(`${name}_node_calls`, traffic.nodeCalls);
  out(`${name}_largest_node_reply_bytes`, traffic.largestNodeReply);
  out(`${name}_explorer_calls`, traffic.explorerCalls);
  out(`${name}_explorer_height_calls`, traffic.heightCalls);
  out(`${name}_explorer_rows`, traffic.explorerRows);
  out(`${name}_explorer_full_pages`, traffic.fullPages);
  out(`${name}_explorer_most_pages_for_one_query`, Math.max(0, ...traffic.pagesPerQuery.values()));
  const busiest = busiestMinute(traffic.explorerStamps);
  out(`${name}_explorer_busiest_minute`, busiest);
  out(`${name}_explorer_over_${EXPLORER_LIMIT_PER_MINUTE}_a_minute`, busiest > EXPLORER_LIMIT_PER_MINUTE ? "YES" : "no");
}

async function measure<T>(name: string, read: () => Promise<T>): Promise<T> {
  traffic = freshTraffic();
  const started = performance.now();
  const value = await read();
  reportTraffic(name, (performance.now() - started) / 1000);
  return value;
}

const clientVersion = String(await fork("web3_clientVersion", []));
const chainId = Number(await fork("eth_chainId", []));
if (!clientVersion.toLowerCase().includes("anvil") || chainId !== 31611) {
  console.error(`refusing to run: ${forkUrl} is not an anvil fork of chain 31611`);
  process.exit(1);
}
out("fork_block", Number(await fork("eth_blockNumber", [])));

const loadStarted = performance.now();
const rows = await loadForkLogs();
out("explorer_stand_in_logs", rows.length);
out("explorer_stand_in_load_seconds", ((performance.now() - loadStarted) / 1000).toFixed(2));
standOnFork(rows);

let failed = false;
try {
  const offers = await measure("scanOpenOffers", () => scanOpenOffers());
  out("scanOpenOffers_open_offers", offers.length);

  const auctions = await measure("readOpenAuctions", () => readOpenAuctions());
  out("readOpenAuctions_auctions", auctions.length);

  const whole = await measure("readAllProgress", () => readAllProgress(Date.now() + SCAN_BUDGET_MS));
  out("readAllProgress_complete", String(whole.complete));
  out("readAllProgress_wallets", whole.wallets.length);
  if (!whole.complete) failed = true;
} catch (err) {
  failed = true;
  console.error(`a read failed: ${err instanceof Error ? err.message : String(err)}`);
}
globalThis.fetch = realFetch;

process.exitCode = failed ? 1 : 0;

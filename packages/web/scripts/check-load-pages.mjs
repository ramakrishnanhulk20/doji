import { createRequire } from "node:module";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, toEventSelector, toHex } from "viem";
import { pairs } from "../src/lib/addresses.ts";
import { mapLimit } from "../src/lib/quests/logs.ts";
import { CONTRACTS, QUEST_EVENTS } from "../src/lib/quests/table.ts";

// The offer and auction screens in headless Chrome at the load packages/contracts/script/load-fork.sh seeds, for threat
// model C21 and C81. Run from packages/web with the fork up and a dev server on port 3005:
//   FORK_RPC_URL=http://127.0.0.1:8547 SEED_FILE=<the fork's seed.json> npx tsx scripts/check-load-pages.mjs
//
// The app's hosts are constants (C72), so the swap sits in the browser's request stream: the node's traffic goes to the
// fork, and explorer getLogs is answered here from the fork's logs, because the real explorer cannot see them. The
// explorer's height call answers the fork's head, and a seeded wallet's public ledger is opened because it is the one
// screen here that makes that call. The page's clock moves to the fork's block time, in this script's pages only, so
// auctions and dates read as they would on that day. Prints one `measure:` line per page and width. Any send is refused
// and fails the run.
//
// What it does NOT cover: a wallet, so /lend's "Your offers" and every write stay out; the real explorer's and node's
// speed, because these are dev server seconds through request interception on a local fork, so compare them with each
// other and not with production; Mezo mainnet, which the fork does not hold, so the hero's locked BTC figure is refused
// and shows as unavailable. The server sends these pages with no chain read, so every number judged here is a
// browser read. The server reads that stay on the real testnet are the quest share image, /api/leaderboard and
// /api/faucet, none of which is opened here.

const HERE = path.dirname(fileURLToPath(import.meta.url));
// puppeteer-core is not one of the app's dependencies. PUPPETEER_HOME names any folder that has it installed.
const PUPPETEER_HOME = process.env.PUPPETEER_HOME ?? path.join(HERE, "../../../scratchpad/walk");
const puppeteer = createRequire(path.join(PUPPETEER_HOME, "package.json"))("puppeteer-core");
const CHROME = process.env.CHROME_PATH ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const BASE = process.env.CHECK_BASE ?? "http://localhost:3005";
const SHOTS = process.env.CHECK_SHOTS ?? path.join(HERE, "../../../scratchpad/l3");

const ALLOWED_FORK = "http://127.0.0.1:8547";
const EXPLORER_PAGE_LOGS = 1_000;
/** The testnet node behind the fork refuses a wider window. */
const WINDOW_BLOCKS = 10_000;
const FORK_CONCURRENCY = 4;
const NAVIGATION_TIMEOUT_MS = 180_000;
const ROWS_TIMEOUT_MS = 120_000;
const ROWS_POLL_MS = 100;
/** The screens read again every 15 seconds, so one full round runs under the load before a page is judged. */
const SETTLE_MS = 16_000;
/** The dev server restarts whenever next.config.ts changes, and a view cut off by that says nothing about the load. */
const VIEW_TRIES = 3;
const FORK_TRIES = 5;
const FORK_RETRY_MS = 3_000;

const VIEWPORTS = [
  { label: "1440x900", width: 1440, height: 900 },
  { label: "375x812", width: 375, height: 812, isMobile: true, hasTouch: true, deviceScaleFactor: 2 },
];

const forkUrl = process.env.FORK_RPC_URL ?? "";
if (forkUrl !== ALLOWED_FORK) {
  console.error(`refusing to run: FORK_RPC_URL must be ${ALLOWED_FORK}`);
  process.exit(1);
}
const seedFile = process.env.SEED_FILE ?? "";
if (seedFile === "") {
  console.error("refusing to run: SEED_FILE must name the seed.json load-fork.sh wrote");
  process.exit(1);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** anvil passes what it does not hold to the testnet node, whose gateway answered a 502 page on 2026-11-06. */
async function throughFork(body) {
  for (let attempt = 1; ; attempt += 1) {
    const response = await fetch(forkUrl, { method: "POST", headers: { "content-type": "application/json" }, body });
    const text = await response.text();
    if (!text.includes("Fork Error") || attempt === FORK_TRIES) return text;
    await sleep(FORK_RETRY_MS);
  }
}

async function fork(method, params) {
  const reply = JSON.parse(await throughFork(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params })));
  if (reply.error !== undefined) throw new Error(`${method}: ${JSON.stringify(reply.error).slice(0, 500)}`);
  return reply.result;
}

/** The same logs check-load.ts loads, read once so every page is answered from one view of the fork. */
async function loadForkLogs() {
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

  const windows = [];
  for (let from = start; from <= head; from += WINDOW_BLOCKS) windows.push(from);
  const pages = await mapLimit(windows, FORK_CONCURRENCY, async (from) => {
    const filter = { address, topics: [topic0s], fromBlock: toHex(from), toBlock: toHex(Math.min(from + WINDOW_BLOCKS - 1, head)) };
    return fork("eth_getLogs", [filter]);
  });
  const logs = pages.flat();

  const blocks = [...new Set(logs.map((log) => log.blockNumber))];
  const times = await mapLimit(blocks, FORK_CONCURRENCY, async (block) => {
    const read = await fork("eth_getBlockByNumber", [block, false]);
    return read.timestamp;
  });
  const timeOf = new Map(blocks.map((block, at) => [block, times[at]]));

  return logs
    .map((log) => ({
      address: log.address.toLowerCase(),
      topics: log.topics,
      data: log.data,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
      transactionHash: log.transactionHash,
      timeStamp: timeOf.get(log.blockNumber),
    }))
    .sort((a, b) => Number(a.blockNumber) - Number(b.blockNumber) || Number(a.logIndex) - Number(b.logIndex));
}

/** One page, oldest first, capped as the real explorer caps it, so the app's pager runs for real. */
function explorerReply(rows, url) {
  const from = Number(url.searchParams.get("fromBlock"));
  const to = url.searchParams.get("toBlock");
  const address = url.searchParams.get("address")?.toLowerCase();
  const wanted = [0, 1, 2, 3].map((topic) => url.searchParams.get(`topic${topic}`)?.toLowerCase() ?? null);
  const page = rows
    .filter((row) => row.address === address && Number(row.blockNumber) >= from && (to === "latest" || Number(row.blockNumber) <= Number(to)))
    .filter((row) => wanted.every((topic, at) => topic === null || row.topics[at]?.toLowerCase() === topic))
    .slice(0, EXPLORER_PAGE_LOGS);
  return page.length === 0 ? { message: "No logs found", result: [], status: "0" } : { message: "OK", result: page, status: "1" };
}

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" };
const sameOrigin = new URL(BASE).origin;

const failures = [];
const sendsTried = [];
/** Every request this check turned away. A console line about one of these is the check's doing, not the page's. */
const refused = new Map();
let heightCalls = 0;

function refuse(url) {
  const name = `${url.origin}${url.pathname}`;
  refused.set(name, (refused.get(name) ?? 0) + 1);
}

async function answerNode(request) {
  const body = request.postData() ?? (await request.fetchPostData());
  const parsed = JSON.parse(body);
  const calls = Array.isArray(parsed) ? parsed : [parsed];
  // A rule and not a list, so a send method nobody named here is refused too.
  const sending = calls.filter((call) => /send/i.test(String(call.method)));
  if (sending.length > 0) {
    sendsTried.push(...sending.map((call) => call.method));
    const denied = calls.map((call) => ({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "this check sends nothing" } }));
    return request.respond({ status: 200, headers: CORS, contentType: "application/json", body: JSON.stringify(Array.isArray(parsed) ? denied : denied[0]) });
  }
  return request.respond({ status: 200, headers: CORS, contentType: "application/json", body: await throughFork(body) });
}

async function answerExplorer(request, url, rows) {
  if (url.pathname === "/api/v2/blocks") {
    heightCalls += 1;
    const height = Number(await fork("eth_blockNumber", []));
    return request.respond({ status: 200, headers: CORS, contentType: "application/json", body: JSON.stringify({ items: [{ height }] }) });
  }
  if (url.searchParams.get("module") !== "logs" || url.searchParams.get("action") !== "getLogs") {
    refuse(url);
    return request.respond({ status: 404, headers: CORS, contentType: "application/json", body: JSON.stringify({ message: "not answered on the fork", status: "0" }) });
  }
  return request.respond({ status: 200, headers: CORS, contentType: "application/json", body: JSON.stringify(explorerReply(rows, url)) });
}

async function route(request, rows) {
  const url = new URL(request.url());
  if (!url.protocol.startsWith("http") || url.origin === sameOrigin) return request.continue();
  const ours = url.hostname === "rpc.test.mezo.org" || url.hostname === "api.explorer.test.mezo.org";
  if (ours && request.method() === "OPTIONS") return request.respond({ status: 204, headers: CORS });
  if (url.hostname === "rpc.test.mezo.org") return answerNode(request);
  if (url.hostname === "api.explorer.test.mezo.org") return answerExplorer(request, url, rows);
  refuse(url);
  return request.abort("blockedbyclient");
}

// Runs in the page before any of its own code. A proxy, so `new Date(x)`, `instanceof Date` and Date.UTC stay real.
function shiftClock(shiftMs) {
  const RealDate = Date;
  const shiftedNow = () => RealDate.now() + shiftMs;
  window.Date = new Proxy(RealDate, {
    construct: (target, args, newTarget) => Reflect.construct(target, args.length === 0 ? [shiftedNow()] : args, newTarget),
    apply: () => new RealDate(shiftedNow()).toString(),
    get: (target, key) => (key === "now" ? shiftedNow : Reflect.get(target, key)),
  });
}

const readBorrow = () => {
  const cards = [...document.querySelectorAll('.date-card[data-disabled="false"]')];
  const musd = cards.reduce((sum, card) => sum + Number(card.textContent.match(/([\d,.]+) MUSD available/)?.[1].replaceAll(",", "") ?? 0), 0);
  return { count: cards.length, text: `${cards.length} date cards with offers, ${musd.toFixed(2)} MUSD available` };
};

const readLend = () => {
  const cards = [...document.querySelectorAll(".date-card")].filter((card) => card.querySelector(".lend-best") !== null);
  const offers = cards.reduce((sum, card) => sum + Number(card.textContent.match(/(\d+) offers?/)?.[1] ?? 0), 0);
  return { count: offers, text: `${cards.length} date cards listing ${offers} offers` };
};

const readAuctions = () => {
  const links = document.querySelectorAll("#risk .chart-live a").length;
  const dots = document.querySelectorAll("#risk .chart-svg circle").length;
  return { count: Math.min(links, dots), text: `${links} auction links, ${dots} chart dots` };
};

const readLedger = () => {
  const exp = document.querySelector(".rank-header-exp");
  if (exp === null) return { count: 0, text: "ledger not read" };
  // RankHeader prints this note while any part of the read is incomplete, and a height it cannot use makes it incomplete.
  const partial = [...document.querySelectorAll(".rank-header-note")].some((note) => note.textContent.startsWith("Still reading"));
  return { count: partial ? 0 : 1, text: `ledger read ${partial ? "partly" : "in full"}, ${exp.textContent.trim()}` };
};

async function openView(context, viewport, view, rows, shiftMs) {
  const page = await context.newPage();
  await page.setViewport(viewport);
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error).slice(0, 300)));
  page.on("console", (message) => {
    if (message.type() !== "error") return;
    const source = message.location()?.url ?? "";
    const from = URL.canParse(source) ? new URL(source) : null;
    if (from !== null && refused.has(`${from.origin}${from.pathname}`)) return;
    errors.push(message.text().slice(0, 300));
  });
  await page.evaluateOnNewDocument(shiftClock, shiftMs);
  await page.setRequestInterception(true);
  page.on("request", (request) => {
    void route(request, rows).catch((error) => {
      if (page.isClosed()) return;
      failures.push(`stand-in failed for ${request.url()}: ${error}`);
      void request.abort("failed").catch(() => undefined);
    });
  });

  const started = performance.now();
  await page.goto(`${BASE}${view.route}`, { waitUntil: "domcontentloaded", timeout: NAVIGATION_TIMEOUT_MS });
  let shown = { count: 0, text: "nothing shown" };
  while (performance.now() - started < ROWS_TIMEOUT_MS && shown.count < view.wanted) {
    shown = await page.evaluate(view.read).catch(() => shown);
    if (shown.count < view.wanted) await sleep(ROWS_POLL_MS);
  }
  return { page, errors, seconds: (performance.now() - started) / 1000, shown };
}

async function measureView(context, viewport, view, rows, shiftMs) {
  const { page, errors, seconds, shown } = await openView(context, viewport, view, rows, shiftMs);
  await sleep(SETTLE_MS);
  // Next's own reload socket, which only exists in dev, drops when the server restarts. That voids the view, nothing more.
  if (errors.some((error) => error.includes("/_next/hmr"))) throw new Error("the dev server restarted during this view");
  const settled = await page.evaluate(view.read);
  const wide = await page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);

  const shot = path.join(SHOTS, `pages${view.route.replaceAll("/", "-")}${view.route === "/" ? "landing" : ""}-${viewport.label}.png`);
  if (view.section) {
    const section = await page.$(view.section);
    await section?.evaluate((item) => item.scrollIntoView());
    await sleep(1_500);
    await section?.screenshot({ path: shot });
  } else {
    await page.screenshot({ path: shot, fullPage: true });
  }

  const name = `${view.route} ${viewport.label}`;
  console.log(
    `measure: page ${name}: ${seconds.toFixed(2)} s until rows show, ${settled.text}, ${errors.length} console errors, horizontal overflow ${wide ? "yes" : "no"}`,
  );
  for (const error of errors) console.log(`console error on ${name}: ${error}`);
  if (shown.count < view.wanted || settled.count < view.wanted) failures.push(`${name} showed ${settled.text}, wanted at least ${view.wanted}`);
  if (errors.length > 0) failures.push(`${name} logged ${errors.length} console errors`);
  if (wide) failures.push(`${name} is wider than the viewport`);
}

async function serverIsBack() {
  const deadline = Date.now() + ROWS_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const up = await fetch(`${BASE}/favicon.svg`).then(
      (reply) => reply.ok,
      () => false,
    );
    if (up) return;
    await sleep(1_000);
  }
}

async function measureWithTries(browser, viewport, view, rows, shiftMs) {
  for (let attempt = 1; attempt <= VIEW_TRIES; attempt += 1) {
    const context = await browser.createBrowserContext();
    try {
      await measureView(context, viewport, view, rows, shiftMs);
      return;
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error);
      console.log(`measure: page ${view.route} ${viewport.label} try ${attempt} of ${VIEW_TRIES} voided: ${why}`);
      if (attempt === VIEW_TRIES) failures.push(`${view.route} ${viewport.label} never finished: ${why}`);
      await serverIsBack();
    } finally {
      await context.close();
    }
  }
}

const clientVersion = String(await fork("web3_clientVersion", []));
const chainId = Number(await fork("eth_chainId", []));
if (!clientVersion.toLowerCase().includes("anvil") || chainId !== 31611) {
  console.error(`refusing to run: ${forkUrl} is not an anvil fork of chain 31611`);
  process.exit(1);
}

const block = await fork("eth_getBlockByNumber", ["latest", false]);
const forkSeconds = Number(block.timestamp);
const shiftMs = forkSeconds * 1000 - Date.now();
console.log(`measure: page_clock ${new Date(forkSeconds * 1000).toISOString()}`);

const seed = JSON.parse(readFileSync(seedFile, "utf8"));
const openOffers = seed.offers.filter((offer) => offer.maturity > forkSeconds);
const startedAuctions = seed.loans.filter((loan) => loan.maturity <= forkSeconds).length;
console.log(`measure: seeded_offers_open_at_page_clock ${openOffers.length}`);
console.log(`measure: seeded_auctions_at_page_clock ${startedAuctions}`);

const rows = await loadForkLogs();
console.log(`measure: explorer_stand_in_logs ${rows.length}`);

const risk = await fetch(`${BASE}/risk`);
console.log(`measure: route_risk_status ${risk.status}`);
if (risk.status === 404) console.log("route /risk does not exist; the auction chart is the #risk section of /, so / is tested in its place");
else failures.push(`/risk answered ${risk.status}, so a route this check does not test now exists`);

const VIEWS = [
  { route: "/borrow", read: readBorrow, wanted: new Set(openOffers.map((offer) => offer.maturity)).size },
  { route: "/lend", read: readLend, wanted: openOffers.length },
  { route: "/", read: readAuctions, wanted: startedAuctions, section: "#risk" },
  { route: `/quests/${getAddress(seed.wallets[0])}`, read: readLedger, wanted: 1 },
];

mkdirSync(SHOTS, { recursive: true });
const profile = mkdtempSync(path.join(tmpdir(), "doji-load-pages-"));
const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: profile, args: ["--no-first-run"] });

try {
  // The first visit to a route makes the dev server compile it, which says nothing about the load.
  for (const view of VIEWS) {
    const context = await browser.createBrowserContext();
    const first = await openView(context, VIEWPORTS[0], view, rows, shiftMs).catch(() => null);
    console.log(`measure: page ${view.route} first load with compile ${first === null ? "cut off" : `${first.seconds.toFixed(2)} s`}, not counted`);
    await context.close();
  }
  for (const viewport of VIEWPORTS) {
    for (const view of VIEWS) await measureWithTries(browser, viewport, view, rows, shiftMs);
  }
} catch (error) {
  failures.push(`the page check stopped: ${error instanceof Error ? error.message : String(error)}`);
} finally {
  await browser.close();
  rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
}

for (const [name, count] of refused) console.log(`measure: refused_by_this_check ${name} ${count}`);
console.log(`measure: explorer_height_calls ${heightCalls}`);
if (heightCalls === 0) failures.push("no screen asked the explorer's height, so its stand-in never ran");
if (sendsTried.length > 0) failures.push(`a page tried to send: ${[...new Set(sendsTried)].join(", ")}`);
for (const failure of failures) console.error(`FAIL ${failure}`);
process.exit(failures.length > 0 ? 1 : 0);

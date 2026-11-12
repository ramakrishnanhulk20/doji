import { createRequire } from "node:module";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// The public wallet pages, the share image, the rankings under the book and the Lend warning, against a dev server on port
// 3005 whose output goes to the file named by CHECK_LOG (scans are counted there). Reads live Mezo testnet and sends nothing:
// the wallet in the browser is a stub and /api/faucet is watched, never reached.
// CHECK_MODE=outage is for a server whose explorer calls fail: it proves the card with no number and the rankings message.
// Not covered: the text inside the PNG, which is read by eye from the saved file, X's own crawler, Vercel's edge cache, a
// real wallet app, and a percent-encoded spelling such as /quests/%30x..., which Next decodes before the page can see it.

const HERE = path.dirname(fileURLToPath(import.meta.url));
// puppeteer-core is not one of the app's dependencies. PUPPETEER_HOME names any folder that has it installed.
const PUPPETEER_HOME = process.env.PUPPETEER_HOME ?? path.join(HERE, "../../../scratchpad/walk");
const puppeteer = createRequire(path.join(PUPPETEER_HOME, "package.json"))("puppeteer-core");
const CHROME = process.env.CHROME_PATH ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const BASE = process.env.CHECK_BASE ?? "http://localhost:3005";
const SHOTS = process.env.CHECK_SHOTS ?? path.join(HERE, "../../../scratchpad/q4c");
const OUTAGE = process.env.CHECK_MODE === "outage";
const LOG = process.env.CHECK_LOG;
if (!LOG) throw new Error("CHECK_LOG must name the dev server's output file");

const BORROWER = "0x92DcCb70C33300848Da555eDe8597d3F7037AE2b";
const BAD_CHECKSUM = "0x92DcCb70C33300848Da555eDe8597d3F7037AE2B";
const LOWER = BORROWER.toLowerCase();
const UPPER = `0x${BORROWER.slice(2).toUpperCase()}`;
const NO_EXP_ONE = "0x1111111111111111111111111111111111111111";
const NO_EXP_TWO = "0x2222222222222222222222222222222222222222";
const WALLET_A = "0x1111111111111111111111111111111111111111";
const SEED_DATE = "Thu 12 Nov";
const SHARED_CACHE = "public, s-maxage=60, stale-while-revalidate=60";
const PAPER_DIM = "rgb(185, 174, 156)";
const INK = "rgb(14, 12, 11)";
const BURST = 500;
const BURST_WIDTH = 16;
// Long enough for a scan already running when a burst ends to reach the log.
const SETTLE_MS = 9_000;
const REFUSED_LINE = "The rankings could not be read right now.";
const WARNING = "A Doji test loan on this date is going to auction, so payouts here can take a few extra days.";
const DOJI_LINE = "This wallet belongs to Doji.";
// Anything else in the log would mean a render reached out. The last two are Next's own dev server chatter.
const EXPECTED_HOSTS = new Set(["api.explorer.test.mezo.org", "rpc.test.mezo.org", "telemetry.nextjs.org", "registry.npmjs.org"]);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const failures = [];
function check(name, passed, detail) {
  console.log(`${passed ? "ok  " : "FAIL"} ${name}${!passed && detail !== undefined ? ` (${JSON.stringify(detail)})` : ""}`);
  if (!passed) failures.push(name);
}

const logText = () => readFileSync(LOG, "utf8");
const scanCount = () => logText().split("\n").filter((line) => line.includes("leaderboard scan:")).length;

/** One request with nothing rewritten by a client library, so a forged Host and an unescaped path reach the server. */
function rawGet(requestPath, headers = {}) {
  const { hostname, port } = new URL(BASE);
  return new Promise((resolve, reject) => {
    const request = http.request({ hostname, port, path: requestPath, headers }, (reply) => {
      const chunks = [];
      reply.on("data", (chunk) => chunks.push(chunk));
      reply.on("end", () => resolve({ status: reply.statusCode, headers: reply.headers, body: Buffer.concat(chunks) }));
    });
    request.on("error", reject);
    request.end();
  });
}

function pngSize(bytes) {
  const signature = bytes.subarray(0, 8).toString("hex") === "89504e470d0a1a0a";
  return signature ? { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) } : null;
}

const metaContent = (html, property) => html.match(new RegExp(`<meta (?:property|name)="${property}" content="([^"]*)"`))?.[1];

// A random id per request and Next's own echo of the URL in its router payload. Neither is shown or read by anything here.
function withoutFrameworkEcho(html, query) {
  return html.replace(/self\.__next_r="[^"]*"/, "").replaceAll(query, "");
}

/** The address cards are served under a hashed folder name, so the path comes from the page's own tag. */
async function imagePathFor(address) {
  const page = await rawGet(`/quests/${address}`);
  const tag = metaContent(page.body.toString("utf8"), "og:image");
  if (!tag) throw new Error(`no og:image on the page for ${address}`);
  return new URL(tag).pathname;
}

const imageOf = async (requestPath) => {
  const reply = await rawGet(requestPath);
  return { ...reply, size: reply.status === 200 ? pngSize(reply.body) : null };
};

async function refusalChecks(image) {
  const imageFolder = image.split("/").at(-1);
  const script = "<script>alert(1)</script>";
  const bad = [
    ["<script>", `/quests/${script}`],
    ["<script>, encoded", `/quests/${encodeURIComponent(script)}`],
    ["an encoded slash", "/quests/0x%2F..%2Fetc"],
    ["a 10 KB path", `/quests/${"a".repeat(10_240)}`],
    ["bad checksum", `/quests/${BAD_CHECKSUM}`],
  ];
  for (const [name, target] of bad) {
    const page = await rawGet(target);
    check(`${name} is a 404`, page.status === 404, page.status);
    check(`${name} is not echoed as markup`, !page.body.toString("utf8").includes(script));
    const card = await rawGet(`${target}/${imageFolder}`);
    check(`${name} has no image`, card.status === 404 && !String(card.headers["content-type"]).startsWith("image/"), card.status);
  }

  for (const spelling of [LOWER, UPPER]) {
    const reply = await rawGet(`/quests/${spelling}`, { Host: "evil.example", "X-Forwarded-Host": "evil.example" });
    const expected = `/quests/${BORROWER}`;
    check(`${spelling.slice(0, 8)}... redirects by a relative path, whatever Host says`, [307, 308].includes(reply.status) && reply.headers.location === expected, [reply.status, reply.headers.location]);
    const card = await rawGet(`/quests/${spelling}/${imageFolder}`);
    check(`${spelling.slice(0, 8)}... has no second image URL`, [307, 308].includes(card.status) && card.headers.location === expected, [card.status, card.headers.location]);
  }
}

async function metadataChecks() {
  const forged = (await rawGet(`/quests/${BORROWER}`, { Host: "evil.example", "X-Forwarded-Host": "evil.example" })).body.toString("utf8");
  check("the title is computed", forged.includes("<title>0x92Dc...AE2b on the Doji ledger</title>"));
  check("the description is the constant", metaContent(forged, "description") === "A wallet&#x27;s seals and rank in Doji&#x27;s quest ledger.");
  check("og:url uses the constant origin", metaContent(forged, "og:url") === `https://www.dojis.site/quests/${BORROWER}`, metaContent(forged, "og:url"));
  check("the card type is the large image", metaContent(forged, "twitter:card") === "summary_large_image");
  check("a forged Host reaches nothing on the page", !forged.includes("evil.example"));
}

async function queryChecks(image) {
  const plainImage = (await imageOf(image)).body;
  const plainPage = (await rawGet(`/quests/${BORROWER}`)).body.toString("utf8");
  for (const query of ["?exp=999999", "?rank=sobashi"]) {
    const card = await imageOf(`${image}${query}`);
    check(`${query} changes no byte of the image`, card.body.equals(plainImage));
    const page = (await rawGet(`/quests/${BORROWER}${query}`)).body.toString("utf8");
    check(`${query} changes nothing in the page but Next's own URL echo`, withoutFrameworkEcho(page, query) === withoutFrameworkEcho(plainPage, query));
    check(`${query} reaches no tag`, metaContent(page, "og:title") === metaContent(plainPage, "og:title") && metaContent(page, "og:image") === metaContent(plainPage, "og:image"));
  }
}

function burstTarget(index, image) {
  const lowerImage = image.replace(BORROWER, LOWER);
  const randomWallet = `0x${Array.from({ length: 40 }, () => Math.floor(Math.random() * 16).toString(16)).join("")}`;
  const targets = [`/quests/${BORROWER}`, `/quests/${LOWER}`, image, lowerImage, image.replace(BORROWER, randomWallet)];
  return `${targets[index % targets.length]}?n=${index}`;
}

async function sendAll(paths) {
  const queue = [...paths];
  const worker = async () => {
    for (let next = queue.pop(); next !== undefined; next = queue.pop()) await rawGet(next);
  };
  await Promise.all(Array.from({ length: BURST_WIDTH }, worker));
}

async function scanChecks(image) {
  const before = scanCount();
  const started = Date.now();
  await sendAll(Array.from({ length: BURST }, (_, index) => burstTarget(index, image)));
  const seconds = (Date.now() - started) / 1000;
  await sleep(SETTLE_MS);
  const scans = scanCount() - before;
  check(`${BURST} requests in ${seconds.toFixed(0)} s with distinct queries and spellings made ${scans} scan(s)`, scans <= 1 && seconds < 60, { scans, seconds });

  const beforeBoard = scanCount();
  await sendAll(Array.from({ length: 100 }, (_, index) => `/api/leaderboard?n=${index}`));
  await sleep(SETTLE_MS);
  const boardScans = scanCount() - beforeBoard;
  check(`100 distinct /api/leaderboard requests made ${boardScans} scan(s) of the route's own`, boardScans <= 1, boardScans);
}

async function imageChecks(image) {
  const reply = await imageOf(image);
  writeFileSync(path.join(SHOTS, "card-borrower.png"), reply.body);
  check("the borrower's image is a 1200 x 630 PNG", reply.size?.width === 1200 && reply.size?.height === 630, reply.size);
  check("the borrower's image is cached like the leaderboard", reply.headers["cache-control"] === SHARED_CACHE, reply.headers["cache-control"]);

  const one = await imageOf(image.replace(BORROWER, NO_EXP_ONE));
  const two = await imageOf(image.replace(BORROWER, NO_EXP_TWO));
  writeFileSync(path.join(SHOTS, "card-static.png"), one.body);
  check("a wallet with no EXP gets a 1200 x 630 PNG", one.size?.width === 1200 && one.size?.height === 630, one.size);
  check("every wallet with no EXP gets the same file", one.body.equals(two.body));
  check("the static card is not the borrower's card", !one.body.equals(reply.body));
}

async function headerChecks(image) {
  for (const target of ["/quests", `/quests/${BORROWER}`, image]) {
    const { headers } = await rawGet(target);
    check(`${target.slice(0, 28)}: no site may frame it`, headers["content-security-policy"] === "frame-ancestors 'none'" && headers["x-frame-options"] === "DENY", [headers["content-security-policy"], headers["x-frame-options"]]);
  }
}

function outboundChecks() {
  const hosts = new Set(logText().split("\n").flatMap((line) => line.match(/^outbound: (\S+)/)?.[1] ?? []));
  const strange = [...hosts].filter((host) => !EXPECTED_HOSTS.has(host));
  check("no render reached a host outside the Mezo explorer and RPC", strange.length === 0, strange);
}

// Runs in the page before any of its own code.
function pageStubs(wallet) {
  const listeners = {};
  window.__walletCalls = [];
  window.ethereum = {
    request: async ({ method }) => {
      window.__walletCalls.push(method);
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [wallet];
      if (method === "eth_chainId") return "0x7b7b";
      if (method === "wallet_switchEthereumChain") return null;
      throw Object.assign(new Error("not supported here"), { code: 4200 });
    },
    on: (event, run) => {
      (listeners[event] ??= []).push(run);
    },
    removeListener: (event, run) => {
      listeners[event] = (listeners[event] ?? []).filter((item) => item !== run);
    },
  };
}

async function hydrated(page) {
  await page.waitForFunction(
    () => {
      const pinned = matchMedia("(min-width: 1024px) and (min-height: 680px)").matches && !matchMedia("(prefers-reduced-motion: reduce)").matches;
      const stage = document.querySelector(pinned ? ".ledger-stage-pinned" : ".ledger-stage-flat");
      return stage !== null && Object.keys(stage).some((key) => key.startsWith("__reactFiber$"));
    },
    { timeout: 120_000 },
  );
}

async function connect(page) {
  await page.waitForSelector("button.wallet-button", { timeout: 60_000 });
  await page.evaluate(() => document.querySelector("button.wallet-button").click());
  await page.waitForSelector(".modal-card", { timeout: 10_000 });
  await page.evaluate(() => [...document.querySelectorAll("button.wallet-row")].find((item) => item.textContent.includes("Browser wallet")).click());
  await page.waitForSelector(".wallet-chip", { timeout: 15_000 });
}

async function slipActions(page) {
  const labels = await page.$$eval(".ledger-entry", (entries) => [...new Set(entries.map((entry) => entry.getAttribute("aria-label")))]);
  const found = [];
  for (const label of labels) {
    await page.evaluate((text) => {
      const entry = [...document.querySelectorAll(".ledger-entry")].find((item) => item.getAttribute("aria-label") === text);
      // A book page out of view is inert, and a dispatched click reaches its button all the same.
      entry.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    }, label);
    await page.waitForSelector('.ledger-slip-root[data-state="open"]', { timeout: 10_000 });
    found.push(
      await page.evaluate(() => {
        const slip = document.querySelector(".ledger-slip");
        return {
          steps: slip.querySelectorAll(".ledger-slip-steps li").length,
          claim: slip.querySelector(".ledger-claim") !== null,
          actions: [...slip.querySelectorAll("button, a")].map((item) => item.textContent.trim()).filter((text) => text !== "Close" && text !== "See the transaction"),
        };
      }),
    );
    await page.evaluate(() => document.querySelector(".ledger-slip-close").click());
    await page.waitForFunction(() => document.querySelector('.ledger-slip-root[data-state="open"]') === null, { timeout: 10_000 });
  }
  return found;
}

async function walletPageChecks(browser, label, viewport) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.setViewport(viewport);
  await page.evaluateOnNewDocument(pageStubs, WALLET_A);
  const faucetPosts = [];
  page.on("request", (request) => {
    if (request.url().endsWith("/api/faucet")) faucetPosts.push(request.url());
  });
  const crashes = [];
  page.on("pageerror", (error) => crashes.push(String(error)));

  await page.goto(`${BASE}/quests/${BORROWER}`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await hydrated(page);
  await connect(page);

  const owner = await page.evaluate(() => {
    const style = (selector) => {
      const item = document.querySelector(selector);
      const found = item && getComputedStyle(item);
      return found && { text: item.textContent, size: found.fontSize, color: found.color, transform: found.textTransform, family: found.fontFamily };
    };
    return { label: style(".wallet-owner-label"), address: style(".wallet-owner-address"), doji: style(".wallet-owner-doji") };
  });
  check(`${label}: connected as A on B's page, the page says whose it is`, owner.label?.text === "This ledger belongs to" && owner.address?.text === BORROWER, owner);
  check(`${label}: the label is 13 px mono uppercase in paper-dim`, owner.label?.size === "13px" && owner.label?.transform === "uppercase" && owner.label?.color === PAPER_DIM && /Plex Mono|plexMono/i.test(owner.label?.family ?? ""), owner.label);
  check(`${label}: the address is 15 px mono`, owner.address?.size === "15px", owner.address);
  check(`${label}: a Doji wallet says so`, owner.doji?.text === DOJI_LINE && owner.doji?.size === "13px" && owner.doji?.color === PAPER_DIM, owner.doji);

  await page.waitForSelector(".rank-header-exp", { timeout: 60_000 });
  await page.waitForFunction(() => /[1-9]/.test(document.querySelector(".rank-header-exp")?.textContent ?? ""), { timeout: 60_000 });
  await sleep(1_500);
  const standing = await page.evaluate(() => ({ name: document.querySelector(".rank-header-name")?.textContent, exp: document.querySelector(".rank-header-exp")?.textContent }));
  const exp = Number((standing.exp ?? "").replace(/[^0-9]/g, ""));
  check(`${label}: the borrower reads ${standing.name}, ${standing.exp}, Tedai or better and 750 EXP or more`, standing.name !== "Decchi" && exp >= 750, standing);
  await page.screenshot({ path: path.join(SHOTS, `wallet-${label}.png`) });

  const slips = await slipActions(page);
  check(`${label}: every entry opens, and shows its steps`, slips.length >= 10 && slips.every((slip) => slip.steps > 0), slips.length);
  check(`${label}: no slip offers a claim or a button on B's page`, slips.every((slip) => !slip.claim && slip.actions.length === 0), slips.filter((slip) => slip.claim || slip.actions.length > 0).slice(0, 3));
  const walletCalls = await page.evaluate(() => window.__walletCalls);
  check(`${label}: nothing was sent to the faucet or to the wallet to sign`, faucetPosts.length === 0 && !walletCalls.some((method) => /send|sign/i.test(method)), { faucetPosts, walletCalls });

  await page.goto(`${BASE}/quests/${NO_EXP_TWO}`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await hydrated(page);
  await page.waitForSelector(".wallet-chip", { timeout: 15_000 });
  const noDojiLine = await page.evaluate(() => document.querySelector(".wallet-owner-doji") === null);
  check(`${label}: a wallet not on the list has no Doji line`, noDojiLine);

  await page.goto(`${BASE}/quests/${WALLET_A}`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await hydrated(page);
  await page.waitForSelector(".wallet-chip", { timeout: 15_000 });
  await page.waitForFunction(() => document.querySelector(".wallet-owner-label") === null, { timeout: 15_000 });
  const ownSlips = await slipActions(page);
  check(`${label}: on A's own page A gets the quest page, with the claim and the buttons`, ownSlips.some((slip) => slip.claim) && ownSlips.some((slip) => slip.actions.length > 0), ownSlips.slice(0, 2));

  check(`${label}: no uncaught page errors`, crashes.length === 0, crashes.slice(0, 3));
  await context.close();
}

const goodRow = { place: 1, address: BORROWER, exp: 900, rank: "banto" };
const secondRow = { place: 2, address: WALLET_A, exp: 300, rank: "tedai" };

async function boardWith(browser, label, viewport, answer, inspect) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.setViewport(viewport);
  if (answer) {
    await page.setRequestInterception(true);
    page.on("request", (request) => {
      if (!request.url().endsWith("/api/leaderboard")) return void request.continue();
      void answer(request);
    });
  }
  await page.goto(`${BASE}/quests`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await hydrated(page);
  await inspect(page);
  await context.close();
}

const replyWith = (status, body) => (request) => request.respond({ status, contentType: "application/json", body: JSON.stringify(body) });

async function boardChecks(browser) {
  const now = Math.floor(Date.now() / 1000);
  const desktop = { width: 1440, height: 900 };

  if (!OUTAGE) {
    for (const [label, viewport] of [["1440", desktop], ["375", { width: 375, height: 812, isMobile: true, hasTouch: true }]]) {
      await boardWith(browser, label, viewport, null, async (page) => {
        await page.waitForSelector("#rankings .bz .bz-title", { timeout: 60_000 });
        await page.waitForFunction(() => document.querySelector("#rankings .shimmer") === null && document.querySelector("#rankings .bz-rule") !== null, { timeout: 60_000 });
        const section = await page.$("#rankings");
        await section.evaluate((item) => item.scrollIntoView({ block: "start" }));
        await sleep(1_500);
        const style = await section.evaluate((item) => {
          const found = getComputedStyle(item);
          return { padding: found.padding, background: found.backgroundColor };
        });
        check(`rankings at ${label}: section padding and ink background`, style.padding === "96px 24px" && style.background === INK, style);
        await section.screenshot({ path: path.join(SHOTS, `rankings-${label}.png`) });
      });
    }
  }

  const failedLine = async (page) => {
    await page.waitForSelector(".quest-board-failed", { timeout: 60_000 });
    return page.evaluate(() => {
      const line = document.querySelector(".quest-board-failed");
      const found = getComputedStyle(line);
      return { text: line.textContent, size: found.fontSize, color: found.color, board: document.querySelector("#rankings .bz") !== null };
    });
  };
  const refused = (name, seen) => check(`rankings: ${name} shows the one line and no board`, seen.text === REFUSED_LINE && seen.size === "15px" && seen.color === PAPER_DIM && !seen.board, seen);

  if (OUTAGE) {
    await boardWith(browser, "outage", desktop, null, async (page) => refused("a real 503", await failedLine(page)));
    return;
  }

  const badBoards = [
    ["a 503", 503, { code: "unavailable" }],
    ["an address with a bad checksum", 200, { asOf: now, rows: [{ ...goodRow, address: BAD_CHECKSUM }, secondRow] }],
    ["EXP as text", 200, { asOf: now, rows: [{ ...goodRow, exp: "900" }, secondRow] }],
    ["EXP that is not whole", 200, { asOf: now, rows: [{ ...goodRow, exp: 1.5 }, secondRow] }],
    ["an unknown rank", 200, { asOf: now, rows: [{ ...goodRow, rank: "shogun" }, secondRow] }],
    ["no rows field", 200, { asOf: now }],
  ];
  for (const [name, status, body] of badBoards) {
    await boardWith(browser, name, desktop, replyWith(status, body), async (page) => refused(name, await failedLine(page)));
  }

  const hourOld = now - 3_600;
  await boardWith(browser, "stale", desktop, replyWith(200, { asOf: hourOld, rows: [goodRow, secondRow] }), async (page) => {
    await page.waitForSelector(".quest-board-asof", { timeout: 60_000 });
    const line = await page.$eval(".quest-board-asof", (item) => ({ text: item.textContent, size: getComputedStyle(item).fontSize, color: getComputedStyle(item).color }));
    check("rankings: an old board says how old", /^As of \d{1,2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2} UTC\.$/.test(line.text) && line.size === "13px" && line.color === PAPER_DIM, line);
  });

  await boardWith(browser, "fresh", desktop, replyWith(200, { asOf: now, rows: [goodRow, secondRow] }), async (page) => {
    await page.waitForSelector("#rankings .bz-address", { timeout: 60_000 });
    check("rankings: a fresh board has no age line", (await page.$(".quest-board-asof")) === null);
  });

  await boardWith(browser, "slow", desktop, async (request) => {
    await sleep(6_000);
    await replyWith(200, { asOf: now, rows: [goodRow, secondRow] })(request);
  }, async (page) => {
    await page.waitForSelector("#rankings .quest-board-shimmer", { timeout: 60_000 });
    check("rankings: while loading, the sheet head and a shimmer", (await page.$("#rankings .bz-title")) !== null);
  });
}

async function lendChecks(browser) {
  for (const [label, viewport] of [["1440", { width: 1440, height: 900 }], ["375", { width: 375, height: 812, isMobile: true, hasTouch: true }]]) {
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    await page.setViewport(viewport);
    await page.goto(`${BASE}/lend`, { waitUntil: "domcontentloaded", timeout: 180_000 });
    await page.waitForSelector(".date-card", { timeout: 120_000 });
    const choose = (text) =>
      page.evaluate((wanted) => {
        const card = [...document.querySelectorAll(".date-card")].find((item) => (wanted === null ? !item.textContent.includes("12 Nov") : item.textContent.includes(wanted)));
        card?.querySelector("input")?.click();
        return card !== undefined;
      }, text);
    const warning = () => page.evaluate((line) => [...document.querySelectorAll(".field-note")].filter((item) => item.textContent === line).length, WARNING);

    check(`lend at ${label}: ${SEED_DATE} is on offer`, await choose(SEED_DATE));
    await sleep(600);
    check(`lend at ${label}: the warning shows on ${SEED_DATE}`, (await warning()) === 1);
    const step = await page.evaluateHandle(() => document.querySelector(".date-strip").closest("section"));
    await step.evaluate((item) => item.scrollIntoView({ block: "center" }));
    await sleep(400);
    await step.asElement().screenshot({ path: path.join(SHOTS, `lend-warning-${label}.png`) });
    check(`lend at ${label}: another Thursday is on offer`, await choose(null));
    await sleep(600);
    check(`lend at ${label}: the warning goes with the date`, (await warning()) === 0);
    await context.close();
  }
}

async function outageChecks(browser, image) {
  const borrower = await imageOf(image);
  const stranger = await imageOf(image.replace(BORROWER, NO_EXP_ONE));
  await sleep(SETTLE_MS);
  check("outage: the borrower gets the card with no number", borrower.size?.width === 1200 && borrower.body.equals(stranger.body));
  check("outage: that card is not cached as an answer", borrower.headers["cache-control"] === "no-store", borrower.headers["cache-control"]);
  const reference = readFileSync(path.join(SHOTS, "card-static.png"));
  check("outage: it is the same file a wallet with no EXP gets", borrower.body.equals(reference));
  await boardChecks(browser);
}

mkdirSync(SHOTS, { recursive: true });
const image = await imagePathFor(BORROWER);
const profile = mkdtempSync(path.join(tmpdir(), "check-share-"));
const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: profile, args: ["--no-first-run"] });
try {
  if (OUTAGE) {
    await outageChecks(browser, image);
  } else {
    await refusalChecks(image);
    await metadataChecks();
    await scanChecks(image);
    await queryChecks(image);
    await imageChecks(image);
    await headerChecks(image);
    await walletPageChecks(browser, "1440", { width: 1440, height: 900 });
    await walletPageChecks(browser, "375", { width: 375, height: 812, isMobile: true, hasTouch: true });
    await boardChecks(browser);
    await lendChecks(browser);
    outboundChecks();
  }
} finally {
  await browser.close();
  rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
}

if (failures.length > 0) {
  console.error(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");

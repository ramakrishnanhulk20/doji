import { createRequire } from "node:module";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { decodeFunctionData, encodeAbiParameters, encodeEventTopics, encodeFunctionResult, multicall3Abi, parseAbi, toFunctionSelector } from "viem";

// The claim step, live seals and rank-ups in headless Chrome against a dev server on port 3005, with the /api/faucet
// reply, the Mezo RPC, the explorer, Turnstile and the wallet all stubbed inside the browser. Needs no key and sends
// nothing. Quest reads are fed straight into the page's query cache, so QuestPage's detection runs on exact fixtures.
// A shortened timer flag exists only in this script's page context.
// Not covered: Cloudflare's real widget, the real /api/faucet route (scripts/check-faucet-route.ts proves that), and a
// real kit reaching a real wallet.

const HERE = path.dirname(fileURLToPath(import.meta.url));
// puppeteer-core is not one of the app's dependencies. PUPPETEER_HOME names any folder that has it installed.
const PUPPETEER_HOME = process.env.PUPPETEER_HOME ?? path.join(HERE, "../../../scratchpad/walk");
const puppeteer = createRequire(path.join(PUPPETEER_HOME, "package.json"))("puppeteer-core");
const CHROME = process.env.CHROME_PATH ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const BASE = process.env.CHECK_BASE ?? "http://localhost:3005";
const SHOTS = process.env.CHECK_SHOTS ?? null;

const FAUCET = readFileSync(path.join(HERE, "../src/generated/deployment.ts"), "utf8").match(/faucet: "(0x[0-9a-fA-F]{40})"/)?.[1];
if (!FAUCET) throw new Error("no faucet address in src/generated/deployment.ts");
const STRANGER = "0x4444444444444444444444444444444444444444";
const WALLET_A = "0x1111111111111111111111111111111111111111";
const WALLET_B = "0x2222222222222222222222222222222222222222";
const WALLET_C = "0x3333333333333333333333333333333333333333";
const HASH_ONE = `0x${"ab".repeat(32)}`;
const HASH_TWO = `0x${"cd".repeat(32)}`;
const HASH_THREE = `0x${"ef".repeat(32)}`;

const BTC_PER_CLAIM = 10n ** 15n;
const MUSD_PER_CLAIM = 25n * 10n ** 18n;
const POLL_MS = 3_000;
const LATE_POLL_MS = 10_000;

const CLAIMED_EVENT = parseAbi(["event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day)"]);
const SELECTORS = {
  claimed: toFunctionSelector("claimed(address)"),
  btcPerClaim: toFunctionSelector("btcPerClaim()"),
  musdPerClaim: toFunctionSelector("musdPerClaim()"),
};
const AGGREGATE3 = toFunctionSelector(multicall3Abi.find((item) => item.name === "aggregate3"));
const GET_ETH_BALANCE = toFunctionSelector("getEthBalance(address)");
const uint = (value) => encodeAbiParameters([{ type: "uint256" }], [value]);
const bool = (value) => encodeAbiParameters([{ type: "bool" }], [value]);

const claimedLog = (emitter, to) => ({
  address: emitter,
  topics: encodeEventTopics({ abi: CLAIMED_EVENT, eventName: "Claimed", args: { to, day: 20_000n } }),
  data: encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [BTC_PER_CLAIM, MUSD_PER_CLAIM]),
});
const receiptWith = (...logs) => ({ status: "0x1", blockNumber: "0x10", logs });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const failures = [];
function check(name, passed, detail) {
  console.log(`${passed ? "ok  " : "FAIL"} ${name}${!passed && detail !== undefined ? ` (${JSON.stringify(detail)})` : ""}`);
  if (!passed) failures.push(name);
}

// Runs in the page before any of its own code.
function pageStubs(wallet) {
  const realTimeout = window.setTimeout.bind(window);
  const shorter = { 15000: 800, 60000: 1500 };
  window.setTimeout = (run, ms, ...rest) => realTimeout(run, window.__shortTimers ? (shorter[ms] ?? ms) : ms, ...rest);

  const listeners = {};
  window.__wallet = wallet;
  window.ethereum = {
    request: async ({ method }) => {
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [window.__wallet];
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
  window.__switchWallet = (next) => {
    window.__wallet = next;
    (listeners.accountsChanged ?? []).forEach((run) => run([next]));
  };

  window.__opened = [];
  window.open = (url, target, features) => {
    window.__opened.push({ url, target, features });
    return null;
  };
}

const TURNSTILE_STUB = `
  (() => {
    let options = null;
    let count = 0;
    const solve = () => {
      if (window.__turnstileSilent) return;
      setTimeout(() => options.callback("stub-token-" + (count += 1)), 250);
    };
    window.__widgetCalls = [];
    window.turnstile = {
      render(host, given) {
        options = given;
        window.__widgetCalls.push("render");
        window.__widgetOptions = { sitekey: given.sitekey, action: given.action, theme: given.theme, appearance: given.appearance, inSlip: !!host.closest(".ledger-slip") };
        solve();
        return "stub-widget";
      },
      reset() {
        window.__widgetCalls.push("reset");
        solve();
      },
      remove() {
        window.__widgetCalls.push("remove");
      },
    };
  })();
`;

function freshWorld() {
  return {
    reply: { status: 503, body: { ok: false, code: "unavailable" } },
    replyDelayMs: 0,
    claimed: false,
    receipt: null,
    posts: [],
    turnstileRequests: 0,
    claimedReads: [],
    balanceReads: 0,
    questReads: 0,
  };
}

function readFaucet(world, bytes) {
  if (bytes.startsWith(SELECTORS.claimed)) {
    world.claimedReads.push(Date.now());
    return bool(world.claimed);
  }
  if (bytes.startsWith(SELECTORS.btcPerClaim)) return uint(BTC_PER_CLAIM);
  if (bytes.startsWith(SELECTORS.musdPerClaim)) return uint(MUSD_PER_CLAIM);
  return null;
}

// viem reads a BTC balance through the multicall contract's getEthBalance whenever multicall is on.
function readBalance(world) {
  world.balanceReads += 1;
  return uint(0n);
}

// wagmi's client gathers reads into one multicall, so a faucet read usually arrives wrapped in aggregate3.
function readThroughMulticall(world, bytes) {
  const { args } = decodeFunctionData({ abi: multicall3Abi, data: bytes });
  const results = args[0].map(({ target, callData }) => {
    const answer = callData.startsWith(GET_ETH_BALANCE)
      ? readBalance(world)
      : target.toLowerCase() === FAUCET.toLowerCase()
        ? readFaucet(world, callData)
        : null;
    return { success: answer !== null, returnData: answer ?? "0x" };
  });
  return encodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", result: results });
}

function answerRpc(world, call) {
  const answer = (result) => ({ jsonrpc: "2.0", id: call.id, result });
  const refuse = () => ({ jsonrpc: "2.0", id: call.id, error: { code: -32601, message: "stubbed" } });
  switch (call.method) {
    case "eth_chainId":
      return answer("0x7b7b");
    case "eth_blockNumber":
      return answer("0x100");
    case "eth_getBalance":
      world.balanceReads += 1;
      return answer("0x0");
    case "eth_getTransactionReceipt":
      return answer(world.receipt);
    case "eth_call": {
      const { to, data = "", input = "" } = call.params[0];
      const bytes = data || input;
      if (bytes.startsWith(AGGREGATE3)) return answer(readThroughMulticall(world, bytes));
      if (bytes.startsWith(GET_ETH_BALANCE)) return answer(readBalance(world));
      const read = to?.toLowerCase() === FAUCET.toLowerCase() ? readFaucet(world, bytes) : null;
      return read === null ? refuse() : answer(read);
    }
    default:
      return refuse();
  }
}

const CORS = { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "*" };

async function route(world, request) {
  const { hostname, pathname } = new URL(request.url());
  const isUpstream = hostname === "rpc.test.mezo.org" || hostname === "api.explorer.test.mezo.org";

  if (hostname === "challenges.cloudflare.com") {
    world.turnstileRequests += 1;
    return request.respond({ status: 200, contentType: "text/javascript", body: TURNSTILE_STUB });
  }
  if (isUpstream && request.method() === "OPTIONS") return request.respond({ status: 204, headers: CORS });
  if (hostname === "api.explorer.test.mezo.org") {
    world.questReads += 1;
    return request.respond({ status: 503, headers: CORS, contentType: "application/json", body: "{}" });
  }
  if (hostname === "rpc.test.mezo.org") {
    const body = JSON.parse(request.postData() ?? "{}");
    const answered = Array.isArray(body) ? body.map((call) => answerRpc(world, call)) : answerRpc(world, body);
    return request.respond({ status: 200, headers: CORS, contentType: "application/json", body: JSON.stringify(answered) });
  }
  if (pathname === "/api/faucet" && request.method() === "POST") {
    world.posts.push(JSON.parse(request.postData() ?? "{}"));
    if (world.replyDelayMs > 0) await sleep(world.replyDelayMs);
    const { reply } = world;
    if (reply === "drop") return request.abort("failed");
    if (reply === "junk") return request.respond({ status: 502, contentType: "text/html", body: "<html>gateway</html>" });
    return request.respond({ status: reply.status, contentType: "application/json", body: JSON.stringify(reply.body) });
  }
  return request.continue();
}

async function loadQuests(page, url = "/quests") {
  await page.goto(`${BASE}${url}`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await page.waitForFunction(
    () => {
      // The server always sends the flat layout, and a laptop swaps it for the pinned book once it has hydrated.
      const pinned = matchMedia("(min-width: 1024px) and (min-height: 680px)").matches && !matchMedia("(prefers-reduced-motion: reduce)").matches;
      const stage = document.querySelector(pinned ? ".ledger-stage-pinned" : ".ledger-stage-flat");
      return stage !== null && Object.keys(stage).some((key) => key.startsWith("__reactFiber$"));
    },
    { timeout: 120_000 },
  );
}

async function openKitSlip(page) {
  await page.evaluate(() => {
    const entry = [...document.querySelectorAll(".ledger-entry")].find((item) => item.getAttribute("aria-label")?.startsWith("Claim your starter kit"));
    // A book page out of view is inert, and a dispatched click reaches its button all the same.
    entry?.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  await page.waitForSelector('.ledger-slip-root[data-state="open"]', { timeout: 10_000 });
}

const closeSlip = (page) => page.evaluate(() => document.querySelector(".ledger-slip-close")?.click());

const claimButton = (page, label) =>
  page.waitForFunction(
    (text) => [...document.querySelectorAll(".ledger-claim button, button.ledger-slip-button")].some((item) => item.textContent.trim() === text),
    { timeout: 30_000 },
    label,
  );

async function press(page, label) {
  await claimButton(page, label);
  await page.evaluate((text) => {
    [...document.querySelectorAll(".ledger-claim button, button.ledger-slip-button")].find((item) => item.textContent.trim() === text)?.click();
  }, label);
}

const claimText = (page) => page.evaluate(() => document.querySelector(".ledger-claim")?.textContent ?? "");

const waitForLine = (page, line, timeout = 15_000) =>
  page
    .waitForFunction((text) => [...document.querySelectorAll(".ledger-claim-line")].some((item) => item.textContent === text), { timeout }, line)
    .then(
      () => true,
      () => false,
    );

const waitForWorking = (page, line, timeout = 15_000) =>
  page
    .waitForFunction((text) => document.querySelector(".ledger-claim-working span")?.textContent === text, { timeout }, line)
    .then(
      () => true,
      () => false,
    );

const hasTryAgain = (page) => page.evaluate(() => [...document.querySelectorAll(".ledger-claim button")].some((item) => item.textContent.trim() === "Try again"));

async function connectFromModal(page) {
  await page.waitForSelector(".modal-card", { timeout: 10_000 });
  const onTop = await page.evaluate(() => {
    const row = [...document.querySelectorAll("button.wallet-row")].find((item) => item.textContent.includes("Browser wallet"));
    const box = row.getBoundingClientRect();
    const top = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
    row.click();
    return row.contains(top);
  });
  await page.waitForFunction(() => document.querySelector(".modal-card") === null, { timeout: 10_000 });
  return onTop;
}

async function claimChecks(page, world, label) {
  await loadQuests(page);
  await openKitSlip(page);
  await claimButton(page, "Connect wallet");
  check(`${label}: no wallet shows Connect wallet`, true);
  await press(page, "Connect wallet");
  check(`${label}: the connect window sits over the slip`, await connectFromModal(page));

  await claimButton(page, "Claim");
  const idle = await claimText(page);
  check(`${label}: idle shows Claim and the fee line, nothing else`, idle === "ClaimFree. Doji pays the fee.", idle);
  const help = await page.$eval(".ledger-claim-help", (item) => ({ size: getComputedStyle(item).fontSize, color: getComputedStyle(item).color }));
  check(`${label}: fee line is 14px soft ink`, help.size === "14px" && help.color === "rgba(28, 24, 21, 0.62)", help);
  const tag = await page.evaluate(() => document.querySelector('script[src*="turnstile"]') !== null);
  check(`${label}: no Turnstile request or script before Claim is pressed`, world.turnstileRequests === 0 && !tag, world.turnstileRequests);

  world.reply = { status: 429, body: { ok: false, code: "busy" } };
  world.replyDelayMs = 700;
  await press(page, "Claim");
  check(`${label}: label one`, await waitForWorking(page, "Checking you are a person."));
  const working = await page.$eval(".ledger-claim-working", (item) => ({
    size: getComputedStyle(item).fontSize,
    color: getComputedStyle(item).color,
    seal: item.querySelector("svg")?.getAttribute("width"),
  }));
  check(`${label}: labels are 14px ink beside the busy seal at 18`, working.size === "14px" && working.color === "rgb(28, 24, 21)" && working.seal === "18", working);
  check(`${label}: label two`, await waitForWorking(page, "Sending your kit."));
  world.replyDelayMs = 0;
  check(`${label}: Turnstile loaded on the press`, world.turnstileRequests === 1, world.turnstileRequests);
  const options = await page.evaluate(() => window.__widgetOptions);
  check(
    `${label}: the widget has the right options, in the slip`,
    options?.action === "faucet" && options?.theme === "light" && options?.appearance === "interaction-only" && options?.inSlip === true && Boolean(options?.sitekey),
    options,
  );

  const now = () => Math.floor(Date.now() / 1000);
  const refusals = [
    ["busy", () => ({ status: 429, body: { ok: false, code: "busy" } }), "Lots of claims at once. Try again in a few seconds."],
    ["none_open", () => ({ status: 429, body: { ok: false, code: "none_open", nextOpenAt: now() + 1800 } }), "The next kit opens in about 30 minutes."],
    ["none_open minimum", () => ({ status: 429, body: { ok: false, code: "none_open", nextOpenAt: now() - 100 } }), "The next kit opens in about 1 minute."],
    ["faucet_empty", () => ({ status: 503, body: { ok: false, code: "faucet_empty" } }), "The faucet is being refilled. Try again soon."],
    ["paused", () => ({ status: 503, body: { ok: false, code: "paused" } }), "The faucet is paused for a moment. Try again soon."],
    ["bot_check_failed", () => ({ status: 403, body: { ok: false, code: "bot_check_failed" } }), "The check did not pass. Try again."],
    ["unavailable", () => ({ status: 503, body: { ok: false, code: "unavailable" } }), "The faucet is not answering right now. Try again soon."],
    ["bad_request", () => ({ status: 400, body: { ok: false, code: "bad_request" } }), "The faucet is not answering right now. Try again soon."],
    ["a page that is not JSON", () => "junk", "The faucet is not answering right now. Try again soon."],
    ["a network error", () => "drop", "The faucet is not answering right now. Try again soon."],
    ["an unknown code", () => ({ status: 500, body: { ok: false, code: "rpc failed at https://node.example" } }), "The faucet is not answering right now. Try again soon."],
    ["none_open with no time", () => ({ status: 429, body: { ok: false, code: "none_open" } }), "The faucet is not answering right now. Try again soon."],
    ["a hash that is not a hash", () => ({ status: 200, body: { ok: true, hash: '"><img src=x onerror=alert(1)>' } }), "The faucet is not answering right now. Try again soon."],
    ["a short hash", () => ({ status: 200, body: { ok: true, hash: "0xabcd" } }), "The faucet is not answering right now. Try again soon."],
  ];
  // The busy reply from the labels above is already on its way, so the first row checks it with no new press.
  let first = true;
  for (const [name, reply, line] of refusals) {
    if (!first) {
      world.reply = reply();
      await press(page, "Try again");
      const cleared = !(await page.evaluate((text) => [...document.querySelectorAll(".ledger-claim-line")].some((item) => item.textContent === text), line));
      check(`${label}: Try again clears the old line before ${name}`, cleared);
    }
    first = false;
    check(`${label}: ${name} reads exactly`, await waitForLine(page, line), await claimText(page));
    check(`${label}: ${name} offers Try again`, await hasTryAgain(page));
    check(`${label}: ${name} puts no link on the page`, (await page.$$eval(".ledger-claim a", (links) => links.length)) === 0);
  }

  const widgetCalls = await page.evaluate(() => window.__widgetCalls);
  const tokens = world.posts.map((post) => post.turnstileToken);
  check(`${label}: Turnstile loaded once however many tries`, world.turnstileRequests === 1, world.turnstileRequests);
  check(`${label}: one render, then a widget reset for every retry`, widgetCalls[0] === "render" && widgetCalls.slice(1).every((call) => call === "reset") && widgetCalls.length === refusals.length, widgetCalls);
  check(`${label}: every POST carried a fresh token`, new Set(tokens).size === tokens.length && tokens.length === refusals.length, tokens.length);
  check(`${label}: every POST named the connected wallet alone`, world.posts.every((post) => post.address === WALLET_A && Object.keys(post).length === 2), world.posts[0]);

  await page.evaluate(() => {
    window.__shortTimers = true;
    window.__turnstileSilent = true;
  });
  await press(page, "Try again");
  check(`${label}: a widget that never answers ends in the unavailable line`, await waitForLine(page, "The faucet is not answering right now. Try again soon."));
  await page.evaluate(() => {
    window.__shortTimers = false;
    window.__turnstileSilent = false;
  });
  const dropped = await page.evaluate(() => window.__widgetCalls.at(-1));
  check(`${label}: the timed out widget is removed`, dropped === "remove", dropped);
  const posted = world.posts.length;
  world.reply = { status: 409, body: { ok: false, code: "already_claimed" } };
  await press(page, "Try again");
  check(`${label}: already_claimed reads exactly`, await waitForLine(page, "This wallet already claimed its kit."));
  check(`${label}: a widget that timed out is drawn fresh`, (await page.evaluate(() => window.__widgetCalls.at(-1))) === "render");
  check(`${label}: already_claimed offers no Try again`, !(await hasTryAgain(page)) && world.posts.length === posted + 1);
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${label}-refusal.png`) });

  await loadQuests(page);
  await openKitSlip(page);
  await claimButton(page, "Claim");
  world.reply = { status: 200, body: { ok: true, hash: HASH_ONE } };
  world.claimedReads.length = 0;
  await press(page, "Claim");
  check(`${label}: label three`, await waitForWorking(page, "Waiting for Mezo to confirm."));
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${label}-confirming.png`) });
  const pollStart = world.claimedReads.length;
  await sleep(POLL_MS * 2 + 1_000);
  check(`${label}: a hash alone is never success`, !(await claimText(page)).includes("landed"), await claimText(page));
  const polls = world.claimedReads.length - pollStart;
  check(`${label}: claimed is polled about every 3 s`, polls >= 2 && polls <= 4, polls);

  world.receipt = receiptWith(claimedLog(STRANGER, WALLET_A));
  await sleep(POLL_MS + 500);
  check(`${label}: a Claimed log from another contract proves nothing`, !(await claimText(page)).includes("landed"));
  world.receipt = receiptWith(claimedLog(FAUCET, WALLET_B));
  await sleep(POLL_MS + 500);
  check(`${label}: a Claimed log naming another wallet proves nothing`, !(await claimText(page)).includes("landed"));
  world.receipt = null;

  const balancesBefore = world.balanceReads;
  const questsBefore = world.questReads;
  world.claimed = true;
  check(`${label}: claimed true shows the success line`, await waitForLine(page, "Your kit has landed."));
  check(`${label}: amounts come from the faucet`, await waitForLine(page, "0.001 test BTC and 25 test MUSD are in your wallet."), await claimText(page));
  const success = await page.$eval(".ledger-claim-line", (item) => ({ size: getComputedStyle(item).fontSize, color: getComputedStyle(item).color }));
  check(`${label}: success is 15px ink`, success.size === "15px" && success.color === "rgb(28, 24, 21)", success);
  const link = await page.$eval(".ledger-claim a", (item) => ({ href: item.href, text: item.textContent, target: item.target, rel: item.rel, drawn: item.classList.contains("link-draw") }));
  check(
    `${label}: the link uses the checked hash and carries no opener`,
    link.href === `https://explorer.test.mezo.org/tx/${HASH_ONE}` && link.text === "See the transaction" && link.target === "_blank" && link.rel.includes("noopener") && link.drawn,
    link,
  );
  await sleep(1_000);
  check(`${label}: balances are read again`, world.balanceReads > balancesBefore, world.balanceReads);
  check(`${label}: the wallet's quests are read again`, world.questReads > questsBefore, world.questReads);
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${label}-landed.png`) });
  world.claimed = false;

  await loadQuests(page);
  await openKitSlip(page);
  await claimButton(page, "Claim");
  world.reply = { status: 200, body: { ok: true, hash: HASH_TWO } };
  world.receipt = receiptWith(claimedLog(FAUCET, WALLET_A));
  await press(page, "Claim");
  check(`${label}: a Claimed log from the faucet naming this wallet is success with claimed still false`, await waitForLine(page, "Your kit has landed."));
  world.receipt = null;

  await loadQuests(page);
  await openKitSlip(page);
  await claimButton(page, "Claim");
  await page.evaluate(() => {
    window.__shortTimers = true;
  });
  world.reply = { status: 200, body: { ok: true, hash: HASH_THREE } };
  await press(page, "Claim");
  const lateLine = "This is taking longer than usual. Your kit may still arrive, so check back in a minute.";
  check(`${label}: the 60 s line shows`, await waitForWorking(page, lateLine), await claimText(page));
  await page.evaluate(() => {
    window.__shortTimers = false;
  });
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${label}-late.png`) });
  world.claimedReads.length = 0;
  await sleep(LATE_POLL_MS * 2 + 1_500);
  const gaps = world.claimedReads.slice(1).map((at, index) => at - (world.claimedReads[index] ?? at));
  check(`${label}: past 60 s it polls every 10 s`, gaps.length >= 1 && gaps.every((gap) => gap > LATE_POLL_MS - 1_500 && gap < LATE_POLL_MS + 1_500), gaps);

  await closeSlip(page);
  await sleep(400);
  world.claimedReads.length = 0;
  await sleep(LATE_POLL_MS + 1_500);
  check(`${label}: past 60 s it stops polling with the slip closed`, world.claimedReads.length === 0, world.claimedReads.length);
  world.claimed = true;
  await openKitSlip(page);
  check(`${label}: opening the slip again polls and lands`, await waitForLine(page, "Your kit has landed."));
  world.claimed = false;

  await loadQuests(page);
  await openKitSlip(page);
  await claimButton(page, "Claim");
  await page.evaluate(() => {
    window.__shortTimers = true;
  });
  await press(page, "Claim");
  await waitForWorking(page, lateLine);
  await page.evaluate(() => {
    window.__shortTimers = false;
  });
  world.claimed = true;
  const landedLate = await waitForLine(page, "Your kit has landed.");
  check(`${label}: a claim past the 60 s line that lands shows success and no Try again`, landedLate && !(await hasTryAgain(page)), await claimText(page));
  world.claimed = false;

  await loadQuests(page, `/quests?address=${WALLET_C}&wallet=${WALLET_C}&recipient=${WALLET_C}`);
  await openKitSlip(page);
  await claimButton(page, "Claim");
  world.posts.length = 0;
  world.reply = { status: 503, body: { ok: false, code: "paused" } };
  await press(page, "Claim");
  await waitForLine(page, "The faucet is paused for a moment. Try again soon.");
  check(`${label}: an address in the URL never becomes the recipient`, world.posts.length === 1 && world.posts[0].address === WALLET_A, world.posts);

  await page.evaluate((next) => window.__switchWallet(next), WALLET_B);
  await claimButton(page, "Claim");
  check(`${label}: a wallet change drops the last wallet's claim`, !(await claimText(page)).includes("paused"), await claimText(page));
  world.posts.length = 0;
  await press(page, "Claim");
  await waitForLine(page, "The faucet is paused for a moment. Try again soon.");
  check(`${label}: after a wallet change the POST names the new wallet`, world.posts.length === 1 && world.posts[0].address === WALLET_B, world.posts);
  await page.evaluate((next) => window.__switchWallet(next), WALLET_A);
}

const RANK = {
  decchi: { id: "decchi", kanji: "丁稚", exp: 0 },
  tedai: { id: "tedai", kanji: "手代", exp: 300 },
  banto: { id: "banto", kanji: "番頭", exp: 800 },
  nakagai: { id: "nakagai", kanji: "仲買", exp: 1400 },
};

const reading = (address, { exp, rank = RANK.decchi, done = [], complete = true }) => ({
  address,
  exp,
  rank,
  next: RANK.nakagai,
  quests: done.map((id, index) => ({ id, done: true, at: 1_762_400_000 + index, hash: `0x${String(index + 1).repeat(64)}` })),
  complete,
  reachedBlock: null,
});

// Finds the app's one query client through React, stops background reads for this wallet, and hands the page a read.
async function feed(page, wallet, read) {
  await page.waitForFunction(
    (address) => {
      const stage = document.querySelector(".ledger-stage");
      let fiber = stage[Object.keys(stage).find((key) => key.startsWith("__reactFiber$"))];
      while (fiber && !fiber.memoizedProps?.client?.getQueryCache) fiber = fiber.return;
      const client = fiber?.memoizedProps.client;
      const query = client?.getQueryCache().find({ queryKey: ["quests", address] });
      if (!query || query.state.fetchStatus !== "idle") return false;
      window.__queryClient = client;
      query.fetch = async () => query.state.data;
      return true;
    },
    { timeout: 30_000 },
    wallet,
  );
  await page.evaluate((address, value) => window.__queryClient.setQueryData(["quests", address], value), wallet, read);
  await sleep(250);
}

const landings = (page) =>
  page.evaluate(() => {
    const entries = [...document.querySelectorAll(".ledger-entry-press")].map((item) => item.closest(".ledger-entry")?.getAttribute("aria-label"));
    return [...new Set(entries)].length;
  });

const toastCount = (page) => page.evaluate(() => window.__toastsSeen.length);
const lastToast = (page) => page.evaluate(() => window.__toastsSeen.at(-1));
const rankUps = (page) => page.$$eval(".ledger-rankup", (items) => items.length);

async function fixtureChecks(page, label) {
  await loadQuests(page);
  await page.waitForSelector(".toasts", { timeout: 10_000 });
  await page.evaluate(() => {
    window.__toastsSeen = [];
    new MutationObserver((changes) => {
      for (const change of changes) {
        for (const node of change.addedNodes) {
          if (node instanceof HTMLElement && node.classList.contains("toast")) {
            window.__toastsSeen.push({ title: node.querySelector(".toast-title")?.textContent, detail: node.querySelector(".toast-detail")?.textContent, kind: node.dataset.kind });
          }
        }
      }
    }).observe(document.querySelector(".toasts"), { childList: true });
  });

  const empty = reading(WALLET_A, { exp: 50, done: ["home"] });
  const kitDone = reading(WALLET_A, { exp: 100, done: ["home", "kit"] });

  await feed(page, WALLET_A, empty);
  check(`${label}: first read lands nothing`, (await landings(page)) === 0 && (await toastCount(page)) === 0);

  await feed(page, WALLET_A, kitDone);
  check(`${label}: one more quest done gives one landing`, (await landings(page)) === 1, await landings(page));
  check(`${label}: and one toast`, (await toastCount(page)) === 1, await toastCount(page));
  const toast = await lastToast(page);
  check(`${label}: toast reads right`, toast?.title === "New seal" && toast?.detail === "Claim your starter kit. +50 EXP" && toast?.kind === "done", toast);
  const pressed = await page.$eval(".ledger-entry-press .ledger-press", (item) => ({ stamped: item.dataset.stamped, tilt: getComputedStyle(item).getPropertyValue("--tilt") }));
  check(`${label}: the seal is stamped at its own tilt`, pressed.stamped === "true" && pressed.tilt !== "", pressed);
  const seated = await page.evaluate(() => {
    const showing = (selector) => [...document.querySelectorAll(selector)].find((item) => item.getClientRects().length > 0);
    const plain = showing(".ledger-entry-seal:not(.ledger-entry-press)");
    const stamped = showing(".ledger-entry-press");
    const inner = stamped?.querySelector(".ledger-press-seal");
    return { plain: plain?.offsetWidth, stamped: stamped?.offsetWidth, inner: inner?.offsetWidth, innerHeight: inner?.offsetHeight, position: getComputedStyle(stamped).position === getComputedStyle(plain).position };
  });
  check(`${label}: a stamped seal sits exactly where a plain one does`, seated.plain > 0 && seated.plain === seated.stamped && seated.plain === seated.inner && seated.plain === seated.innerHeight && seated.position, seated);
  if (SHOTS) {
    await sleep(600);
    const entry = await page.evaluateHandle(() => [...document.querySelectorAll(".ledger-entry-press")].find((item) => item.getClientRects().length > 0)?.closest(".ledger-entry"));
    await entry.asElement()?.screenshot({ path: path.join(SHOTS, `${label}-seal.png`) });
  }

  await feed(page, WALLET_A, { ...kitDone });
  check(`${label}: the same read again lands nothing`, (await landings(page)) === 1 && (await toastCount(page)) === 1);

  await feed(page, WALLET_A, reading(WALLET_A, { exp: 350, rank: RANK.tedai, done: ["home", "kit", "borrow", "vote"], complete: false }));
  check(`${label}: an incomplete read lands nothing and raises no rank`, (await landings(page)) === 1 && (await toastCount(page)) === 1 && (await rankUps(page)) === 0);

  await feed(page, WALLET_A, { ...kitDone });
  check(`${label}: a partial read is not the new starting point`, (await landings(page)) === 1 && (await toastCount(page)) === 1);

  await feed(page, WALLET_A, reading(WALLET_A, { exp: 200, done: ["home", "kit", "bug"] }));
  check(`${label}: a bug bonus lands`, (await landings(page)) === 2 && (await toastCount(page)) === 2, await landings(page));
  const bonus = await lastToast(page);
  check(`${label}: a bug bonus toast names its EXP`, bonus?.detail === "Report a real bug. +100 EXP", bonus);

  await feed(page, WALLET_A, reading(WALLET_A, { exp: 400, rank: RANK.tedai, done: ["home", "kit", "bug", "borrow"] }));
  check(`${label}: a rank rise opens RankUp once`, (await rankUps(page)) === 1, await rankUps(page));
  const risen = await page.$eval(".ledger-rankup", (item) => {
    const style = getComputedStyle(item);
    const sheet = item.querySelector(".ledger-rankup-sheet").getBoundingClientRect();
    const title = item.querySelector(".ledger-rankup-title");
    const meaning = item.querySelector(".ledger-rankup-meaning");
    const seal = item.querySelector(".ledger-press-seal svg");
    return {
      background: style.backgroundColor,
      zIndex: Number(style.zIndex),
      sheet: [Math.round(sheet.width), Math.round(sheet.height)],
      title: title.textContent,
      titleSize: getComputedStyle(title).fontSize,
      titleFace: title.classList.contains("display-face"),
      meaning: meaning.textContent,
      meaningSize: getComputedStyle(meaning).fontSize,
      seal: seal?.dataset.rank,
      sealSize: seal?.getAttribute("width"),
      tilt: getComputedStyle(item.querySelector(".ledger-press")).getPropertyValue("--tilt"),
      buttons: [...item.querySelectorAll("button")].map((button) => button.textContent.trim()),
    };
  });
  const sheetSide = Math.min(380, (await page.evaluate(() => window.innerWidth)) * 0.84);
  check(
    `${label}: RankUp matches the order`,
    risen.title === "You are now Tedai" &&
      risen.meaning === "the clerk." &&
      risen.titleSize === "38px" &&
      risen.titleFace &&
      risen.meaningSize === "17px" &&
      risen.background === "rgba(10, 8, 7, 0.78)" &&
      risen.zIndex > 90 &&
      risen.seal === "tedai" &&
      risen.sealSize === "280" &&
      risen.tilt === "-3deg" &&
      Math.abs(risen.sheet[0] - sheetSide) <= 1 &&
      Math.abs(risen.sheet[1] - sheetSide) <= 1 &&
      risen.buttons.join() === "Share on X,Close",
    risen,
  );
  await sleep(500);
  const stampedLate = await page.$eval(".ledger-rankup .ledger-press", (item) => item.dataset.stamped);
  check(`${label}: the seal is stamped after 200 ms`, stampedLate === "true", stampedLate);
  if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `${label}-rankup.png`) });

  const focusText = () => page.evaluate(() => document.activeElement?.textContent?.trim());
  check(`${label}: focus starts inside RankUp`, (await focusText()) === "Share on X", await focusText());
  await page.keyboard.press("Tab");
  check(`${label}: Tab moves to Close`, (await focusText()) === "Close", await focusText());
  await page.keyboard.press("Tab");
  check(`${label}: Tab wraps back to the first button`, (await focusText()) === "Share on X", await focusText());
  await page.keyboard.down("Shift");
  await page.keyboard.press("Tab");
  await page.keyboard.up("Shift");
  check(`${label}: Shift Tab wraps to the last button`, (await focusText()) === "Close", await focusText());

  await page.evaluate(() => [...document.querySelectorAll(".ledger-rankup button")].find((item) => item.textContent.trim() === "Share on X")?.click());
  const shared = await page.evaluate(() => window.__opened.at(-1));
  const url = shared ? new URL(shared.url) : null;
  check(
    `${label}: Share on X opens a new tab with no opener and the exact post`,
    shared?.target === "_blank" &&
      shared?.features.includes("noopener") &&
      url?.origin === "https://x.com" &&
      url?.pathname === "/intent/post" &&
      url?.searchParams.get("text") === "I reached Tedai, the clerk, in the Doji ledger." &&
      url?.searchParams.get("url") === `https://www.dojis.site/quests/${WALLET_A}`,
    shared,
  );

  await page.keyboard.press("Escape");
  await sleep(200);
  check(`${label}: Esc closes RankUp`, (await rankUps(page)) === 0);
  await feed(page, WALLET_A, reading(WALLET_A, { exp: 400, rank: RANK.tedai, done: ["home", "kit", "bug", "borrow"] }));
  check(`${label}: the same rank does not open again`, (await rankUps(page)) === 0);

  await openKitSlip(page);
  await feed(page, WALLET_A, reading(WALLET_A, { exp: 850, rank: RANK.banto, done: ["home", "kit", "bug", "borrow", "parked"] }));
  check(`${label}: RankUp opens over an open slip`, (await rankUps(page)) === 1);
  const headClerk = await page.$eval(".ledger-rankup-meaning", (item) => item.textContent);
  check(`${label}: meaning has no capital`, headClerk === "the head clerk.", headClerk);
  const onTop = await page.evaluate(() => {
    const box = document.querySelector(".ledger-rankup-actions button").getBoundingClientRect();
    return document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)?.closest(".ledger-rankup") !== null;
  });
  check(`${label}: RankUp is above the slip`, onTop);
  await page.keyboard.press("Escape");
  await sleep(200);
  const slipOpen = await page.$('.ledger-slip-root[data-state="open"]');
  check(`${label}: Esc on RankUp leaves the slip open`, (await rankUps(page)) === 0 && slipOpen !== null);
  await closeSlip(page);
  await sleep(350);

  const toastsBefore = await toastCount(page);
  await page.evaluate((next) => window.__switchWallet(next), WALLET_B);
  await sleep(300);
  await feed(page, WALLET_B, reading(WALLET_B, { exp: 900, rank: RANK.banto, done: ["kit", "borrow", "vote", "repay"] }));
  check(`${label}: a wallet change lands nothing`, (await landings(page)) === 0 && (await toastCount(page)) === toastsBefore, await landings(page));
  check(`${label}: a wallet change raises no rank`, (await rankUps(page)) === 0);

  await page.evaluate((next) => window.__switchWallet(next), WALLET_A);
  await sleep(300);
  check(`${label}: going back to the first wallet lands nothing`, (await landings(page)) === 0 && (await toastCount(page)) === toastsBefore && (await rankUps(page)) === 0);
  await feed(page, WALLET_A, reading(WALLET_A, { exp: 850, rank: RANK.banto, done: ["home", "kit", "bug", "borrow", "parked"] }));
  check(`${label}: and its first read back is only a starting point`, (await landings(page)) === 0 && (await toastCount(page)) === toastsBefore);

  await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "reduce" }]);
  await sleep(500);
  await feed(page, WALLET_A, reading(WALLET_A, { exp: 1500, rank: RANK.nakagai, done: ["home", "kit", "bug", "borrow", "parked", "repay"] }));
  const calm = await page.$eval(".ledger-rankup", (item) => ({
    stamped: item.querySelector(".ledger-press")?.dataset.stamped,
    moving: item.getAnimations({ subtree: true }).length,
  }));
  check(`${label}: reduced motion shows the seal at rest with no drop`, calm.stamped === "true" && calm.moving === 0, calm);
  const quiet = await page.$$eval(".ledger-entry-press", (items) => items.flatMap((item) => item.getAnimations({ subtree: true })).length);
  check(`${label}: reduced motion stamps the entry with no drop`, quiet === 0, quiet);
  await page.keyboard.press("Escape");
  await page.emulateMediaFeatures([{ name: "prefers-reduced-motion", value: "no-preference" }]);
  await sleep(300);

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check(`${label}: no sideways overflow`, overflow <= 0, overflow);
}

async function labCheck(browser) {
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error).slice(0, 200)));
  await page.goto(`${BASE}/lab/ledger`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  await page.waitForFunction(
    () => {
      const entry = [...document.querySelectorAll(".ledger-entry")].find((item) => item.getAttribute("aria-label")?.startsWith("Claim your starter kit"));
      return entry !== undefined && Object.keys(entry).some((key) => key.startsWith("__reactFiber$"));
    },
    { timeout: 120_000 },
  );
  await openKitSlip(page);
  const label = await page.$eval("button.ledger-slip-button", (item) => item.textContent.trim());
  check("lab: the slip still opens with no wallet layer", label === "Claim" && errors.length === 0, { label, errors });
  await page.close();
}

const VIEWPORTS = [
  ["desktop-1440", { width: 1440, height: 900 }],
  ["phone-375", { width: 375, height: 812, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }],
];

if (SHOTS) mkdirSync(SHOTS, { recursive: true });
const profile = mkdtempSync(path.join(tmpdir(), "doji-claim-ui-"));
const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: profile, args: ["--no-first-run"] });

try {
  for (const [label, viewport] of VIEWPORTS) {
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    await page.setViewport(viewport);
    const world = freshWorld();
    const crashes = [];
    page.on("pageerror", (error) => crashes.push(String(error).slice(0, 300)));
    await page.evaluateOnNewDocument(pageStubs, WALLET_A);
    await page.setRequestInterception(true);
    page.on("request", (request) => {
      void route(world, request).catch((error) => {
        console.error(`stub failed for ${request.url()}: ${error}`);
      });
    });

    await claimChecks(page, world, label);
    await fixtureChecks(page, `${label} fixture`);
    check(`${label}: no uncaught page errors`, crashes.length === 0, crashes.slice(0, 3));
    await context.close();
  }
  await labCheck(browser);
} finally {
  await browser.close();
  rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
}

if (failures.length > 0) {
  console.error(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\nall checks passed");

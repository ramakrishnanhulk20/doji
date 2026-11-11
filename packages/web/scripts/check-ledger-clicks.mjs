import { createRequire } from "node:module";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Opens every quest on /quests with a real pointer at the screen point where a tester would aim: page.mouse on the
// pinned book at three laptop sizes, page.touchscreen on the flat layout at two phone sizes. A click dispatched from
// script reaches its button even when another layer sits over it, so only a pointer at screen coordinates proves the
// slip opens for a person. Each quest is tried just after scrolling to it, the moment the book looks still, because that
// is when a tester clicks. Reads the page only: no wallet is connected and nothing is sent.
// Not covered: wheel and finger scrolling (the page is moved with scrollTo), a point on a leaf caught mid-turn, the
// edges and corners of a tile (one point inside it is tried), and Safari and Firefox hit testing.

const HERE = path.dirname(fileURLToPath(import.meta.url));
// puppeteer-core is not one of the app's dependencies. PUPPETEER_HOME names any folder that has it installed.
const PUPPETEER_HOME = process.env.PUPPETEER_HOME ?? path.join(HERE, "../../../scratchpad/walk");
const puppeteer = createRequire(path.join(PUPPETEER_HOME, "package.json"))("puppeteer-core");
const CHROME = process.env.CHROME_PATH ?? "C:/Program Files/Google/Chrome/Application/chrome.exe";
const BASE = process.env.CHECK_BASE ?? "http://localhost:3008";

const QUEST_COUNT = 16;
// The shortest rest between two page turns is about 120px of scroll at 1024 by 768, so a 50px step always lands in it.
const PINNED_STEP = 50;
// Still to a person: nothing on the book moves half a pixel in a tenth of a second. The pause first lets the scroll land.
const SCROLL_LANDS = 150;
const STILL_SAMPLE = 100;
const STILL_PX = 0.5;
const SETTLE_TIMEOUT = 8_000;

const VIEWPORTS = [
  ["1440x900", { width: 1440, height: 900 }],
  ["1280x800", { width: 1280, height: 800 }],
  ["1024x768", { width: 1024, height: 768 }],
  ["390x844", { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }],
  ["375x812", { width: 375, height: 812, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }],
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function loadQuests(page) {
  await page.goto(`${BASE}/quests`, { waitUntil: "domcontentloaded", timeout: 180_000 });
  // The server always sends the flat layout, and a laptop swaps it for the pinned book once it has hydrated.
  await page.waitForFunction(
    (count) => {
      const pinned = matchMedia("(min-width: 1024px) and (min-height: 680px)").matches && !matchMedia("(prefers-reduced-motion: reduce)").matches;
      const stage = document.querySelector(pinned ? ".ledger-stage-pinned" : ".ledger-stage-flat");
      if (stage === null || !Object.keys(stage).some((key) => key.startsWith("__reactFiber$"))) return false;
      return [...stage.querySelectorAll(".ledger-entry")].filter((entry) => entry.getClientRects().length > 0).length === count;
    },
    { timeout: 120_000 },
    QUEST_COUNT,
  );
  return page.evaluate(() => document.querySelector(".ledger-stage-pinned") !== null);
}

// The stage's own idea of motion is not used, because the bug this guards against was a wrong idea of motion.
const pose = (page) =>
  page.evaluate(() => [
    scrollY,
    ...[...document.querySelectorAll("[data-leaf], .ledger-stage-base")].flatMap((part) => {
      const box = part.getBoundingClientRect();
      return [box.left, box.top, box.right, box.bottom];
    }),
  ]);

async function looksStill(page) {
  await sleep(SCROLL_LANDS);
  const started = Date.now();
  let before = await pose(page);
  while (Date.now() - started < SETTLE_TIMEOUT) {
    await sleep(STILL_SAMPLE);
    const now = await pose(page);
    if (now.every((value, index) => Math.abs(value - (before[index] ?? Number.NaN)) < STILL_PX)) return;
    before = now;
  }
  throw new Error("the book never came to rest");
}

async function arrive(page, y, pinned) {
  await page.evaluate((to) => window.scrollTo(0, to), y);
  if (pinned) await looksStill(page);
  else await sleep(250);
}

// Every quest whose tile is wholly on screen below the top bar, on a page that takes clicks, with the book lying flat.
const candidates = (page) =>
  page.evaluate(() => {
    const describe = (element) =>
      element === null ? "nothing" : `${element.tagName}${[...element.classList].map((name) => `.${name}`).join("")}`;
    const leaves = [...document.querySelectorAll("[data-leaf]")];
    const flat = leaves.every((leaf) => {
      const transform = getComputedStyle(leaf).transform;
      return transform === "none" || Math.abs(new DOMMatrix(transform).m13) < 0.02;
    });
    if (!flat) return [];
    const bar = document.querySelector(".topbar")?.getBoundingClientRect().bottom ?? 0;
    const stage = document.querySelector(".ledger-stage-pinned, .ledger-stage-flat");
    const entries = [...stage.querySelectorAll(".ledger-entry")].filter((entry) => entry.getClientRects().length > 0);
    return entries.flatMap((entry, order) => {
      if (entry.closest("[inert]") !== null) return [];
      const box = entry.getBoundingClientRect();
      if (box.top < bar || box.bottom > innerHeight || box.left < 0 || box.right > innerWidth) return [];
      const x = Math.round(box.left + box.width / 2);
      const y = Math.round(box.top + box.height / 2);
      const top = document.elementFromPoint(x, y);
      const number = Number(entry.querySelector(".ledger-entry-number")?.textContent ?? order + 1);
      const title = entry.querySelector(".ledger-entry-title")?.textContent ?? "";
      return [{ number, title, x, y, top: describe(top), onEntry: top !== null && entry.contains(top) }];
    });
  });

const openTitle = (page) =>
  page.evaluate(() => {
    const root = document.querySelector('.ledger-slip-root[data-state="open"]');
    return root === null ? null : (root.querySelector(".ledger-slip-title")?.textContent ?? "");
  });

async function waitForTitle(page, timeout) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const title = await openTitle(page);
    if (title !== null) return title;
    await sleep(50);
  }
  return null;
}

async function closeSlip(page) {
  await page.keyboard.press("Escape");
  await page.waitForFunction(() => document.querySelector('.ledger-slip-root[data-state="open"]') === null, { timeout: 5_000 });
  // The slip keeps its visibility for 300ms while it slides away.
  await sleep(350);
}

async function tryQuest(page, candidate, touch) {
  if (touch) await page.touchscreen.tap(candidate.x, candidate.y);
  else await page.mouse.click(candidate.x, candidate.y);
  const title = await waitForTitle(page, 2_500);
  if (title === null) return `no slip opened, on top: ${candidate.top}`;
  await closeSlip(page);
  if (title !== candidate.title) return `opened "${title}" instead, on top: ${candidate.top}`;
  return null;
}

async function runViewport(browser, label, viewport) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.setViewport(viewport);
  const crashes = [];
  page.on("pageerror", (error) => crashes.push(String(error).slice(0, 200)));
  const pinned = await loadQuests(page);
  const touch = viewport.hasTouch === true;

  const results = new Map();
  const end = await page.evaluate(() => document.documentElement.scrollHeight - innerHeight);
  const step = pinned ? PINNED_STEP : Math.round(viewport.height * 0.5);
  for (let y = 0; y <= end + step && results.size < QUEST_COUNT; y += step) {
    const here = Math.min(y, end);
    await arrive(page, here, pinned);
    // Every quest gets its own arrival: a click made long after the last scroll would pass even with the bug.
    for (let first = true; ; first = false) {
      if (!first) {
        await arrive(page, Math.max(0, here - step), pinned);
        await arrive(page, here, pinned);
      }
      const next = (await candidates(page)).find((candidate) => !results.has(candidate.number));
      if (next === undefined) break;
      results.set(next.number, { ...next, failure: await tryQuest(page, next, touch) });
    }
  }

  const failures = [];
  for (let number = 1; number <= QUEST_COUNT; number += 1) {
    const result = results.get(number);
    if (result === undefined) failures.push(`${String(number).padStart(2, "0")} never wholly in view on an open page`);
    else if (result.failure !== null) failures.push(`${String(number).padStart(2, "0")} "${result.title}": ${result.failure}`);
  }
  if (crashes.length > 0) failures.push(`page errors: ${crashes.slice(0, 2).join(" | ")}`);
  const passed = QUEST_COUNT - failures.filter((line) => !line.startsWith("page errors")).length;
  const layout = pinned ? "pinned book, mouse" : "flat layout, touch";
  console.log(`${label} (${layout}): passed ${passed} of ${QUEST_COUNT}${failures.length > 0 ? `. Failed: ${failures.join("; ")}` : ""}`);
  await context.close();
  return failures.length === 0;
}

const profile = mkdtempSync(path.join(tmpdir(), "doji-ledger-clicks-"));
const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, userDataDir: profile, args: ["--no-first-run"] });
let clean = true;
try {
  console.log(`checking ${BASE}/quests`);
  for (const [label, viewport] of VIEWPORTS) {
    if (!(await runViewport(browser, label, viewport))) clean = false;
  }
} finally {
  await browser.close();
  rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 500 });
}

if (!clean) {
  console.error("\nsome quests did not open on a real click or tap");
  process.exit(1);
}
console.log("\nevery quest opened on a real click or tap at every size");

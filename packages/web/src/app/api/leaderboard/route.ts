import { unstable_cache } from "next/cache";
import { leaderboardRows, readAllProgress, type BoardRow } from "@/lib/quests/read-all";

// Always a live handler, so the build itself never scans. The cached reads below are what keep the work fixed.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const SCAN_EVERY_MS = 60_000;
const SCAN_EVERY_SECONDS = 60;
// The budget stops new reads, and the slowest read already running takes 10 s more, which still lands under maxDuration.
const SCAN_BUDGET_MS = 45_000;
const SHARED_CACHE = "public, s-maxage=60, stale-while-revalidate=600";

type Scan = { complete: boolean; asOf: number; rows: BoardRow[] };

async function runScan(): Promise<Scan> {
  const asOf = Math.floor(Date.now() / 1000);
  try {
    const { wallets, complete } = await readAllProgress(Date.now() + SCAN_BUDGET_MS);
    console.info(`leaderboard scan: ${wallets.length} wallets, ${complete ? "complete" : "incomplete"}`);
    return { complete, asOf, rows: complete ? leaderboardRows(wallets) : [] };
  } catch {
    console.error("leaderboard scan failed");
    return { complete: false, asOf, rows: [] };
  }
}

let lastScan: { startedAt: number; result: Promise<Scan> } | null = null;

/**
 * unstable_cache runs its function again for every request that finds the entry stale or missing, however many arrive
 * during the seconds a scan takes. This is what makes it one scan a minute from one instance (C73).
 */
function scanAtMostOnceAMinute(): Promise<Scan> {
  if (lastScan !== null && Date.now() - lastScan.startedAt < SCAN_EVERY_MS) return lastScan.result;
  lastScan = { startedAt: Date.now(), result: runScan() };
  return lastScan.result;
}

// Failed scans are cached too, or an outage would send every request upstream. The key holds nothing from the request.
const latestScan = unstable_cache(scanAtMostOnceAMinute, ["leaderboard-latest-scan"], { revalidate: SCAN_EVERY_SECONDS });

let newestComplete: Scan | null = null;

// Throwing leaves the entry as it was, which is how an outage keeps the last complete board across instances and cold
// starts. Arguments would change the cache key, so the scan to keep arrives through newestComplete.
const keptScan = unstable_cache(
  async () => {
    if (newestComplete === null) throw new Error("no complete scan to keep yet");
    return newestComplete;
  },
  ["leaderboard-kept-scan"],
  { revalidate: SCAN_EVERY_SECONDS },
);

/**
 * The top 50 wallets by EXP, Doji's own removed. Takes no input: the query string, headers and cookies never reach the
 * handler, so every caller gets one answer. Upstream scans run at most once a minute. An incomplete scan never reaches
 * a caller: the last complete board is served instead, and `asOf` says how old it is. With none, 503 and
 * `{ code: "unavailable" }`.
 */
export async function GET(): Promise<Response> {
  const latest = await latestScan().catch(() => null);
  if (latest?.complete) newestComplete = latest;
  const kept = await keptScan().catch(() => null);

  const board = latest?.complete ? latest : kept;
  if (board === null) {
    return Response.json({ code: "unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
  return Response.json({ asOf: board.asOf, rows: board.rows }, { headers: { "Cache-Control": SHARED_CACHE } });
}

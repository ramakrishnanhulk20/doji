import { unstable_cache } from "next/cache";
import { readExpSnapshot, type ExpSnapshot } from "@/lib/quests/read-all";

// Always a live handler, so the build itself never scans. The cached reads below are what keep the work fixed.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const KEEP_EVERY_SECONDS = 60;
const SHARED_CACHE = "public, s-maxage=60, stale-while-revalidate=600";

type Board = Pick<ExpSnapshot, "asOf" | "rows">;

let newestComplete: Board | null = null;

// Throwing leaves the entry as it was, which is how an outage keeps the last complete board across instances and cold
// starts. Arguments would change the cache key, so the board to keep arrives through newestComplete.
const keptScan = unstable_cache(
  async () => {
    if (newestComplete === null) throw new Error("no complete scan to keep yet");
    return newestComplete;
  },
  ["leaderboard-kept-scan"],
  { revalidate: KEEP_EVERY_SECONDS },
);

/**
 * The top 50 wallets by EXP, Doji's own removed. Takes no input: the query string, headers and cookies never reach the
 * handler, so every caller gets one answer. Upstream scans run at most once a minute, in the one snapshot. An incomplete
 * scan never reaches a caller: the last complete board is served instead, and `asOf` says how old it is. With none, 503
 * and `{ code: "unavailable" }`.
 */
export async function GET(): Promise<Response> {
  const latest = await readExpSnapshot().catch(() => null);
  if (latest?.complete) newestComplete = { asOf: latest.asOf, rows: latest.rows };
  const kept = await keptScan().catch(() => null);

  const board = latest?.complete ? latest : kept;
  if (board === null) {
    return Response.json({ code: "unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
  return Response.json({ asOf: board.asOf, rows: board.rows }, { headers: { "Cache-Control": SHARED_CACHE } });
}

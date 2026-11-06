import "server-only";
import { unstable_cache } from "next/cache";
import type { Address } from "viem";
import { parseAddress } from "../address";
import { isDojiWallet } from "../doji-wallets";
import { bonusEntries, compareProgress, computeProgress, walletsIn, type WalletProgress } from "./exp";
import { MAX_CONCURRENT, mapLimit, mergeReads, readExplorerLogs, readRecentLogs, stampLogs, unseenLogs, type ExplorerQuery } from "./logs";
import type { RankId } from "./ranks";
import { QUEST_EVENTS } from "./table";

const BOARD_ROWS = 50;

export type BoardRow = { place: number; address: Address; exp: number; rank: RankId };

export type WholeRead = { wallets: WalletProgress[]; complete: boolean };

const scanQueries: readonly ExplorerQuery[] = QUEST_EVENTS.map((event) => ({ event, match: event.scan }));

/**
 * Every wallet's progress from every log of every table event since the deploy block. It costs at least one explorer
 * call per event, so only the leaderboard route's once-a-minute scan may call it. Past `deadline` the remaining reads
 * stop and the result is incomplete. It reaches no request data, so it cannot vary by caller.
 */
export async function readAllProgress(deadline?: number): Promise<WholeRead> {
  const scans = await mapLimit(scanQueries, MAX_CONCURRENT, (query) => readExplorerLogs(query, deadline));
  const recent = await readRecentLogs();
  const indexed = mergeReads(scans);
  const stamped = await stampLogs(unseenLogs(recent, indexed));
  const read = mergeReads([indexed, stamped, { logs: [], complete: recent.complete }]);

  const wallets = new Set(walletsIn(read));
  for (const entry of bonusEntries) {
    const wallet = parseAddress(entry.address);
    if (wallet !== null) wallets.add(wallet);
  }
  return {
    wallets: [...wallets].map((wallet) => computeProgress(wallet, read, bonusEntries)),
    complete: read.complete,
  };
}

/** The top 50 by the C69 order, after removing Doji's own wallets and anyone with no EXP. */
export function leaderboardRows(wallets: readonly WalletProgress[]): BoardRow[] {
  return wallets
    .filter((wallet) => wallet.exp > 0 && !isDojiWallet(wallet.address))
    .sort(compareProgress)
    .slice(0, BOARD_ROWS)
    .map((wallet, at) => ({ place: at + 1, address: wallet.address, exp: wallet.exp, rank: wallet.rank.id }));
}

const SNAPSHOT_EVERY_MS = 60_000;
const SNAPSHOT_EVERY_SECONDS = 60;
// The same budget as the leaderboard route's scan: new reads stop here, and the slowest one running takes 10 s more.
const SNAPSHOT_BUDGET_MS = 45_000;

export type WalletStanding = { exp: number; rank: RankId };

/** Every wallet with EXP, Doji's own included because their public pages stay (C75). A failed read holds nothing. */
export type ExpSnapshot = { complete: boolean; wallets: Record<string, WalletStanding> };

async function takeSnapshot(): Promise<ExpSnapshot> {
  try {
    const { wallets, complete } = await readAllProgress(Date.now() + SNAPSHOT_BUDGET_MS);
    console.info(`leaderboard scan: ${wallets.length} wallets, ${complete ? "complete" : "incomplete"}, for the snapshot`);
    if (!complete) return { complete: false, wallets: {} };
    const standings = wallets.filter((wallet) => wallet.exp > 0).map((wallet) => [wallet.address, { exp: wallet.exp, rank: wallet.rank.id }]);
    return { complete: true, wallets: Object.fromEntries(standings) };
  } catch {
    console.error("leaderboard scan: failed, for the snapshot");
    return { complete: false, wallets: {} };
  }
}

let lastSnapshot: { startedAt: number; result: Promise<ExpSnapshot> } | null = null;

// unstable_cache runs its function for every request that finds the entry stale, so this is what holds one instance to
// one scan a minute (C73).
function snapshotAtMostOnceAMinute(): Promise<ExpSnapshot> {
  if (lastSnapshot !== null && Date.now() - lastSnapshot.startedAt < SNAPSHOT_EVERY_MS) return lastSnapshot.result;
  lastSnapshot = { startedAt: Date.now(), result: takeSnapshot() };
  return lastSnapshot.result;
}

// The key holds nothing from the request. A failed read is cached too, so an outage cannot send every request upstream.
const cachedSnapshot = unstable_cache(snapshotAtMostOnceAMinute, ["quest-exp-snapshot"], { revalidate: SNAPSHOT_EVERY_SECONDS });

/**
 * The one cached snapshot of every wallet's EXP, for the share image (C73). The leaderboard route's cache holds only 50
 * rows without Doji's wallets, so it cannot answer for any address. Takes no input, so every caller gets one answer.
 */
export function readExpSnapshot(): Promise<ExpSnapshot> {
  return cachedSnapshot();
}

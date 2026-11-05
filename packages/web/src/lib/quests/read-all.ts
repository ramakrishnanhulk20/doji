import "server-only";
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

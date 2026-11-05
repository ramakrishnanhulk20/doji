import type { Address, Hex } from "viem";
import { parseAddress } from "../address";
import { bonusEntries, computeProgress, type WalletProgress } from "./exp";
import {
  MAX_CONCURRENT,
  decodeQuestLog,
  mapLimit,
  mergeReads,
  readExplorerLogs,
  readReceiptLogs,
  readRecentLogs,
  stampLogs,
  unseenLogs,
  type DecodedLog,
  type ExplorerQuery,
  type LogRead,
  type NormalizedLog,
} from "./logs";
import { EVENTS, QUEST_EVENTS, type QuestId } from "./table";

/** Transactions whose receipt is read to look for a borrower who is not this wallet. */
const MAX_RECEIPTS = 20;
/** Ids followed per kind. Each one costs upstream calls on every poll, and the read must stay a fixed size. */
const MAX_IDS = 20;

/** The quests a read can no longer rule out once more ids exist than it follows. */
const QUESTS_BY_TOKEN: readonly QuestId[] = ["vote", "paydown", "roll"];

type Links = { tokens: bigint[]; offers: bigint[]; listings: bigint[]; fills: NormalizedLog[] };

const newestFirst = (a: NormalizedLog, b: NormalizedLog) => b.blockNumber - a.blockNumber || b.logIndex - a.logIndex;

const namedQueries = (wallet: Address): ExplorerQuery[] =>
  QUEST_EVENTS.flatMap((event) => event.wallets.map((field) => ({ event, match: { field, wallet } })));

const tokenEvents = QUEST_EVENTS.filter((event) => event.id === "tokenId");

/** What a wallet's own logs point at, newest first: the ids and transactions the logs that do not name it hang off. */
function linksOf(wallet: Address, logs: readonly NormalizedLog[]): Links {
  const tokens = new Set<bigint>();
  const offers = new Set<bigint>();
  const listings = new Set<bigint>();
  const fills: NormalizedLog[] = [];
  for (const log of [...logs].sort(newestFirst)) {
    const seen = decodeQuestLog(log);
    if (seen?.name === "Deposited" && seen.args.borrower === wallet) tokens.add(seen.args.tokenId as bigint);
    if (seen?.name === "OfferPosted" && seen.args.maker === wallet) offers.add(seen.args.offerId as bigint);
    if (seen?.name === "Bought" && seen.args.buyer === wallet) listings.add(seen.args.listingId as bigint);
    if (seen?.name === "Filled" && seen.args.maker === wallet) fills.push(log);
  }
  return { tokens: [...tokens], offers: [...offers], listings: [...listings], fills };
}

function followQueries({ tokens, offers, listings }: Links): ExplorerQuery[] {
  return [
    ...tokens.slice(0, MAX_IDS).flatMap((id) => tokenEvents.map((event) => ({ event, match: { field: "tokenId", id } }))),
    ...offers.slice(0, MAX_IDS).map((id) => ({ event: EVENTS.OfferParked, match: { field: "offerId", id } })),
    ...listings.slice(0, MAX_IDS).map((id) => ({ event: EVENTS.Listed, match: { field: "listingId", id } })),
  ];
}

/** True when a log from the all-wallets node window matters to this wallet. */
function concerns(seen: DecodedLog, wallet: Address, links: Links, fillHashes: ReadonlySet<Hex>): boolean {
  const event = EVENTS[seen.name];
  if (event.wallets.some((field) => seen.args[field] === wallet)) return true;
  if (seen.name === "Borrowed") return fillHashes.has(seen.log.hash);
  if (event.id === "tokenId") return links.tokens.includes(seen.args.tokenId as bigint);
  if (event.id === "offerId") return links.offers.includes(seen.args.offerId as bigint);
  if (event.id === "listingId") return links.listings.includes(seen.args.listingId as bigint);
  return false;
}

/**
 * The table logs of a fill's transaction. Mezo's public RPC sometimes answers null for a receipt it has: 5 of 6 reads of
 * one wallet hit that on 2026-11-05, and 1 of 60 receipts minutes later. So a missing receipt falls back to the
 * explorer's Borrowed logs for the block, which computeProgress joins to the fill by hash just the same.
 */
async function readFillLogs(fill: NormalizedLog): Promise<LogRead> {
  const receipt = await readReceiptLogs(fill.hash, fill.timestamp);
  return receipt.complete ? receipt : readExplorerLogs({ event: EVENTS.Borrowed, block: fill.blockNumber });
}

function questsPastTheCaps(links: Links): QuestId[] {
  return [
    ...(links.tokens.length > MAX_IDS ? QUESTS_BY_TOKEN : []),
    ...(links.offers.length > MAX_IDS ? (["parked"] as const) : []),
    ...(links.listings.length > MAX_IDS ? (["buy"] as const) : []),
    ...(links.fills.length > MAX_RECEIPTS ? (["stranger"] as const) : []),
  ];
}

/**
 * One wallet's quests, EXP and rank from chain logs. Every event that names a wallet is read by that wallet's topic,
 * what hangs off its positions, offers and listings is read by id, the newest fills' receipts show who borrowed, and
 * one node request covers blocks the explorer has not indexed (C70). At most four reads run at once. A failed read, or
 * a cap that leaves a quest undecided, marks the result incomplete and never throws.
 *
 * @throws when `address` is not an address.
 */
export async function readWalletProgress(address: Address): Promise<WalletProgress> {
  const wallet = parseAddress(address);
  if (wallet === null) throw new Error("readWalletProgress needs an address");

  const reads = await mapLimit<() => Promise<LogRead>, LogRead>(
    [readRecentLogs, ...namedQueries(wallet).map((query) => () => readExplorerLogs(query))],
    MAX_CONCURRENT,
    (read) => read(),
  );
  const recent = reads[0] as LogRead;
  const named = reads.slice(1);

  const links = linksOf(wallet, mergeReads(reads).logs);
  const followed = await mapLimit(followQueries(links), MAX_CONCURRENT, (query) => readExplorerLogs(query));
  const indexed = mergeReads([...named, ...followed]);

  const fills = links.fills.slice(0, MAX_RECEIPTS);
  const fillHashes = new Set(fills.map((fill) => fill.hash));
  const fresh = unseenLogs(recent, indexed).filter((log) => {
    const seen = decodeQuestLog(log);
    return seen !== null && concerns(seen, wallet, links, fillHashes);
  });
  const stamped = await stampLogs(fresh);
  const receipts = await mapLimit(fills, MAX_CONCURRENT, readFillLogs);

  const read = mergeReads([indexed, stamped, ...receipts, { logs: [], complete: recent.complete }]);
  const progress = computeProgress(wallet, read, bonusEntries);
  const undecided = questsPastTheCaps(links).some((id) => !progress.quests.some((quest) => quest.id === id && quest.done));
  return undecided ? { ...progress, complete: false } : progress;
}

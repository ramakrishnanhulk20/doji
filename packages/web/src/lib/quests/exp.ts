import type { Address, Hex } from "viem";
import bonusFile from "../../../content/quests/bonus-exp.json";
import { parseAddress } from "../address";
import { decodeQuestLog, type DecodedLog, type LogRead, type NormalizedLog } from "./logs";
import { nextRank, rankOf, type Rank } from "./ranks";
import { EVENTS, QUESTS, type Quest, type QuestFacts, type QuestId } from "./table";

// The one EXP function (C69). The browser, the leaderboard and the share image all land here, so the same logs always
// give the same number. It reads no view and no clock, and imports nothing that only runs on a server.

/** One line of content/quests/bonus-exp.json. scripts/validate-bonus.mjs checks the file at build (C74). */
export type BonusEntry = { address: string; exp: number; reason: string; link: string };

export const bonusEntries = bonusFile as readonly BonusEntry[];

export type QuestState = {
  id: QuestId;
  done: boolean;
  /** The block's own time, in unix seconds, never a browser clock (C68). */
  at?: number;
  hash?: Hex;
};

export type WalletProgress = {
  address: Address;
  exp: number;
  rank: Rank;
  /** The next rank up, or null at the top. */
  next: Rank | null;
  quests: QuestState[];
  /** False when any read behind this failed, so `exp` is not a final number (C70). */
  complete: boolean;
  /** The block that took the wallet to this EXP, for the leaderboard's tie rule. Null when no log earned any of it. */
  reachedBlock: number | null;
};

type LogIndex = {
  byWallet: Map<Address, DecodedLog[]>;
  /** Logs that name no wallet and are reached through the position they are about. */
  byToken: Map<bigint, DecodedLog[]>;
  parkedOffers: Set<bigint>;
  sellers: Map<bigint, Address>;
  borrowers: Map<Hex, Address[]>;
};

function bucket<K, V>(map: Map<K, V[]>, key: K, value: V): void {
  const list = map.get(key);
  if (list === undefined) map.set(key, [value]);
  else list.push(value);
}

function buildIndex(logs: readonly NormalizedLog[]): LogIndex {
  const index: LogIndex = { byWallet: new Map(), byToken: new Map(), parkedOffers: new Set(), sellers: new Map(), borrowers: new Map() };
  for (const log of logs) {
    const seen = decodeQuestLog(log);
    if (seen === null) continue;
    const event = EVENTS[seen.name];
    const named = new Set(event.wallets.map((field) => seen.args[field] as Address));
    for (const wallet of named) bucket(index.byWallet, wallet, seen);
    if (event.id === "tokenId") bucket(index.byToken, seen.args.tokenId as bigint, seen);
    if (seen.name === "OfferParked") index.parkedOffers.add(seen.args.offerId as bigint);
    if (seen.name === "Listed") index.sellers.set(seen.args.listingId as bigint, seen.args.seller as Address);
    if (seen.name === "Borrowed") bucket(index.borrowers, log.hash, seen.args.borrower as Address);
  }
  return index;
}

const indexes = new WeakMap<readonly NormalizedLog[], LogIndex>();

// The leaderboard asks about every wallet over one list of logs, so the list is read once, not once per wallet.
function indexOf(logs: readonly NormalizedLog[]): LogIndex {
  const known = indexes.get(logs);
  if (known !== undefined) return known;
  const index = buildIndex(logs);
  indexes.set(logs, index);
  return index;
}

/** Every wallet a table event names in these logs. */
export const walletsIn = (read: LogRead): Address[] => [...indexOf(read.logs).byWallet.keys()];

const isBefore = (a: DecodedLog, b: DecodedLog): boolean =>
  a.log.blockNumber === b.log.blockNumber ? a.log.logIndex < b.log.logIndex : a.log.blockNumber < b.log.blockNumber;

type PositionMoves = { deposits: DecodedLog[]; losses: DecodedLog[] };

function positionsOf(wallet: Address, own: readonly DecodedLog[]): Map<bigint, PositionMoves> {
  const positions = new Map<bigint, PositionMoves>();
  for (const seen of own) {
    const tokenId = seen.args.tokenId as bigint;
    const moves = positions.get(tokenId) ?? { deposits: [], losses: [] };
    if (seen.name === "Deposited") moves.deposits.push(seen);
    else if ((seen.name === "Withdrawn" || seen.name === "Purchased" || seen.name === "Settled") && seen.args.borrower === wallet) {
      moves.losses.push(seen);
    } else continue;
    positions.set(tokenId, moves);
  }
  return positions;
}

/** Deposited at or before `block` and not lost before it. A position can leave and come back, so each deposit is tried. */
function heldAt(moves: PositionMoves | undefined, block: number): boolean {
  if (moves === undefined) return false;
  return moves.deposits.some(
    (deposit) =>
      deposit.log.blockNumber <= block && !moves.losses.some((loss) => isBefore(deposit, loss) && loss.log.blockNumber < block),
  );
}

/** The earliest log that proves a quest for this wallet, or null. */
function firstProof(
  quest: Quest,
  own: readonly DecodedLog[],
  index: LogIndex,
  positions: ReadonlyMap<bigint, PositionMoves>,
  facts: QuestFacts,
): DecodedLog | null {
  let first: DecodedLog | null = null;
  for (const proof of quest.proofs) {
    const candidates = proof.wallet === undefined ? [...positions.keys()].flatMap((tokenId) => index.byToken.get(tokenId) ?? []) : own;
    for (const seen of candidates) {
      if (seen.name !== proof.event) continue;
      if (proof.wallet !== undefined && seen.args[proof.wallet] !== facts.wallet) continue;
      if (proof.held && !heldAt(positions.get(seen.args.tokenId as bigint), seen.log.blockNumber)) continue;
      if (proof.also !== undefined && !proof.also(seen, facts)) continue;
      if (first === null || isBefore(seen, first)) first = seen;
    }
  }
  return first;
}

/**
 * What these logs and the bonus file say about one wallet. Each quest counts once, however many logs prove it, and the
 * earliest proof is the one shown. The wallet comes from the table's field in each log, never from a transaction's
 * sender (C68). `complete` is carried from `logs` as it is, so a partial read cannot pass for a final number (C70).
 *
 * @throws when `wallet` is not an address.
 */
export function computeProgress(wallet: Address, logs: LogRead, bonus: readonly BonusEntry[]): WalletProgress {
  const address = parseAddress(wallet);
  if (address === null) throw new Error("computeProgress needs an address");

  const index = indexOf(logs.logs);
  const own = index.byWallet.get(address) ?? [];
  const positions = positionsOf(address, own);
  const facts: QuestFacts = {
    wallet: address,
    offerParked: (offerId) => index.parkedOffers.has(offerId),
    sellerOf: (listingId) => index.sellers.get(listingId) ?? null,
    borrowersIn: (hash) => index.borrowers.get(hash) ?? [],
  };
  const bonusEntry = bonus.find((entry) => parseAddress(entry.address) === address);

  let exp = 0;
  let reachedBlock: number | null = null;
  const quests = QUESTS.map((quest): QuestState => {
    if (quest.id === "bug") {
      if (bonusEntry === undefined) return { id: quest.id, done: false };
      exp += bonusEntry.exp;
      return { id: quest.id, done: true };
    }
    const proof = firstProof(quest, own, index, positions, facts);
    if (proof === null) return { id: quest.id, done: false };
    exp += quest.exp;
    reachedBlock = Math.max(reachedBlock ?? 0, proof.log.blockNumber);
    return { id: quest.id, done: true, at: proof.log.timestamp, hash: proof.log.hash };
  });

  return { address, exp, rank: rankOf(exp), next: nextRank(exp), quests, complete: logs.complete, reachedBlock };
}

/** Most EXP first, then the earliest block to reach it, then address, so one set of logs gives one order (C69). */
export function compareProgress(a: WalletProgress, b: WalletProgress): number {
  if (a.exp !== b.exp) return b.exp - a.exp;
  const aBlock = a.reachedBlock ?? Number.POSITIVE_INFINITY;
  const bBlock = b.reachedBlock ?? Number.POSITIVE_INFINITY;
  if (aBlock !== bBlock) return aBlock < bBlock ? -1 : 1;
  if (a.address === b.address) return 0;
  return a.address < b.address ? -1 : 1;
}

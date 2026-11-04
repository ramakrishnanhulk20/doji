// Everything the Lend screen reads or works out. The reads are plain async functions over a viem client so the
// screen and scripts/check-lend.ts use the same code. Nothing here sends a transaction: the call builders only
// describe one, and the write hook simulates it before the wallet is asked.

import {
  BaseError,
  ContractFunctionRevertedError,
  decodeEventLog,
  formatUnits,
  isAddressEqual,
  pad,
  parseAbi,
  parseAbiItem,
  parseEventLogs,
  toEventSelector,
  toHex,
  zeroAddress,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { creditMarketsAbi } from "../abi/creditMarkets";
import { erc20Abi } from "../abi/external";
import { legacyCreditMarketsAbi } from "../abi/legacyCreditMarkets";
import { addressBook, pairOf, pairs, wave2Pair, type Pair, type PairKey } from "./addresses";
import { formatMusd } from "./stats";

const book = addressBook[31611];
const WEEK_SECONDS = 604_800;
/** The newest credit-unit dates that are read for a wallet, per pair. */
const MAX_UNIT_DATES = 32;
/** How far back the node is asked for logs, so an offer posted a moment ago shows before the explorer has it. */
const RPC_LOG_WINDOW = 10_000n;
const MAX_UINT128 = (1n << 128n) - 1n;
// Both CreditMarkets refuse a longest term above 4 weeks (MAX_TERM_CEILING), so no 20 October date can lie further out.
const MAX_TERM_CEILING = 4 * WEEK_SECONDS;

const settingsReads = parseAbi([
  "function minOffer() view returns (uint128)",
  "function offersPaused() view returns (bool)",
  "function maxTermSeconds() view returns (uint32)",
  "function feeShareBps() view returns (uint16)",
  "function MAX_APR_BPS() view returns (uint16)",
]);

const parkingReads = parseAbi([
  "function parkingOn() view returns (bool)",
  "function parkedPrincipal() view returns (uint256)",
  "function savingsVault() view returns (address)",
]);

const vaultWithdrawRead = parseAbi(["function withdraw(uint256 amount)"]);

const yieldReads = parseAbi([
  "function pendingOfferYield(uint256 offerId) view returns (uint256 earned)",
  "function isInVault(uint256 offerId) view returns (bool)",
  "function yieldOwedOf(address maker) view returns (uint256)",
]);

/** withdrawOfferYield books at most this many offers per call (MAX_FILLS); more ids revert BadFillCount. */
export const MAX_YIELD_IDS = 8;

const quoteRead = parseAbi([
  "function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity) view returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits)",
]);

// Wave 2's offerOf adds a fifth field, parked; the 20 October contract returns four words and is read with four.
const offerReads: Record<PairKey, Abi> = {
  wave2: parseAbi([
    "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining, bool parked))",
  ]),
  legacy: parseAbi([
    "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining))",
  ]),
};

/** Lowercased on both sides, so a checksummed address and the explorer's lowercase one compare equal. */
const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

const unitsReads = parseAbi([
  "function balanceOf(address account, uint256 id) view returns (uint256)",
  "function pendingUnits(address account, uint64 maturity) view returns (uint256)",
  "function claimOf(address account, uint64 maturity) view returns ((uint128 units, uint128 musdPaid, uint128 btcPaid))",
  "function marketOf(uint64 maturity) view returns ((uint128 faceTotal, uint128 collectedMusd, uint64 openLoans, bool isFinal, uint128 unitsAtFinal, uint128 musdAtFinal, uint128 collectedBtc, uint128 btcAtFinal))",
  "function paidOutOf(uint64 maturity) view returns (uint256 musd, uint256 btc)",
]);

export type LendSettings = {
  minOffer: bigint;
  offersPaused: boolean;
  maxTermSeconds: number;
  /** The protocol's share of the interest, in basis points. */
  feeShareBps: number;
  maxAprBps: number;
};

export async function readLendSettings(client: PublicClient): Promise<LendSettings> {
  const [minOffer, offersPaused, maxTermSeconds, feeShareBps, maxAprBps] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.creditMarkets, abi: settingsReads, functionName: "minOffer" },
      { address: book.creditMarkets, abi: settingsReads, functionName: "offersPaused" },
      { address: book.creditMarkets, abi: settingsReads, functionName: "maxTermSeconds" },
      { address: book.creditMarkets, abi: settingsReads, functionName: "feeShareBps" },
      { address: book.creditMarkets, abi: settingsReads, functionName: "MAX_APR_BPS" },
    ],
  });
  return { minOffer, offersPaused, maxTermSeconds, feeShareBps, maxAprBps };
}

export type MusdWallet = {
  balance: bigint;
  /** What the wallet has approved CreditMarkets to pull. */
  allowance: bigint;
};

export async function readMusdWallet(client: PublicClient, owner: Address): Promise<MusdWallet> {
  const [balance, allowance] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.musd, abi: erc20Abi, functionName: "balanceOf", args: [owner] },
      { address: book.musd, abi: erc20Abi, functionName: "allowance", args: [owner, book.creditMarkets] },
    ],
  });
  return { balance, allowance };
}

export type OfferQuote = {
  /** What a borrower would owe on the date for this amount at this rate, taken now. */
  face: bigint;
  /** Credit units the lender would hold. */
  makerUnits: bigint;
  /** Credit units the protocol fee takes. */
  treasuryUnits: bigint;
};

/** CreditMarkets' own quote, as if a borrower took the whole offer right now. Reverts on a date that is not open. */
export async function quoteOffer(client: PublicClient, amount: bigint, aprBps: number, maturity: number): Promise<OfferQuote> {
  const [face, makerUnits, treasuryUnits] = await client.readContract({
    address: book.creditMarkets,
    abi: quoteRead,
    functionName: "quoteFill",
    args: [amount, aprBps, BigInt(maturity)],
  });
  return { face, makerUnits, treasuryUnits };
}

/** True when the amount fits the contract's uint128, so a quote can be asked for without the encoder throwing. */
export const fitsOffer = (amount: bigint): boolean => amount > 0n && amount <= MAX_UINT128;

export type Parking = {
  /** Wave 2's parkingOn(): false while the guardian has paused earning in sMUSD for new offers. */
  on: boolean;
  /** "down" when Mezo's vault would refuse to hand back everything Doji has parked in it. */
  vault: "ok" | "down";
};

/**
 * The same check the keeper runs every hour (checkVault in packages/keeper/src/keeper.ts, alert C35): ask Mezo's vault,
 * as CreditMarkets itself, to give back all the parked principal, and change nothing. A revert means "down". A request
 * that fails any other way throws, so a broken connection never reads as a broken vault.
 */
export async function readParking(client: PublicClient): Promise<Parking> {
  const markets = wave2Pair.creditMarkets;
  const [on, parked, vault] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: markets, abi: parkingReads, functionName: "parkingOn" },
      { address: markets, abi: parkingReads, functionName: "parkedPrincipal" },
      { address: markets, abi: parkingReads, functionName: "savingsVault" },
    ],
  });
  // The chain decides which vault is checked, and it must be the one the address book shows the lender.
  if (isAddressEqual(vault, zeroAddress)) return { on, vault: "down" };
  if (!isAddressEqual(vault, book.savingsVault)) {
    throw new Error(`CreditMarkets reports savings vault ${vault}, the address book has ${book.savingsVault}`);
  }
  if (parked === 0n) return { on, vault: "ok" };

  try {
    await client.simulateContract({ address: vault, abi: vaultWithdrawRead, functionName: "withdraw", args: [parked], account: markets });
  } catch (error) {
    const reverted = error instanceof BaseError && error.walk((cause) => cause instanceof ContractFunctionRevertedError) !== null;
    if (reverted) return { on, vault: "down" };
    throw error;
  }
  return { on, vault: "ok" };
}

export type OfferYield = {
  id: bigint;
  /** MUSD the offer has earned in sMUSD that its maker has not withdrawn yet. */
  pending: bigint;
  /** The offer's unfilled MUSD sits in Mezo's vault now. */
  inVault: boolean;
};

/** Wave 2 only: the 20 October CreditMarkets has neither function. One multicall for every id given. */
export async function readOfferYields(client: PublicClient, ids: readonly bigint[]): Promise<OfferYield[]> {
  if (ids.length === 0) return [];
  const markets = wave2Pair.creditMarkets;
  const reads = await client.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: ids.flatMap((id) => [
      { address: markets, abi: yieldReads, functionName: "pendingOfferYield" as const, args: [id] as const },
      { address: markets, abi: yieldReads, functionName: "isInVault" as const, args: [id] as const },
    ]),
  });
  return ids.map((id, index) => ({
    id,
    pending: reads[index * 2] as bigint,
    inVault: reads[index * 2 + 1] as boolean,
  }));
}

/**
 * Yield already booked to the maker and not paid: a fill or a cancel books an offer's yield, after which the offer's
 * own pendingOfferYield restarts from zero, so a lender whose parked offers were all taken is owed only this.
 */
export async function readYieldOwed(client: PublicClient, maker: Address): Promise<bigint> {
  return client.readContract({ address: wave2Pair.creditMarkets, abi: yieldReads, functionName: "yieldOwedOf", args: [maker] });
}

export const earnedNumber = (wei: bigint): number => Number(formatUnits(wei, 18));

/** MUSD earned in sMUSD, always with 4 decimals. */
export const formatEarned = (value: number): string => value.toFixed(4);

/** "6.5" to 650 basis points. Null when the text is not a number yet. */
export function parseRateBps(text: string): number | null {
  if (text === "" || text === ".") return null;
  const [whole = "0", fraction = ""] = text.split(".");
  if (whole === "" && fraction === "") return null;
  return Number(whole === "" ? "0" : whole) * 100 + Number((fraction + "00").slice(0, 2));
}

/** Basis points as the text of the rate field: 650 becomes "6.50". */
export function rateFieldText(bps: number): string {
  return `${Math.floor(bps / 100)}.${String(bps % 100).padStart(2, "0")}`;
}

export type LendProblem =
  | { kind: "paused" }
  | { kind: "rateLow" }
  | { kind: "rateHigh"; maxAprBps: number }
  | { kind: "belowMin"; minOffer: bigint }
  | { kind: "overBalance"; balance: bigint };

const musdText = (wei: bigint): string => formatMusd(Number(formatUnits(wei, 18)));

/** The reasons the Post button can give before anything is sent, in the same words the contract errors use. */
export function lendProblemText(problem: LendProblem): string {
  switch (problem.kind) {
    case "paused":
      return "New offers are paused by the guardian. Cancelling still works.";
    case "rateLow":
      return "The lowest rate is 0.01%.";
    case "rateHigh":
      return `The highest rate allowed is ${+(problem.maxAprBps / 100).toFixed(2)}%.`;
    case "belowMin":
      return `The minimum offer is ${musdText(problem.minOffer)} MUSD.`;
    case "overBalance":
      return `You don't have that much MUSD. Your balance is ${musdText(problem.balance)} MUSD.`;
  }
}

export type LendStepId = "approve-musd" | "post-offer";

export type LendStep = { id: LendStepId; label: string };

/** The steps the Post button walks through. The approval is left out when the allowance already covers the amount. */
export function buildLendSteps(input: { amountText: string; allowanceCovers: boolean; parked: boolean }): LendStep[] {
  const steps: LendStep[] = [];
  if (!input.allowanceCovers) steps.push({ id: "approve-musd", label: `Approve ${input.amountText} MUSD` });
  steps.push({ id: "post-offer", label: input.parked ? "Post offer, earning in sMUSD" : "Post offer" });
  return steps;
}

// Events are described once and used for the explorer path, the node path and the receipt.
const offerPostedEvent = parseAbiItem(
  "event OfferPosted(uint256 indexed offerId, address indexed maker, uint64 indexed maturity, uint16 aprBps, uint128 amount)",
);
const offerCancelledEvent = parseAbiItem(
  "event OfferCancelled(uint256 indexed offerId, address indexed maker, uint128 refunded)",
);
const offerEvents = [offerPostedEvent, offerCancelledEvent] as const;
export const OFFER_POSTED_TOPIC: Hex = toEventSelector(offerPostedEvent);
export const OFFER_CANCELLED_TOPIC: Hex = toEventSelector(offerCancelledEvent);

type OfferLog =
  | { kind: "posted"; offerId: bigint; maturity: number; aprBps: number; amount: bigint }
  | { kind: "cancelled"; offerId: bigint };

function decodeOfferLog(topics: readonly Hex[], data: Hex): OfferLog | null {
  if (topics.length === 0) return null;
  try {
    const decoded = decodeEventLog({ abi: offerEvents, topics: topics as [Hex, ...Hex[]], data, strict: false });
    if (decoded.eventName === "OfferPosted") {
      const args = decoded.args as { offerId: bigint; maturity: bigint; aprBps: number; amount: bigint };
      return { kind: "posted", offerId: args.offerId, maturity: Number(args.maturity), aprBps: args.aprBps, amount: args.amount };
    }
    const args = decoded.args as { offerId: bigint };
    return { kind: "cancelled", offerId: args.offerId };
  } catch {
    return null;
  }
}

const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_MAX_CALLS = 5;

// Both CreditMarkets emit the same offer events and number offers from 1, so every log is checked against the pair's
// address on the way in: an offer id means nothing without the contract it came from.
async function explorerLogs(pair: Pair, topic0: Hex, maker: Address): Promise<OfferLog[]> {
  const found: OfferLog[] = [];
  let start = pair.fromBlock;

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", pair.creditMarkets);
    url.searchParams.set("topic0", topic0);
    url.searchParams.set("topic2", pad(maker, { size: 32 }));
    url.searchParams.set("topic0_2_opr", "and");
    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as Record<string, unknown>[]) : [];

    for (const raw of page) {
      if (typeof raw.address !== "string" || !sameAddress(raw.address, pair.creditMarkets)) continue;
      const topics = (Array.isArray(raw.topics) ? raw.topics : []).filter((topic): topic is Hex => typeof topic === "string");
      if (typeof raw.data !== "string") continue;
      const log = decodeOfferLog(topics, raw.data as Hex);
      if (log) found.push(log);
      if (typeof raw.blockNumber === "string") {
        const block = BigInt(raw.blockNumber);
        if (block > start) start = block;
      }
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
  }
  return found;
}

async function nodeLogs(client: PublicClient, pair: Pair, maker: Address): Promise<OfferLog[]> {
  const latest = await client.getBlockNumber();
  const floor = pair.fromBlock;
  const from = latest > RPC_LOG_WINDOW && latest - RPC_LOG_WINDOW + 1n > floor ? latest - RPC_LOG_WINDOW + 1n : floor;
  const logs = await client.request({
    method: "eth_getLogs",
    params: [
      {
        address: pair.creditMarkets,
        fromBlock: toHex(from),
        toBlock: "latest",
        topics: [[OFFER_POSTED_TOPIC, OFFER_CANCELLED_TOPIC], null, pad(maker, { size: 32 })],
      },
    ],
  });
  return logs.flatMap((log) => {
    if (!sameAddress(log.address, pair.creditMarkets)) return [];
    const decoded = decodeOfferLog(log.topics as Hex[], log.data);
    return decoded ? [decoded] : [];
  });
}

export type MyOffer = {
  /** Unique only inside its pair: both CreditMarkets number their offers from 1. */
  id: bigint;
  /** The CreditMarkets that holds the offer, and the one a cancel must go to. */
  pair: PairKey;
  maturity: number;
  aprBps: number;
  /** MUSD the offer was posted with. */
  posted: bigint;
  /** MUSD still on the offer, read from the contract now. */
  remaining: bigint;
  /** An OfferCancelled log exists for it. */
  cancelled: boolean;
  /** Its unfilled MUSD waits in Mezo's sMUSD vault. Always false on the 20 October pair, which has no vault. */
  parked: boolean;
};

/**
 * One pair's offers from this wallet. The explorer lists every OfferPosted and OfferCancelled log for the wallet from
 * the pair's deployment block, the node adds the newest 10,000 blocks so a fresh post shows before the explorer has
 * indexed it, and offerOf gives the live amount left. If the explorer is down the read fails, so a partial list never
 * passes for a full one.
 */
async function readPairOffers(client: PublicClient, pair: Pair, maker: Address): Promise<MyOffer[]> {
  const [posted, cancelled, node] = await Promise.allSettled([
    explorerLogs(pair, OFFER_POSTED_TOPIC, maker),
    explorerLogs(pair, OFFER_CANCELLED_TOPIC, maker),
    nodeLogs(client, pair, maker),
  ]);
  if (posted.status === "rejected") throw posted.reason;
  if (cancelled.status === "rejected") throw cancelled.reason;

  const logs = [...posted.value, ...cancelled.value, ...(node.status === "fulfilled" ? node.value : [])];
  const offers = new Map<bigint, { maturity: number; aprBps: number; posted: bigint }>();
  const cancelledIds = new Set<bigint>();
  for (const log of logs) {
    if (log.kind === "posted") offers.set(log.offerId, { maturity: log.maturity, aprBps: log.aprBps, posted: log.amount });
    else cancelledIds.add(log.offerId);
  }

  const ids = [...offers.keys()].sort((a, b) => (a < b ? 1 : a > b ? -1 : 0));
  if (ids.length === 0) return [];
  const live = await client.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: ids.map((id) => ({ address: pair.creditMarkets, abi: offerReads[pair.key], functionName: "offerOf", args: [id] })),
  });

  // The logs only name candidates. An offer is shown as this wallet's only when the contract says this wallet made it;
  // cancelOffer keeps the maker, so cancelled offers still pass.
  return ids.flatMap((id, index) => {
    const onChain = live[index] as { maker: Address; remaining: bigint; parked?: boolean };
    if (!isAddressEqual(onChain.maker, maker)) return [];
    const fixed = offers.get(id) as { maturity: number; aprBps: number; posted: bigint };
    return [
      {
        id,
        pair: pair.key,
        maturity: fixed.maturity,
        aprBps: fixed.aprBps,
        posted: fixed.posted,
        remaining: onChain.remaining,
        cancelled: cancelledIds.has(id),
        parked: onChain.parked === true,
      },
    ];
  });
}

/**
 * The offers a wallet has posted on both pairs, Wave 2 first and newest first inside each, every one tagged with the
 * pair it lives on. Either pair's read failing fails the whole read, so a partial list never passes for a full one.
 */
export async function readMyOffers(client: PublicClient, maker: Address): Promise<MyOffer[]> {
  return (await Promise.all(pairs.map((pair) => readPairOffers(client, pair, maker)))).flat();
}

export type OfferStatus = "open" | "partly" | "taken" | "cancelled" | "expired";

/**
 * Open: nothing taken. Partly taken: some left. Taken: nothing left and no cancel log, so borrowers took it all.
 * Cancelled: nothing left after a cancel. Expired: its date has passed with MUSD still on it, which can only be cancelled.
 */
export function offerStatus(offer: Pick<MyOffer, "posted" | "remaining" | "cancelled" | "maturity">, now: number): OfferStatus {
  if (offer.remaining === 0n) return offer.cancelled ? "cancelled" : "taken";
  if (now >= offer.maturity) return "expired";
  return offer.remaining === offer.posted ? "open" : "partly";
}

export type MarketView = {
  faceTotal: bigint;
  collectedMusd: bigint;
  openLoans: bigint;
  isFinal: boolean;
  unitsAtFinal: bigint;
  musdAtFinal: bigint;
  collectedBtc: bigint;
  btcAtFinal: bigint;
};

export type ClaimView = { units: bigint; musdPaid: bigint; btcPaid: bigint };

export type DateUnits = {
  /** The CreditMarkets that issued these units. The same date can have units on both pairs, as two rows. */
  pair: PairKey;
  /** Unix seconds of Thursday 00:00 UTC. */
  maturity: number;
  /** Credit units the wallet holds (the ERC-1155 balance). */
  balance: bigint;
  /** Units from filled offers that are minted when the wallet claims them. */
  pending: bigint;
  claim: ClaimView;
  market: MarketView;
  /** What the market has paid out so far through redeem and withdrawals together. */
  paidOut: { musd: bigint; btc: bigint };
};

const deploymentTimes = new Map<PairKey, Promise<number>>();

/** The timestamp of a pair's deployment block, read once. No date before the next Thursday after it can have units. */
function readDeploymentTime(client: PublicClient, pair: Pair): Promise<number> {
  const known = deploymentTimes.get(pair.key);
  if (known !== undefined) return known;
  const read = client.getBlock({ blockNumber: pair.fromBlock }).then((block) => Number(block.timestamp));
  deploymentTimes.set(pair.key, read);
  read.catch(() => {
    deploymentTimes.delete(pair.key);
  });
  return read;
}

/** Every Thursday from the first one after the deployment up to now plus the longest term, the newest 32. */
export function unitDates(deployedAt: number, now: number, maxTermSeconds: number): number[] {
  const dates: number[] = [];
  for (let date = (Math.floor(deployedAt / WEEK_SECONDS) + 1) * WEEK_SECONDS; date <= now + maxTermSeconds; date += WEEK_SECONDS) {
    dates.push(date);
  }
  return dates.slice(-MAX_UNIT_DATES);
}

/**
 * The dates where the wallet has units, units waiting to be claimed, or an early-withdrawal claim, on both pairs: one
 * row per pair and date, newest date first and Wave 2 first on the same date. `maxTermSeconds` is Wave 2's; the 20
 * October dates run to the 4-week ceiling, which its own setting can never pass.
 */
export async function readCreditUnits(client: PublicClient, owner: Address, now: number, maxTermSeconds: number): Promise<DateUnits[]> {
  const deployedAt = await Promise.all(pairs.map((pair) => readDeploymentTime(client, pair)));
  const slots = pairs.flatMap((pair, index) =>
    unitDates(deployedAt[index] as number, now, pair.key === wave2Pair.key ? maxTermSeconds : MAX_TERM_CEILING).map(
      (maturity) => ({ pair, maturity }),
    ),
  );
  if (slots.length === 0) return [];

  const reads = await client.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: slots.flatMap(({ pair, maturity }) => [
      { address: pair.creditMarkets, abi: unitsReads, functionName: "balanceOf" as const, args: [owner, BigInt(maturity)] as const },
      { address: pair.creditMarkets, abi: unitsReads, functionName: "pendingUnits" as const, args: [owner, BigInt(maturity)] as const },
      { address: pair.creditMarkets, abi: unitsReads, functionName: "claimOf" as const, args: [owner, BigInt(maturity)] as const },
      { address: pair.creditMarkets, abi: unitsReads, functionName: "marketOf" as const, args: [BigInt(maturity)] as const },
      { address: pair.creditMarkets, abi: unitsReads, functionName: "paidOutOf" as const, args: [BigInt(maturity)] as const },
    ]),
  });

  const rows: DateUnits[] = [];
  slots.forEach(({ pair, maturity }, index) => {
    const at = index * 5;
    const balance = reads[at] as bigint;
    const pending = reads[at + 1] as bigint;
    const claim = reads[at + 2] as ClaimView;
    const market = reads[at + 3] as MarketView;
    const paid = reads[at + 4] as readonly [bigint, bigint];
    if (balance === 0n && pending === 0n && claim.units === 0n) return;
    rows.push({
      pair: pair.key,
      maturity,
      balance,
      pending,
      claim: { units: claim.units, musdPaid: claim.musdPaid, btcPaid: claim.btcPaid },
      market: { ...market },
      paidOut: { musd: paid[0], btc: paid[1] },
    });
  });
  const order = (key: PairKey) => pairs.findIndex((pair) => pair.key === key);
  return rows.sort((a, b) => b.maturity - a.maturity || order(a.pair) - order(b.pair));
}

export type DateState = "open" | "due" | "closeable" | "final";

/**
 * Open: the date has not come. Due: it has passed and loans are still open. Closeable: it has passed and every loan
 * has ended, so anyone can close the market. Final: the market is closed and units redeem.
 */
export function dateState(market: MarketView, maturity: number, now: number): DateState {
  if (market.isFinal) return "final";
  if (now <= maturity) return "open";
  return market.openLoans === 0n && market.faceTotal > 0n ? "closeable" : "due";
}

/**
 * What withdrawCollected pays if `moveUnits` more units go into the wallet's claim. The contract works out the claim's
 * whole share of what is collected and pays the part not paid yet, so this does the same sum with the same rounding.
 */
export function withdrawalAmounts(market: MarketView, claim: ClaimView, moveUnits: bigint): { musd: bigint; btc: bigint } {
  if (market.faceTotal === 0n) return { musd: 0n, btc: 0n };
  const held = claim.units + moveUnits;
  const musdShare = (held * market.collectedMusd) / market.faceTotal;
  const musdDue = held < musdShare ? held : musdShare;
  const btcDue = (held * market.collectedBtc) / market.faceTotal;
  return {
    musd: musdDue > claim.musdPaid ? musdDue - claim.musdPaid : 0n,
    btc: btcDue > claim.btcPaid ? btcDue - claim.btcPaid : 0n,
  };
}

/** What redeem pays for `units` once the market is closed. */
export function redeemAmounts(market: MarketView, units: bigint): { musd: bigint; btc: bigint } {
  if (!market.isFinal || market.unitsAtFinal === 0n) return { musd: 0n, btc: 0n };
  const musdShare = (units * market.musdAtFinal) / market.unitsAtFinal;
  return {
    musd: units < musdShare ? units : musdShare,
    btc: (units * market.btcAtFinal) / market.unitsAtFinal,
  };
}

/** Collected so far, per unit, as exact fractions in 18 decimals. Zero when nothing has been lent. */
export function unitValue(market: MarketView): { musd: bigint; btc: bigint } {
  if (market.faceTotal === 0n) return { musd: 0n, btc: 0n };
  const scale = 10n ** 18n;
  return {
    musd: (market.collectedMusd * scale) / market.faceTotal,
    btc: (market.collectedBtc * scale) / market.faceTotal,
  };
}

/** MUSD or units with 2 decimals. An amount that is real but under 0.01 shows its own digits, so it never reads as zero. */
export function formatUnitsNumber(value: number): string {
  return value > 0 && value < 0.01 ? value.toFixed(6).replace(/0+$/, "") : formatMusd(value);
}

/** A fraction in 18 decimals shown with 4 decimals. A value that is real but smaller than that shows 8, so it never reads as zero. */
export function fmtPerUnit(wei: bigint): string {
  const text = (digits: number) => {
    const scaled = wei / 10n ** BigInt(18 - digits);
    const padded = scaled.toString().padStart(digits + 1, "0");
    return `${padded.slice(0, padded.length - digits)}.${padded.slice(padded.length - digits)}`;
  };
  const short = text(4);
  return wei > 0n && short === "0.0000" ? text(8) : short;
}

/** A BTC amount in wei with 6 decimals. Anything real but smaller reads "<0.000001". */
export function fmtBtcAmount(wei: bigint): string {
  const scaled = wei / 10n ** 12n;
  if (wei > 0n && scaled === 0n) return "<0.000001";
  const padded = scaled.toString().padStart(7, "0");
  return `${padded.slice(0, -6)}.${padded.slice(-6)}`;
}

export type LendCall = {
  target: "creditMarkets" | "legacyCreditMarkets" | "musd";
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

/** A call on one pair's CreditMarkets, with that pair's own ABI and the address book name the write hook resolves. */
const marketsCall = (key: PairKey, functionName: string, args: readonly unknown[]): LendCall => {
  const pair = pairOf(key);
  return {
    target: key === "wave2" ? "creditMarkets" : "legacyCreditMarkets",
    address: pair.creditMarkets,
    abi: (key === "wave2" ? creditMarketsAbi : legacyCreditMarketsAbi) as Abi,
    functionName,
    args,
  };
};

/** MUSD is approved for the exact amount of the offer, never more, and only to Wave 2, where every new offer goes. */
export const approveMusdCall = (amount: bigint): LendCall => ({
  target: "musd",
  address: book.musd,
  abi: erc20Abi as Abi,
  functionName: "approve",
  args: [wave2Pair.creditMarkets, amount],
});

/** A new offer always goes to Wave 2. */
export const postOfferCall = (maturity: number, aprBps: number, amount: bigint): LendCall =>
  marketsCall("wave2", "postOffer", [BigInt(maturity), aprBps, amount]);

/** Same as postOfferCall, and the offer's unfilled MUSD sits in Mezo's sMUSD vault until a borrower takes it. */
export const postParkedOfferCall = (maturity: number, aprBps: number, amount: bigint): LendCall =>
  marketsCall("wave2", "postParkedOffer", [BigInt(maturity), aprBps, amount]);

export const withdrawOfferYieldCall = (offerIds: readonly bigint[]): LendCall =>
  marketsCall("wave2", "withdrawOfferYield", [offerIds]);

export const cancelOfferCall = (offer: Pick<MyOffer, "id" | "pair">): LendCall =>
  marketsCall(offer.pair, "cancelOffer", [offer.id]);

export const claimUnitsCall = (pair: PairKey, maturity: number): LendCall => marketsCall(pair, "claimUnits", [BigInt(maturity)]);

export const sendUnitsCall = (pair: PairKey, from: Address, to: Address, maturity: number, units: bigint): LendCall =>
  marketsCall(pair, "safeTransferFrom", [from, to, BigInt(maturity), units, "0x"]);

export const withdrawCollectedCall = (pair: PairKey, maturity: number, units: bigint): LendCall =>
  marketsCall(pair, "withdrawCollected", [BigInt(maturity), units]);

export const finalizeCall = (pair: PairKey, maturity: number): LendCall => marketsCall(pair, "finalize", [BigInt(maturity)]);

export const redeemCall = (pair: PairKey, maturity: number, units: bigint): LendCall =>
  marketsCall(pair, "redeem", [BigInt(maturity), units]);

type ReceiptLog = { address: Address; topics: readonly Hex[]; data: Hex };

/**
 * Only the logs Wave 2 CreditMarkets itself emitted. Any contract can emit an event with the same name, so a receipt
 * is never read for an offer id or a payout without this first (C49).
 */
const wave2Logs = (logs: readonly ReceiptLog[]): ReceiptLog[] =>
  logs.filter((log) => sameAddress(log.address, wave2Pair.creditMarkets));

/** The id from the OfferPosted event Wave 2 emitted in this receipt, or null when it emitted none. */
export function postedOfferId(logs: readonly ReceiptLog[]): bigint | null {
  const [log] = parseEventLogs({ abi: creditMarketsAbi as Abi, eventName: "OfferPosted", logs: wave2Logs(logs) as never });
  const args = (log?.args ?? {}) as { offerId?: bigint };
  return args.offerId ?? null;
}

/** What the OfferYieldWithdrawn event Wave 2 emitted in this receipt says was paid, and what Mezo's vault still owes. */
export function withdrawnYield(logs: readonly ReceiptLog[]): { paid: bigint; stillOwed: bigint } | null {
  const [log] = parseEventLogs({ abi: creditMarketsAbi as Abi, eventName: "OfferYieldWithdrawn", logs: wave2Logs(logs) as never });
  const args = log?.args as { paid?: bigint; stillOwed?: bigint } | undefined;
  if (args?.paid === undefined || args.stillOwed === undefined) return null;
  return { paid: args.paid, stillOwed: args.stillOwed };
}

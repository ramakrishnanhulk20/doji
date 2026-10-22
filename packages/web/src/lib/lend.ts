// Everything the Lend screen reads or works out. The reads are plain async functions over a viem client so the
// screen and scripts/check-lend.ts use the same code. Nothing here sends a transaction: the call builders only
// describe one, and the write hook simulates it before the wallet is asked.

import {
  decodeEventLog,
  formatUnits,
  isAddressEqual,
  pad,
  parseAbi,
  parseAbiItem,
  toEventSelector,
  toHex,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { creditMarketsAbi } from "../abi/creditMarkets";
import { erc20Abi } from "../abi/external";
import { deployment } from "../generated/deployment";
import { addressBook } from "./addresses";
import { formatMusd } from "./stats";

const book = addressBook[31611];
const WEEK_SECONDS = 604_800;
/** The newest credit-unit dates that are read for a wallet. */
const MAX_UNIT_DATES = 32;
/** How far back the node is asked for logs, so an offer posted a moment ago shows before the explorer has it. */
const RPC_LOG_WINDOW = 10_000n;
const MAX_UINT128 = (1n << 128n) - 1n;

const settingsReads = parseAbi([
  "function minOffer() view returns (uint128)",
  "function offersPaused() view returns (bool)",
  "function maxTermSeconds() view returns (uint32)",
  "function feeShareBps() view returns (uint16)",
  "function MAX_APR_BPS() view returns (uint16)",
]);

const quoteRead = parseAbi([
  "function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity) view returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits)",
]);

const offerRead = parseAbi([
  "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining))",
]);

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
export function buildLendSteps(input: { amountText: string; allowanceCovers: boolean }): LendStep[] {
  const steps: LendStep[] = [];
  if (!input.allowanceCovers) steps.push({ id: "approve-musd", label: `Approve ${input.amountText} MUSD` });
  steps.push({ id: "post-offer", label: "Post offer" });
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

async function explorerLogs(topic0: Hex, maker: Address): Promise<OfferLog[]> {
  const found: OfferLog[] = [];
  let start = BigInt(deployment.block);

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", book.creditMarkets);
    url.searchParams.set("topic0", topic0);
    url.searchParams.set("topic2", pad(maker, { size: 32 }));
    url.searchParams.set("topic0_2_opr", "and");
    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as Record<string, unknown>[]) : [];

    for (const raw of page) {
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

async function nodeLogs(client: PublicClient, maker: Address): Promise<OfferLog[]> {
  const latest = await client.getBlockNumber();
  const floor = BigInt(deployment.block);
  const from = latest > RPC_LOG_WINDOW && latest - RPC_LOG_WINDOW + 1n > floor ? latest - RPC_LOG_WINDOW + 1n : floor;
  const logs = await client.request({
    method: "eth_getLogs",
    params: [
      {
        address: book.creditMarkets,
        fromBlock: toHex(from),
        toBlock: "latest",
        topics: [[OFFER_POSTED_TOPIC, OFFER_CANCELLED_TOPIC], null, pad(maker, { size: 32 })],
      },
    ],
  });
  return logs.flatMap((log) => {
    const decoded = decodeOfferLog(log.topics as Hex[], log.data);
    return decoded ? [decoded] : [];
  });
}

export type MyOffer = {
  id: bigint;
  maturity: number;
  aprBps: number;
  /** MUSD the offer was posted with. */
  posted: bigint;
  /** MUSD still on the offer, read from the contract now. */
  remaining: bigint;
  /** An OfferCancelled log exists for it. */
  cancelled: boolean;
};

/**
 * The offers a wallet has posted. The explorer lists every OfferPosted and OfferCancelled log for the wallet from the
 * deployment block, the node adds the newest 10,000 blocks so a fresh post shows before the explorer has indexed it,
 * and offerOf gives the live amount left. If the explorer is down the read fails, so a partial list never passes for
 * a full one.
 */
export async function readMyOffers(client: PublicClient, maker: Address): Promise<MyOffer[]> {
  const [posted, cancelled, node] = await Promise.allSettled([
    explorerLogs(OFFER_POSTED_TOPIC, maker),
    explorerLogs(OFFER_CANCELLED_TOPIC, maker),
    nodeLogs(client, maker),
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
    contracts: ids.map((id) => ({ address: book.creditMarkets, abi: offerRead, functionName: "offerOf" as const, args: [id] as const })),
  });

  // The logs only name candidates. An offer is shown as this wallet's only when the contract says this wallet made it;
  // cancelOffer keeps the maker, so cancelled offers still pass.
  return ids.flatMap((id, index) => {
    const onChain = live[index] as { maker: Address; remaining: bigint };
    if (!isAddressEqual(onChain.maker, maker)) return [];
    const fixed = offers.get(id) as { maturity: number; aprBps: number; posted: bigint };
    return [
      {
        id,
        maturity: fixed.maturity,
        aprBps: fixed.aprBps,
        posted: fixed.posted,
        remaining: onChain.remaining,
        cancelled: cancelledIds.has(id),
      },
    ];
  });
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

let deploymentTime: Promise<number> | null = null;

/** The timestamp of the deployment block, read once. No date before the next Thursday after it can have units. */
function readDeploymentTime(client: PublicClient): Promise<number> {
  if (deploymentTime === null) {
    deploymentTime = client.getBlock({ blockNumber: BigInt(deployment.block) }).then((block) => Number(block.timestamp));
    deploymentTime.catch(() => {
      deploymentTime = null;
    });
  }
  return deploymentTime;
}

/** Every Thursday from the first one after the deployment up to now plus the longest term, the newest 32. */
export function unitDates(deployedAt: number, now: number, maxTermSeconds: number): number[] {
  const dates: number[] = [];
  for (let date = (Math.floor(deployedAt / WEEK_SECONDS) + 1) * WEEK_SECONDS; date <= now + maxTermSeconds; date += WEEK_SECONDS) {
    dates.push(date);
  }
  return dates.slice(-MAX_UNIT_DATES);
}

/** The dates where the wallet has units, units waiting to be claimed, or an early-withdrawal claim. Newest date first. */
export async function readCreditUnits(client: PublicClient, owner: Address, now: number, maxTermSeconds: number): Promise<DateUnits[]> {
  const dates = unitDates(await readDeploymentTime(client), now, maxTermSeconds);
  if (dates.length === 0) return [];

  const reads = await client.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: dates.flatMap((date) => [
      { address: book.creditMarkets, abi: unitsReads, functionName: "balanceOf" as const, args: [owner, BigInt(date)] as const },
      { address: book.creditMarkets, abi: unitsReads, functionName: "pendingUnits" as const, args: [owner, BigInt(date)] as const },
      { address: book.creditMarkets, abi: unitsReads, functionName: "claimOf" as const, args: [owner, BigInt(date)] as const },
      { address: book.creditMarkets, abi: unitsReads, functionName: "marketOf" as const, args: [BigInt(date)] as const },
      { address: book.creditMarkets, abi: unitsReads, functionName: "paidOutOf" as const, args: [BigInt(date)] as const },
    ]),
  });

  const rows: DateUnits[] = [];
  dates.forEach((maturity, index) => {
    const at = index * 5;
    const balance = reads[at] as bigint;
    const pending = reads[at + 1] as bigint;
    const claim = reads[at + 2] as ClaimView;
    const market = reads[at + 3] as MarketView;
    const paid = reads[at + 4] as readonly [bigint, bigint];
    if (balance === 0n && pending === 0n && claim.units === 0n) return;
    rows.push({
      maturity,
      balance,
      pending,
      claim: { units: claim.units, musdPaid: claim.musdPaid, btcPaid: claim.btcPaid },
      market: { ...market },
      paidOut: { musd: paid[0], btc: paid[1] },
    });
  });
  return rows.sort((a, b) => b.maturity - a.maturity);
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
  target: "creditMarkets" | "musd";
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

const marketsCall = (functionName: string, args: readonly unknown[]): LendCall => ({
  target: "creditMarkets",
  address: book.creditMarkets,
  abi: creditMarketsAbi as Abi,
  functionName,
  args,
});

/** MUSD is approved for the exact amount of the offer, never more. */
export const approveMusdCall = (amount: bigint): LendCall => ({
  target: "musd",
  address: book.musd,
  abi: erc20Abi as Abi,
  functionName: "approve",
  args: [book.creditMarkets, amount],
});

export const postOfferCall = (maturity: number, aprBps: number, amount: bigint): LendCall =>
  marketsCall("postOffer", [BigInt(maturity), aprBps, amount]);

export const cancelOfferCall = (offerId: bigint): LendCall => marketsCall("cancelOffer", [offerId]);

export const claimUnitsCall = (maturity: number): LendCall => marketsCall("claimUnits", [BigInt(maturity)]);

export const sendUnitsCall = (from: Address, to: Address, maturity: number, units: bigint): LendCall =>
  marketsCall("safeTransferFrom", [from, to, BigInt(maturity), units, "0x"]);

export const withdrawCollectedCall = (maturity: number, units: bigint): LendCall =>
  marketsCall("withdrawCollected", [BigInt(maturity), units]);

export const finalizeCall = (maturity: number): LendCall => marketsCall("finalize", [BigInt(maturity)]);

export const redeemCall = (maturity: number, units: bigint): LendCall => marketsCall("redeem", [BigInt(maturity), units]);

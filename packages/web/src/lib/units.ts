// Everything the units market reads or works out. The reads are plain async functions over a viem client so the screen
// and scripts/check-units.ts use the same code. Nothing here sends a transaction: the call builders only describe one,
// and the write hook simulates it before the wallet is asked.

import {
  encodeAbiParameters,
  formatUnits,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { creditMarketsAbi } from "../abi/creditMarkets";
import { erc20Abi } from "../abi/external";
import { unitMarketAbi } from "../abi/unitMarket";
import { addressBook } from "./addresses";
import { earnedNumber, formatEarned, formatUnitsNumber } from "./lend";
import { formatDate } from "./stats";

const book = addressBook[31611];
const DAY_SECONDS = 86_400;
const YEAR_DAYS = 365;
const PRICE_SCALE = 10n ** 18n;
const BPS = 10_000n;

/** The strip a paused market shows above the listings and inside the sheets. */
export const MARKET_PAUSED_LINE =
  "The units market is paused by Doji's guardian. Buying and selling resume when it ends. Cancelling a listing still works.";

export type Listing = {
  id: bigint;
  seller: Address;
  maturity: number;
  expiry: number;
  feeBps: number;
  unitsLeft: bigint;
  pricePerUnit: bigint;
};

/**
 * Every listing that still has units, soonest Thursday first and the cheapest price first inside a Thursday. One
 * multicall reads every id, so a listing that was emptied or cancelled drops out and nothing is left out.
 */
export async function readListings(client: PublicClient): Promise<Listing[]> {
  const next = await client.readContract({ address: book.unitMarket, abi: unitMarketAbi, functionName: "nextListingId" });

  const ids: bigint[] = [];
  for (let id = 1n; id < next; id++) ids.push(id);
  if (ids.length === 0) return [];

  const reads = await client.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: ids.map((id) => ({
      address: book.unitMarket,
      abi: unitMarketAbi,
      functionName: "listingOf" as const,
      args: [id] as const,
    })),
  });

  return reads
    .map((listing, index) => ({
      id: ids[index] as bigint,
      seller: listing.seller,
      maturity: Number(listing.maturity),
      expiry: Number(listing.expiry),
      feeBps: listing.feeBps,
      unitsLeft: listing.unitsLeft,
      pricePerUnit: listing.pricePerUnit,
    }))
    .filter((listing) => listing.unitsLeft > 0n)
    .sort((a, b) => a.maturity - b.maturity || (a.pricePerUnit < b.pricePerUnit ? -1 : a.pricePerUnit > b.pricePerUnit ? 1 : 0));
}

export type ListingStage = "open" | "dated" | "expired";

/**
 * Where a listing stands at `now`. A unit is worth 1 MUSD only before its Thursday; after it, what the unit pays is
 * whatever its loans returned, which the chain decides. So a listing past its Thursday ("dated") promises no yield and
 * is not offered for buying, even though UnitMarket would still take a buy until the listing's own last day. "expired"
 * is from that last day on, when the units can only go back to the seller.
 */
export function listingStage(listing: Pick<Listing, "maturity" | "expiry">, now: number): ListingStage {
  if (now >= listing.expiry) return "expired";
  if (listing.maturity <= now) return "dated";
  return "open";
}

export type MarketSettings = { feeBps: number; paused: boolean };

export async function readMarketSettings(client: PublicClient): Promise<MarketSettings> {
  const [feeBps, paused] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.unitMarket, abi: unitMarketAbi, functionName: "feeBps" },
      { address: book.unitMarket, abi: unitMarketAbi, functionName: "paused" },
    ],
  });
  return { feeBps, paused };
}

/** UnitMarket's own price for a buy: the cost rounds up and the fee, which the seller pays out of it, rounds down. */
export async function quoteBuy(client: PublicClient, listingId: bigint, units: bigint): Promise<{ cost: bigint; fee: bigint }> {
  const [cost, fee] = await client.readContract({
    address: book.unitMarket,
    abi: unitMarketAbi,
    functionName: "quoteBuy",
    args: [listingId, units],
  });
  return { cost, fee };
}

export type UnitWallet = {
  balance: bigint;
  /** What the wallet has approved UnitMarket to pull. CreditMarkets has its own, separate allowance. */
  allowance: bigint;
};

export async function readUnitWallet(client: PublicClient, owner: Address): Promise<UnitWallet> {
  const [balance, allowance] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.musd, abi: erc20Abi, functionName: "balanceOf", args: [owner] },
      { address: book.musd, abi: erc20Abi, functionName: "allowance", args: [owner, book.unitMarket] },
    ],
  });
  return { balance, allowance };
}

/**
 * What a buyer earns by holding a unit to its Thursday: a unit pays 1 MUSD there, so a price of 0.99 earns about
 * 1.01%. The yearly figure scales that to 365 days and is 0 once the date has come.
 */
export function unitYield(pricePerUnit: bigint, maturity: number, now: number): { toMaturityPct: number; perYearPct: number } {
  // The contract refuses a zero price, so this only guards the division.
  if (pricePerUnit <= 0n) return { toMaturityPct: 0, perYearPct: 0 };
  const toMaturityPct = (Number(PRICE_SCALE) / Number(pricePerUnit) - 1) * 100;
  const perYearPct = maturity > now ? (toMaturityPct * YEAR_DAYS * DAY_SECONDS) / (maturity - now) : 0;
  return { toMaturityPct, perYearPct };
}

/** What the seller keeps of each unit's price after the fee, rounded down as the contract does. */
export const sellerNetPrice = (pricePerUnit: bigint, feeBps: number): bigint => (pricePerUnit * (BPS - BigInt(feeBps))) / BPS;

/** Units or MUSD with 2 decimals. An amount that is real but under 0.01 shows its own digits, so it never reads as zero. */
export const fmtUnitsAmount = (wei: bigint): string => formatUnitsNumber(Number(formatUnits(wei, 18)));

/** MUSD with 4 decimals. */
export const fmtFourDecimals = (wei: bigint): string => formatEarned(earnedNumber(wei));

/** The exact amount as the text of a units field, with at least two decimals so a round number reads 3.00. */
export function unitsFieldText(wei: bigint): string {
  const [whole = "0", fraction = ""] = formatUnits(wei, 18).split(".");
  return `${whole}.${fraction.padEnd(2, "0")}`;
}

/** A price per unit with 3 decimals. */
export const fmtPrice = (wei: bigint): string => Number(formatUnits(wei, 18)).toFixed(3);

export type BuyStepId = "approve-musd" | "buy-units";

export type BuyStep = { id: BuyStepId; label: string };

/** The approval is left out when the allowance already covers the cost. */
export function buildBuySteps(input: { cost: bigint; allowanceCovers: boolean }): BuyStep[] {
  const steps: BuyStep[] = [];
  if (!input.allowanceCovers) steps.push({ id: "approve-musd", label: `Approve ${fmtFourDecimals(input.cost)} MUSD` });
  steps.push({ id: "buy-units", label: "Buy units" });
  return steps;
}

export type ExpiryChoice = { label: string; expiry: number };

const EARLY_EXPIRY_SPANS = [
  { label: "1 day", seconds: DAY_SECONDS },
  { label: "3 days", seconds: 3 * DAY_SECONDS },
  { label: "1 week", seconds: 7 * DAY_SECONDS },
] as const;

/**
 * How long a listing stays open. Each short span counts from the next midnight UTC, and none may reach the last day
 * before the Thursday: that day is the last choice, which is also the default.
 */
export function expiryChoices(maturity: number, now: number): ExpiryChoice[] {
  const lastDay = maturity - DAY_SECONDS;
  const firstMidnight = (Math.floor(now / DAY_SECONDS) + 1) * DAY_SECONDS;
  const early = EARLY_EXPIRY_SPANS.map((span) => ({ label: span.label, expiry: firstMidnight + span.seconds })).filter(
    (choice) => choice.expiry < lastDay,
  );
  return [...early, { label: `Until ${formatDate(lastDay)}`, expiry: lastDay }];
}

/** The same shape as the Lend calls, with the extra names this market's writes go to. */
export type UnitCall = {
  target: "unitMarket" | "creditMarkets" | "musd";
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

/** MUSD is approved for the exact cost the quote gave, never more. */
export const approveUnitBuyCall = (cost: bigint): UnitCall => ({
  target: "musd",
  abi: erc20Abi as Abi,
  functionName: "approve",
  args: [book.unitMarket, cost],
});

/** The listing's price as read is the ceiling, so a price raised between the read and the block can never be charged. */
export const buyCall = (listingId: bigint, units: bigint, maxPricePerUnit: bigint): UnitCall => ({
  target: "unitMarket",
  abi: unitMarketAbi as Abi,
  functionName: "buy",
  args: [listingId, units, maxPricePerUnit],
});

export const cancelListingCall = (id: bigint): UnitCall => ({
  target: "unitMarket",
  abi: unitMarketAbi as Abi,
  functionName: "cancel",
  args: [id],
});

export const returnExpiredCall = (id: bigint): UnitCall => ({
  target: "unitMarket",
  abi: unitMarketAbi as Abi,
  functionName: "returnExpired",
  args: [id],
});

/** A listing is created by sending Wave 2 units to UnitMarket with the price and the last day as the data. */
export const listUnitsCall = (from: Address, maturity: number, units: bigint, pricePerUnit: bigint, expiry: number): UnitCall => ({
  target: "creditMarkets",
  abi: creditMarketsAbi as Abi,
  functionName: "safeTransferFrom",
  args: [
    from,
    book.unitMarket,
    BigInt(maturity),
    units,
    encodeAbiParameters([{ type: "uint128" }, { type: "uint64" }], [pricePerUnit, BigInt(expiry)]),
  ],
});

type ReceiptLog = { address: Address; topics: readonly Hex[]; data: Hex };

/** The id from the Listed event UnitMarket itself emitted in this receipt, or null when it emitted none. */
export function listedId(logs: readonly ReceiptLog[]): bigint | null {
  const own = logs.filter((log) => log.address.toLowerCase() === book.unitMarket.toLowerCase());
  const [log] = parseEventLogs({ abi: unitMarketAbi as Abi, eventName: "Listed", logs: own as never });
  const args = (log?.args ?? {}) as { listingId?: bigint };
  return args.listingId ?? null;
}

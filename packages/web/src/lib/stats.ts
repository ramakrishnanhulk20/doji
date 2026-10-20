import { createPublicClient, formatUnits, http, parseAbi } from "viem";
import { addressBook } from "./addresses";
import { mezoMainnetChain, mezoTestnetChain } from "./chains";

const mainnetClient = createPublicClient({ chain: mezoMainnetChain, transport: http() });
const testnetClient = createPublicClient({ chain: mezoTestnetChain, transport: http() });

const veBtcAbi = parseAbi(["function supply() view returns (uint256)"]);
const priceFeedAbi = parseAbi(["function fetchPrice() view returns (uint256)"]);
const creditMarketsAbi = parseAbi([
  "function nextOfferId() view returns (uint256)",
  "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining))",
]);

// Only the newest offers are scanned: older ids are long settled and would cost a read each.
const OFFER_WINDOW = 200n;

export type MezoLocked = {
  btc: number;
  /** Null when the oracle read reverts, which it does once the price is older than 60 seconds. */
  usd: number | null;
};

export type OfferStats = {
  musdOnOffer: number;
  openOffers: number;
  /** The lowest rate among open offers for the nearest maturity, or null when no offer is open. */
  best: { maturity: number; aprBps: number } | null;
};

export async function readMezoLocked(): Promise<MezoLocked> {
  const { veBTC, priceFeed } = addressBook[31612];
  const [supply, price] = await Promise.all([
    mainnetClient.readContract({ address: veBTC, abi: veBtcAbi, functionName: "supply" }),
    mainnetClient.readContract({ address: priceFeed, abi: priceFeedAbi, functionName: "fetchPrice" }).catch(() => null),
  ]);
  return {
    btc: Number(formatUnits(supply, 18)),
    usd: price === null ? null : Number(formatUnits(supply * price, 36)),
  };
}

export async function readOffers(): Promise<OfferStats> {
  const { creditMarkets } = addressBook[31611];
  const next = await testnetClient.readContract({
    address: creditMarkets,
    abi: creditMarketsAbi,
    functionName: "nextOfferId",
  });

  const first = next > OFFER_WINDOW + 1n ? next - OFFER_WINDOW : 1n;
  const ids: bigint[] = [];
  for (let id = first; id < next; id++) ids.push(id);

  const offers =
    ids.length === 0
      ? []
      : await testnetClient.multicall({
          allowFailure: false,
          batchSize: 16_384,
          contracts: ids.map((id) => ({
            address: creditMarkets,
            abi: creditMarketsAbi,
            functionName: "offerOf" as const,
            args: [id] as const,
          })),
        });

  const now = BigInt(Math.floor(Date.now() / 1000));
  const open = offers.filter((offer) => offer.remaining > 0n && offer.maturity > now);

  const musdOnOffer = open.reduce((sum, offer) => sum + offer.remaining, 0n);

  let best: OfferStats["best"] = null;
  for (const offer of open) {
    const maturity = Number(offer.maturity);
    if (best === null || maturity < best.maturity || (maturity === best.maturity && offer.aprBps < best.aprBps)) {
      best = { maturity, aprBps: offer.aprBps };
    }
  }

  return { musdOnOffer: Number(formatUnits(musdOnOffer, 18)), openOffers: open.length, best };
}

export async function readBlock(): Promise<number> {
  return Number(await testnetClient.getBlockNumber());
}

const numberFormat = new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const usdFormat = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  notation: "compact",
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});
const dateFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: "UTC",
  weekday: "short",
  day: "numeric",
  month: "short",
});

export const formatBtc = (btc: number): string => numberFormat.format(btc);
export const formatMusd = (musd: number): string => numberFormat.format(musd);
export const formatUsdCompact = (usd: number): string => usdFormat.format(usd);
export const formatApr = (percent: number): string => `${numberFormat.format(percent)}%`;
export const formatBlock = (block: number): string => Math.round(block).toLocaleString("en-US");

/** "Thu 22 Oct", in UTC, from a unix timestamp in seconds. */
export function formatDate(seconds: number): string {
  const parts: Record<string, string> = {};
  for (const part of dateFormat.formatToParts(new Date(seconds * 1000))) parts[part.type] = part.value;
  return `${parts.weekday} ${parts.day} ${parts.month}`;
}

import {
  createPublicClient,
  decodeEventLog,
  formatUnits,
  getAbiItem,
  hexToBigInt,
  hexToNumber,
  http,
  parseAbi,
  parseEventLogs,
  toEventSelector,
  type Address,
  type Hex,
} from "viem";
import { deployment } from "../generated/deployment";
import { addressBook, demoLoan } from "./addresses";
import { mezoMainnetChain, mezoTestnetChain } from "./chains";

const mainnetClient = createPublicClient({ chain: mezoMainnetChain, transport: http() });
const testnetClient = createPublicClient({ chain: mezoTestnetChain, transport: http() });

const veBtcAbi = parseAbi(["function supply() view returns (uint256)"]);
const priceFeedAbi = parseAbi(["function fetchPrice() view returns (uint256)"]);
const creditMarketsAbi = parseAbi([
  "function nextOfferId() view returns (uint256)",
  "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining))",
]);

const loanManagerAbi = parseAbi([
  "function loanOf(uint256 tokenId) view returns ((uint64 maturity, uint128 face, uint128 repaid, uint16 maxLtvBps, uint16 liqLtvBps, uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration, uint8 state))",
  "function lockOf(uint256 tokenId) view returns (uint256 amount, uint256 end, bool isPermanent)",
  "event Borrowed(uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face)",
]);
const veBtcVotedAbi = parseAbi(["function voted(uint256 tokenId) view returns (bool)"]);
const feeDistributorAbi = parseAbi(["function claimable(uint256 tokenId) view returns (uint256 amount)"]);

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

export type OpenOffer = { id: bigint; maturity: number; aprBps: number; remaining: bigint };

// The hero and the Thursday board both read the offers every 15 seconds, so one scan serves both inside two seconds.
let recentScan: { at: number; scan: Promise<OpenOffer[]> } | null = null;

/** Offers with MUSD left and a maturity in the future, from the newest OFFER_WINDOW ids. */
export function scanOpenOffers(): Promise<OpenOffer[]> {
  if (recentScan !== null && Date.now() - recentScan.at < 2_000) return recentScan.scan;
  const scan = readOpenOffers();
  recentScan = { at: Date.now(), scan };
  scan.catch(() => {
    recentScan = null;
  });
  return scan;
}

async function readOpenOffers(): Promise<OpenOffer[]> {
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
  return offers
    .map((offer, index) => ({ id: ids[index] as bigint, offer }))
    .filter(({ offer }) => offer.remaining > 0n && offer.maturity > now)
    .map(({ id, offer }) => ({ id, maturity: Number(offer.maturity), aprBps: offer.aprBps, remaining: offer.remaining }));
}

export async function readOffers(): Promise<OfferStats> {
  const open = await scanOpenOffers();
  const musdOnOffer = open.reduce((sum, offer) => sum + offer.remaining, 0n);

  let best: OfferStats["best"] = null;
  for (const offer of open) {
    if (best === null || offer.maturity < best.maturity || (offer.maturity === best.maturity && offer.aprBps < best.aprBps)) {
      best = { maturity: offer.maturity, aprBps: offer.aprBps };
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

// LoanState.Active in LoanManager.
const LOAN_STATE_ACTIVE = 1;

// Some nodes behind the public RPC answer null for a receipt that others already have.
const RECEIPT_ATTEMPTS = 8;
const RECEIPT_RETRY_MS = 1_500;
const EXPLORER_LOGS_URL = "https://api.explorer.test.mezo.org/api/v2/transactions";

export type DemoLoanState = {
  /** False once the loan has been repaid, sold or otherwise closed. */
  active: boolean;
  lockEnd: number;
  isPermanent: boolean;
  voted: boolean;
  claimableBtc: number;
  face: number;
  maturity: number;
};

export type DemoLoan = DemoLoanState & { principal: number };

export async function readDemoLoanState(): Promise<DemoLoanState> {
  const { loanManager, veBTC, feeDistributor } = addressBook[31611];
  const tokenId = demoLoan.tokenId;
  const [loan, lock, voted, claimable] = await Promise.all([
    testnetClient.readContract({ address: loanManager, abi: loanManagerAbi, functionName: "loanOf", args: [tokenId] }),
    testnetClient.readContract({ address: loanManager, abi: loanManagerAbi, functionName: "lockOf", args: [tokenId] }),
    testnetClient.readContract({ address: veBTC, abi: veBtcVotedAbi, functionName: "voted", args: [tokenId] }),
    testnetClient.readContract({
      address: feeDistributor,
      abi: feeDistributorAbi,
      functionName: "claimable",
      args: [tokenId],
    }),
  ]);

  return {
    active: loan.state === LOAN_STATE_ACTIVE,
    lockEnd: Number(lock[1]),
    isPermanent: lock[2],
    voted,
    claimableBtc: Number(formatUnits(claimable, 18)),
    face: Number(formatUnits(loan.face, 18)),
    maturity: Number(loan.maturity),
  };
}

async function readPrincipalFromReceipt(): Promise<bigint | null> {
  for (let attempt = 0; attempt < RECEIPT_ATTEMPTS; attempt++) {
    try {
      const receipt = await testnetClient.getTransactionReceipt({ hash: demoLoan.hash });
      const [borrowed] = parseEventLogs({
        abi: loanManagerAbi,
        eventName: "Borrowed",
        logs: receipt.logs,
      }).filter((log) => log.args.tokenId === demoLoan.tokenId);
      return borrowed ? borrowed.args.principal : null;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, RECEIPT_RETRY_MS));
    }
  }
  return null;
}

type ExplorerLog = { address: { hash: string }; data: string; topics: (string | null)[] };

export async function readPrincipalFromExplorer(): Promise<bigint> {
  const response = await fetch(`${EXPLORER_LOGS_URL}/${demoLoan.hash}/logs`);
  if (!response.ok) throw new Error(`explorer answered ${response.status}`);
  const body = (await response.json()) as { items: ExplorerLog[] };

  for (const item of body.items) {
    const topics = item.topics.filter((topic): topic is string => topic !== null);
    if (topics.length === 0) continue;
    try {
      const decoded = decodeEventLog({
        abi: loanManagerAbi,
        data: item.data as `0x${string}`,
        topics: topics as [`0x${string}`, ...`0x${string}`[]],
      });
      if (decoded.eventName === "Borrowed" && decoded.args.tokenId === demoLoan.tokenId) return decoded.args.principal;
    } catch {
      continue;
    }
  }
  throw new Error("the borrow transaction has no Borrowed log for this loan");
}

// The principal never changes after the borrow, so it is read once per page load.
let principalOnce: Promise<number> | null = null;

export function readDemoLoanPrincipal(): Promise<number> {
  if (principalOnce === null) {
    principalOnce = (async () => {
      const fromReceipt = await readPrincipalFromReceipt();
      const principal = fromReceipt ?? (await readPrincipalFromExplorer());
      return Number(formatUnits(principal, 18));
    })();
    principalOnce.catch(() => {
      principalOnce = null;
    });
  }
  return principalOnce;
}

export async function readDemoLoan(): Promise<DemoLoan> {
  const [state, principal] = await Promise.all([readDemoLoanState(), readDemoLoanPrincipal()]);
  return { ...state, principal };
}

const riskAbi = parseAbi([
  "function maxLtvBps() view returns (uint16)",
  "function liqLtvBps() view returns (uint16)",
  "function penaltyBps() view returns (uint16)",
  "function auctionFloorBps() view returns (uint16)",
  "function auctionDuration() view returns (uint32)",
]);
const maxTermAbi = parseAbi(["function maxTermSeconds() view returns (uint32)"]);
const marketAbi = parseAbi([
  "function marketOf(uint64 maturity) view returns ((uint128 faceTotal, uint128 collectedMusd, uint64 openLoans, bool isFinal, uint128 unitsAtFinal, uint128 musdAtFinal, uint128 collectedBtc, uint128 btcAtFinal))",
]);
const auctionAbi = parseAbi([
  "function loanOf(uint256 tokenId) view returns ((uint64 maturity, uint128 face, uint128 repaid, uint16 maxLtvBps, uint16 liqLtvBps, uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration, uint8 state))",
  "function auctionOf(uint256 tokenId) view returns ((uint64 startTime, uint32 duration, uint16 penaltyBps, uint128 startValue, uint128 floorPrice))",
  "function auctionPrice(uint256 tokenId) view returns (uint256 price)",
]);

export type RiskSettings = {
  maxLtvBps: number;
  liqLtvBps: number;
  penaltyBps: number;
  auctionFloorBps: number;
  /** Seconds. */
  auctionDuration: number;
  /** Seconds: how far from now a loan date may be. */
  maxTermSeconds: number;
};

export async function readRiskSettings(): Promise<RiskSettings> {
  const { loanManager, creditMarkets } = addressBook[31611];
  const [maxLtvBps, liqLtvBps, penaltyBps, auctionFloorBps, auctionDuration, maxTermSeconds] =
    await testnetClient.multicall({
      allowFailure: false,
      contracts: [
        { address: loanManager, abi: riskAbi, functionName: "maxLtvBps" },
        { address: loanManager, abi: riskAbi, functionName: "liqLtvBps" },
        { address: loanManager, abi: riskAbi, functionName: "penaltyBps" },
        { address: loanManager, abi: riskAbi, functionName: "auctionFloorBps" },
        { address: loanManager, abi: riskAbi, functionName: "auctionDuration" },
        { address: creditMarkets, abi: maxTermAbi, functionName: "maxTermSeconds" },
      ],
    });
  return { maxLtvBps, liqLtvBps, penaltyBps, auctionFloorBps, auctionDuration, maxTermSeconds };
}

export type ThursdayCard = {
  /** Unix seconds of Thursday 00:00 UTC. */
  maturity: number;
  musdOnOffer: number;
  offerCount: number;
  /** The lowest rate among open offers for this date, or null when none is open. */
  bestAprBps: number | null;
  /** MUSD lent for this date so far. */
  lent: number;
  openLoans: number;
};

const WEEK_SECONDS = 604_800;

/** The next four Thursdays after `now`, never beyond now plus the maximum term, each with its live offers and market. */
export async function readThursdayBoard(now: number): Promise<ThursdayCard[]> {
  const { creditMarkets } = addressBook[31611];
  const [maxTerm, open] = await Promise.all([
    testnetClient.readContract({ address: creditMarkets, abi: maxTermAbi, functionName: "maxTermSeconds" }),
    scanOpenOffers(),
  ]);

  const dates: number[] = [];
  const first = (Math.floor(now / WEEK_SECONDS) + 1) * WEEK_SECONDS;
  for (let date = first; dates.length < 4 && date <= now + maxTerm; date += WEEK_SECONDS) dates.push(date);
  if (dates.length === 0) return [];

  const markets = await testnetClient.multicall({
    allowFailure: false,
    contracts: dates.map((date) => ({
      address: creditMarkets,
      abi: marketAbi,
      functionName: "marketOf" as const,
      args: [BigInt(date)] as const,
    })),
  });

  return dates.map((date, index) => {
    const offers = open.filter((offer) => offer.maturity === date);
    const market = markets[index];
    return {
      maturity: date,
      musdOnOffer: Number(formatUnits(offers.reduce((sum, offer) => sum + offer.remaining, 0n), 18)),
      offerCount: offers.length,
      bestAprBps: offers.length === 0 ? null : Math.min(...offers.map((offer) => offer.aprBps)),
      lent: market ? Number(formatUnits(market.faceTotal, 18)) : 0,
      openLoans: market ? Number(market.openLoans) : 0,
    };
  });
}

export type OpenAuction = {
  tokenId: bigint;
  /** Unix seconds. */
  startTime: number;
  /** Seconds the price takes to fall from the start value to the floor. */
  duration: number;
  startValue: number;
  floorPrice: number;
  /** MUSD a buyer pays now. */
  price: number;
};

const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const EXPLORER_PAGE_LOGS = 1_000;
// Each call reads up to 1,000 events, so this covers about 20,000 loan events.
const EXPLORER_MAX_CALLS = 20;
// Open loans are read in the order they fall due, and no more than this many are read per poll.
const MAX_POSITIONS = 50;
const LOAN_STATE_AUCTION = 2;

const loanEventsAbi = parseAbi([
  "event Borrowed(uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face)",
  "event LoanClosed(uint256 indexed tokenId, uint64 indexed maturity)",
]);

type LoanEventName = "Borrowed" | "LoanClosed";
type LoanLog = { event: LoanEventName; tokenId: bigint; maturity: bigint; blockNumber: bigint; logIndex: number };

async function fetchLoanLogs(event: LoanEventName): Promise<LoanLog[]> {
  const { loanManager } = addressBook[31611];
  const topic0 = toEventSelector(getAbiItem({ abi: loanEventsAbi, name: event }));
  const seen = new Set<string>();
  const logs: LoanLog[] = [];
  let start = BigInt(deployment.block);

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", loanManager);
    url.searchParams.set("topic0", topic0);
    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as Record<string, unknown>[]) : [];

    for (const raw of page) {
      const topics = (Array.isArray(raw.topics) ? raw.topics : []).filter(
        (topic): topic is Hex => typeof topic === "string",
      );
      if (topics.length === 0 || typeof raw.data !== "string") continue;
      try {
        const decoded = decodeEventLog({
          abi: loanEventsAbi,
          data: raw.data as Hex,
          topics: topics as [Hex, ...Hex[]],
          strict: false,
        });
        if (decoded.eventName !== event) continue;
        const blockNumber = hexToBigInt(raw.blockNumber as Hex);
        const logIndex = hexToNumber(raw.logIndex as Hex);
        if (blockNumber > start) start = blockNumber;
        const key = `${String(raw.transactionHash)}:${logIndex}`;
        if (seen.has(key)) continue;
        seen.add(key);
        const args = decoded.args as { tokenId: bigint; maturity: bigint };
        logs.push({ event, tokenId: args.tokenId, maturity: args.maturity, blockNumber, logIndex });
      } catch {
        continue;
      }
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
  }
  return logs;
}

const logIsLater = (a: LoanLog, b: LoanLog) =>
  a.blockNumber > b.blockNumber || (a.blockNumber === b.blockNumber && a.logIndex > b.logIndex);

/** A position is open when its latest Borrowed comes after its latest LoanClosed, as the keeper reads it. */
function openLoans(logs: LoanLog[]): LoanLog[] {
  const lastBorrowed = new Map<bigint, LoanLog>();
  const lastClosed = new Map<bigint, LoanLog>();
  for (const log of logs) {
    const latest = log.event === "Borrowed" ? lastBorrowed : lastClosed;
    const seen = latest.get(log.tokenId);
    if (seen === undefined || logIsLater(log, seen)) latest.set(log.tokenId, log);
  }
  return [...lastBorrowed.values()].filter((borrowed) => {
    const closed = lastClosed.get(borrowed.tokenId);
    return closed === undefined || logIsLater(borrowed, closed);
  });
}

/** Every loan in auction right now. The explorer names the open loans; LoanManager says which are in auction. */
export async function readOpenAuctions(): Promise<OpenAuction[]> {
  const { loanManager } = addressBook[31611];
  const [borrowed, closed] = await Promise.all([fetchLoanLogs("Borrowed"), fetchLoanLogs("LoanClosed")]);
  const tokenIds = openLoans([...borrowed, ...closed])
    .sort((a, b) => (a.maturity < b.maturity ? -1 : a.maturity > b.maturity ? 1 : a.tokenId < b.tokenId ? -1 : 1))
    .slice(0, MAX_POSITIONS)
    .map((log) => log.tokenId);
  if (tokenIds.length === 0) return [];

  const loans = await testnetClient.multicall({
    allowFailure: false,
    batchSize: 16_384,
    contracts: tokenIds.map((tokenId) => ({
      address: loanManager,
      abi: auctionAbi,
      functionName: "loanOf" as const,
      args: [tokenId] as const,
    })),
  });
  const inAuction = tokenIds.filter((_, index) => loans[index]?.state === LOAN_STATE_AUCTION);
  if (inAuction.length === 0) return [];

  const reads = await testnetClient.multicall({
    allowFailure: false,
    contracts: inAuction.flatMap((tokenId) => [
      { address: loanManager, abi: auctionAbi, functionName: "auctionOf" as const, args: [tokenId] as const },
      { address: loanManager, abi: auctionAbi, functionName: "auctionPrice" as const, args: [tokenId] as const },
    ]),
  });

  return inAuction.map((tokenId, index) => {
    const auction = reads[index * 2] as { startTime: bigint; duration: number; startValue: bigint; floorPrice: bigint };
    const price = reads[index * 2 + 1] as bigint;
    return {
      tokenId,
      startTime: Number(auction.startTime),
      duration: auction.duration,
      startValue: Number(formatUnits(auction.startValue, 18)),
      floorPrice: Number(formatUnits(auction.floorPrice, 18)),
      price: Number(formatUnits(price, 18)),
    };
  });
}

const EXPLORER_V2 = "https://api.explorer.test.mezo.org/api/v2";

/** True when the explorer has the contract's source verified. */
export async function readVerified(address: Address): Promise<boolean> {
  const response = await fetch(`${EXPLORER_V2}/smart-contracts/${address}`);
  if (!response.ok) throw new Error(`explorer answered ${response.status}`);
  const body = (await response.json()) as { is_verified?: unknown };
  if (typeof body.is_verified !== "boolean") throw new Error("explorer gave no verification flag");
  return body.is_verified;
}

export const formatPercentBps = (bps: number): string => `${+(bps / 100).toFixed(2)}%`;
export const formatHours = (seconds: number): string => `${+(seconds / 3600).toFixed(2)}h`;

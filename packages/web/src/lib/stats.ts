import { createPublicClient, decodeEventLog, formatUnits, http, parseAbi, parseEventLogs } from "viem";
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

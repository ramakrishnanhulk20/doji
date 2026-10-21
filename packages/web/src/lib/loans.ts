import {
  decodeEventLog,
  formatUnits,
  hexToBigInt,
  hexToNumber,
  pad,
  parseAbi,
  parseAbiItem,
  toEventSelector,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { erc20Abi, feeDistributorAbi, veBtcAbi } from "../abi/external";
import { loanManagerAbi } from "../abi/loanManager";
import { deployment } from "../generated/deployment";
import { addressBook } from "./addresses";
import {
  BPS,
  auctionLinePrice,
  selectOffers,
  thursdaysWithin,
  weightedAprBps,
  type DateGroup,
  type Selection,
} from "./borrow";
import { quoteFaces, type BorrowSettings } from "./borrow-reads";
import { explainProblem } from "./errors";
import { formatDate, formatMusd } from "./stats";

const book = addressBook[31611];

export const EXPLORER = "https://explorer.test.mezo.org";
const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_MAX_CALLS = 20;
/** The testnet RPC refuses a log window wider than 10,000 blocks, so one block is left spare. */
const RPC_LOG_WINDOW = 9_999n;

export const STATE_NONE = 0;
export const STATE_ACTIVE = 1;
export const STATE_AUCTION = 2;

/** The share of the auction line, in basis points, above which a loan is called close to the limit. */
export const CLOSE_TO_LINE_BPS = 8_000;
/** The bar turns from safe to watch at this share of the line, as on the Borrow summary. */
export const SAFE_SHARE_BPS = 7_500;
/** A buyer's cap is the price now plus this share, in basis points. */
const BUY_SLACK_BPS = 100n;
const BUY_DEADLINE_SECONDS = 600;

// Small read-only slices, so the compiler does not carry the full contract ABI through every read.
const loanReads = parseAbi([
  "function positionOf(uint256 tokenId) view returns ((address borrower))",
  "function loanOf(uint256 tokenId) view returns ((uint64 maturity, uint128 face, uint128 repaid, uint16 maxLtvBps, uint16 liqLtvBps, uint16 penaltyBps, uint16 auctionFloorBps, uint32 auctionDuration, uint8 state))",
  "function owedOf(uint256 tokenId) view returns (uint256)",
  "function collateralValue(uint256 tokenId) view returns (uint256 btcAmount, uint256 usdValue)",
  "function lockOf(uint256 tokenId) view returns (uint256 amount, uint256 end, bool isPermanent)",
  "function isUnsafe(uint256 tokenId) view returns (bool)",
  "function isOverdue(uint256 tokenId) view returns (bool)",
  "function auctionOf(uint256 tokenId) view returns ((uint64 startTime, uint32 duration, uint16 penaltyBps, uint128 startValue, uint128 floorPrice))",
  "function auctionPrice(uint256 tokenId) view returns (uint256)",
  "function claimableMusd(address account) view returns (uint256)",
  "function claimableBtc(address account) view returns (uint256)",
]);
const marketReads = parseAbi([
  "function marketOf(uint64 maturity) view returns ((uint128 faceTotal, uint128 collectedMusd, uint64 openLoans, bool isFinal, uint128 unitsAtFinal, uint128 musdAtFinal, uint128 collectedBtc, uint128 btcAtFinal))",
]);

const depositedEvent = parseAbiItem("event Deposited(uint256 indexed tokenId, address indexed borrower)");
const borrowedEvent = parseAbiItem(
  "event Borrowed(uint256 indexed tokenId, address indexed borrower, uint64 indexed maturity, uint256 principal, uint256 face)",
);
export const DEPOSITED_TOPIC = toEventSelector(depositedEvent);
export const BORROWED_TOPIC = toEventSelector(borrowedEvent);

const dateTimeFormat = new Intl.DateTimeFormat("en-US", {
  timeZone: "UTC",
  weekday: "short",
  day: "numeric",
  month: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** "Thu 22 Oct 14:05 UTC", from unix seconds. */
export function formatDateTime(seconds: number): string {
  const parts: Record<string, string> = {};
  for (const part of dateTimeFormat.formatToParts(new Date(seconds * 1000))) parts[part.type] = part.value;
  return `${parts.weekday} ${parts.day} ${parts.month} ${parts.hour}:${parts.minute} UTC`;
}

/** "3h 12m", "2d 4h", "42m". Zero or less reads "now". */
export function formatCountdown(seconds: number): string {
  if (seconds <= 0) return "now";
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return minutes > 0 ? `${minutes}m` : "under 1m";
}

export const shortAddress = (address: string): string => `${address.slice(0, 6)}...${address.slice(-4)}`;

export const toMusdNumber = (wei: bigint): number => Number(formatUnits(wei, 18));

/** MUSD with two decimals, from wei. */
export const musdText = (wei: bigint): string => formatMusd(toMusdNumber(wei));

/** BTC with at least four decimals and as many more as the amount needs, down to eight. Real but tiny reads "<0.00000001". */
export function btcText(wei: bigint): string {
  if (wei <= 0n) return "0.0000";
  const scaled = wei / 10n ** 10n;
  if (scaled === 0n) return "<0.00000001";
  const padded = scaled.toString().padStart(9, "0");
  const whole = padded.slice(0, -8);
  const fraction = padded.slice(-8).replace(/0+$/, "").padEnd(4, "0");
  return `${whole}.${fraction}`;
}

/** The amount with all its digits and no trailing zeros, for approval labels. */
export const exactText = (wei: bigint): string => formatUnits(wei, 18);

/** An approval's amount as people read it, rounded up so the label never shows less than what is approved. */
export function approveText(wei: bigint): string {
  const decimals = wei < 10n ** 16n ? 6 : 2;
  const step = 10n ** BigInt(18 - decimals);
  const rounded = ((wei + step - 1n) / step) * step;
  return Number(formatUnits(rounded, 18)).toLocaleString("en-US", { maximumFractionDigits: decimals });
}

export type Entry = { status: "success"; result: unknown } | { status: "failure"; error: Error };

/** A multicall answer, or null when that one call reverted. */
export function answer<T>(entry: Entry | undefined): T | null {
  return entry !== undefined && entry.status === "success" ? (entry.result as T) : null;
}

export type Loan = {
  maturity: number;
  face: bigint;
  repaid: bigint;
  maxLtvBps: number;
  liqLtvBps: number;
  penaltyBps: number;
  auctionFloorBps: number;
  auctionDuration: number;
  state: number;
};

export type Auction = {
  startTime: number;
  duration: number;
  penaltyBps: number;
  startValue: bigint;
  floorPrice: bigint;
};

export type Lock = { amount: bigint; end: number; isPermanent: boolean };

/** Everything Doji and Mezo say about one veBTC position. A field is null when its read reverted. */
export type PositionView = {
  id: bigint;
  /** Null when no one has deposited this position. */
  borrower: Address | null;
  loan: Loan;
  owed: bigint;
  /** Collateral value in MUSD. Null while Mezo's price feed is stale. */
  value: bigint | null;
  lock: Lock | null;
  unsafe: boolean | null;
  overdue: boolean;
  auction: Auction | null;
  /** What a buyer pays now. Only read for a loan in auction. */
  auctionPrice: bigint | null;
  voted: boolean | null;
  /** BTC the fee distributor holds for this position. */
  rewards: bigint | null;
};

const ZERO = "0x0000000000000000000000000000000000000000";
const CALLS_PER_POSITION = 10;

/** Reads the loan, the lock, the votes and the rewards of each position in two multicalls. */
export async function readPositionViews(client: PublicClient, ids: readonly bigint[]): Promise<PositionView[]> {
  if (ids.length === 0) return [];

  const calls = ids.flatMap((id) => [
    { address: book.loanManager, abi: loanReads, functionName: "positionOf" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "loanOf" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "owedOf" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "collateralValue" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "lockOf" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "isUnsafe" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "isOverdue" as const, args: [id] as const },
    { address: book.loanManager, abi: loanReads, functionName: "auctionOf" as const, args: [id] as const },
    { address: book.veBTC, abi: veBtcAbi, functionName: "voted" as const, args: [id] as const },
    { address: book.feeDistributor, abi: feeDistributorAbi, functionName: "claimable" as const, args: [id] as const },
  ]);
  const results = (await client.multicall({
    allowFailure: true,
    batchSize: 16_384,
    contracts: calls,
  })) as unknown as Entry[];

  const stages = ids.map((id, index) => {
    const at = (slot: number) => results[index * CALLS_PER_POSITION + slot];
    const loan = answer<{
      maturity: bigint;
      face: bigint;
      repaid: bigint;
      maxLtvBps: number;
      liqLtvBps: number;
      penaltyBps: number;
      auctionFloorBps: number;
      auctionDuration: number;
      state: number;
    }>(at(1));
    if (loan === null) throw new Error(`Doji could not read the loan of veBTC #${id}`);
    const position = answer<{ borrower: Address }>(at(0));
    const collateral = answer<readonly [bigint, bigint]>(at(3));
    const lock = answer<readonly [bigint, bigint, boolean]>(at(4));
    const auction = answer<{ startTime: bigint; duration: number; penaltyBps: number; startValue: bigint; floorPrice: bigint }>(at(7));
    return { id, loan, position, collateral, lock, auction, entry: (slot: number) => at(slot) };
  });

  const inAuction = stages.filter((stage) => stage.loan.state === STATE_AUCTION).map((stage) => stage.id);
  const prices = new Map<bigint, bigint | null>();
  if (inAuction.length > 0) {
    const priceResults = (await client.multicall({
      allowFailure: true,
      contracts: inAuction.map((id) => ({
        address: book.loanManager,
        abi: loanReads,
        functionName: "auctionPrice" as const,
        args: [id] as const,
      })),
    })) as unknown as Entry[];
    inAuction.forEach((id, index) => prices.set(id, answer<bigint>(priceResults[index])));
  }

  return stages.map((stage) => {
    const { loan, position, collateral, lock, auction } = stage;
    const borrower = position !== null && position.borrower.toLowerCase() !== ZERO ? position.borrower : null;
    return {
      id: stage.id,
      borrower,
      loan: {
        maturity: Number(loan.maturity),
        face: loan.face,
        repaid: loan.repaid,
        maxLtvBps: loan.maxLtvBps,
        liqLtvBps: loan.liqLtvBps,
        penaltyBps: loan.penaltyBps,
        auctionFloorBps: loan.auctionFloorBps,
        auctionDuration: loan.auctionDuration,
        state: loan.state,
      },
      owed: answer<bigint>(stage.entry(2)) ?? loan.face - loan.repaid,
      value: collateral === null ? null : collateral[1],
      lock: lock === null ? null : { amount: lock[0], end: Number(lock[1]), isPermanent: lock[2] },
      unsafe: answer<boolean>(stage.entry(5)),
      overdue: answer<boolean>(stage.entry(6)) ?? false,
      auction:
        loan.state === STATE_AUCTION && auction !== null
          ? {
              startTime: Number(auction.startTime),
              duration: auction.duration,
              penaltyBps: auction.penaltyBps,
              startValue: auction.startValue,
              floorPrice: auction.floorPrice,
            }
          : null,
      auctionPrice: prices.get(stage.id) ?? null,
      voted: answer<boolean>(stage.entry(8)),
      rewards: answer<bigint>(stage.entry(9)),
    };
  });
}

type RawLog = {
  blockNumber: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  timeStamp: Hex;
  data: Hex;
  topics: (Hex | null)[];
};

type LogTopics = { topic0: Hex; topic1?: Hex; topic2?: Hex };

/** LoanManager logs from the explorer, filtered by topic, from the deployment block on. */
async function fetchExplorerLogs({ topic0, topic1, topic2 }: LogTopics): Promise<RawLog[]> {
  const seen = new Set<string>();
  const logs: RawLog[] = [];
  let start = BigInt(deployment.block);

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", book.loanManager);
    url.searchParams.set("topic0", topic0);
    if (topic1) {
      url.searchParams.set("topic1", topic1);
      url.searchParams.set("topic0_1_opr", "and");
    }
    if (topic2) {
      url.searchParams.set("topic2", topic2);
      url.searchParams.set("topic0_2_opr", "and");
    }
    if (topic1 && topic2) url.searchParams.set("topic1_2_opr", "and");

    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as RawLog[]) : [];

    for (const raw of page) {
      const key = `${raw.transactionHash}:${raw.logIndex}`;
      const block = hexToBigInt(raw.blockNumber);
      if (block > start) start = block;
      if (seen.has(key)) continue;
      seen.add(key);
      logs.push(raw);
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
  }
  return logs;
}

const wordOf = (value: bigint | Address): Hex => pad(typeof value === "bigint" ? (`0x${value.toString(16)}` as Hex) : value, { size: 32 });

/**
 * The position ids a wallet has put into Doji: the explorer's Deposited logs plus one RPC request over the newest
 * blocks (the explorer can lag a little). Each id is then checked live, and only those whose borrower is the wallet
 * today are kept, newest id first.
 */
export async function readWalletPositionIds(client: PublicClient, owner: Address): Promise<bigint[]> {
  const latest = await client.getBlockNumber();
  const [indexed, recent] = await Promise.all([
    fetchExplorerLogs({ topic0: DEPOSITED_TOPIC, topic2: wordOf(owner) }),
    client.getLogs({
      address: book.loanManager,
      event: depositedEvent,
      args: { borrower: owner },
      fromBlock: latest > RPC_LOG_WINDOW ? latest - RPC_LOG_WINDOW : 0n,
      toBlock: latest,
    }),
  ]);

  const ids = new Set<bigint>();
  for (const log of indexed) {
    const topic = log.topics[1];
    if (topic) ids.add(hexToBigInt(topic));
  }
  for (const log of recent) {
    if (log.args.tokenId !== undefined) ids.add(log.args.tokenId);
  }
  if (ids.size === 0) return [];

  const list = [...ids];
  const positions = await client.multicall({
    allowFailure: false,
    contracts: list.map((id) => ({
      address: book.loanManager,
      abi: loanReads,
      functionName: "positionOf" as const,
      args: [id] as const,
    })),
  });
  return list
    .filter((_, index) => positions[index]?.borrower.toLowerCase() === owner.toLowerCase())
    .sort((a, b) => (a > b ? -1 : a < b ? 1 : 0));
}

export type Claimables = { musd: bigint; btc: bigint };

export async function readClaimables(client: PublicClient, owner: Address): Promise<Claimables> {
  const [musd, btc] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.loanManager, abi: loanReads, functionName: "claimableMusd", args: [owner] },
      { address: book.loanManager, abi: loanReads, functionName: "claimableBtc", args: [owner] },
    ],
  });
  return { musd, btc };
}

export type MusdWallet = { balance: bigint; allowance: bigint };

/** The wallet's MUSD and how much of it Doji may already pull. */
export async function readMusdWallet(client: PublicClient, owner: Address): Promise<MusdWallet> {
  const [balance, allowance] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.musd, abi: erc20Abi, functionName: "balanceOf", args: [owner] },
      { address: book.musd, abi: erc20Abi, functionName: "allowance", args: [owner, book.loanManager] },
    ],
  });
  return { balance, allowance };
}

export type OpenedRecord = { principal: bigint; hash: Hex; timestamp: number };

/** The latest Borrowed log of a position, from the explorer. Null when the position never had a loan. */
export async function readOpened(id: bigint): Promise<OpenedRecord | null> {
  const logs = await fetchExplorerLogs({ topic0: BORROWED_TOPIC, topic1: wordOf(id) });
  let latest: { log: RawLog; block: bigint; index: number } | null = null;
  for (const log of logs) {
    const block = hexToBigInt(log.blockNumber);
    const index = hexToNumber(log.logIndex);
    if (latest === null || block > latest.block || (block === latest.block && index > latest.index)) {
      latest = { log, block, index };
    }
  }
  if (latest === null) return null;

  const topics = latest.log.topics.filter((topic): topic is Hex => topic !== null);
  const decoded = decodeEventLog({
    abi: [borrowedEvent],
    data: latest.log.data,
    topics: topics as [Hex, ...Hex[]],
  });
  return { principal: decoded.args.principal, hash: latest.log.transactionHash, timestamp: hexToNumber(latest.log.timeStamp) };
}

export type MarketView = { lent: bigint; openLoans: number };

/** What the loan's Thursday has lent so far and how many of its loans are still open. */
export async function readMarket(client: PublicClient, maturity: number): Promise<MarketView> {
  const market = await client.readContract({
    address: book.creditMarkets,
    abi: marketReads,
    functionName: "marketOf",
    args: [BigInt(maturity)],
  });
  return { lent: market.faceTotal, openLoans: Number(market.openLoans) };
}

/** "unknown" is an Active loan whose safety cannot be told because Mezo's price feed is not answering. */
export type Standing = "none" | "safe" | "close" | "overdue" | "auction" | "unknown";

/** The share of the auction line the debt has used, in basis points of the line. Null while the value is unknown. */
export function lineUsedBps(view: PositionView): number | null {
  if (view.value === null || view.value === 0n || view.loan.liqLtvBps === 0) return null;
  return Number((view.owed * BPS * BPS) / (view.value * BigInt(view.loan.liqLtvBps)));
}

export function standingOf(view: PositionView): Standing {
  if (view.loan.state === STATE_AUCTION) return "auction";
  if (view.loan.state !== STATE_ACTIVE) return "none";
  if (view.overdue) return "overdue";
  const used = lineUsedBps(view);
  if (view.unsafe === true || (used !== null && used > CLOSE_TO_LINE_BPS)) return "close";
  if (view.unsafe === null && used === null) return "unknown";
  return "safe";
}

/** The MUSD price of one BTC at which the loan reaches its auction line. Null while the value is unknown. */
export function auctionLineFor(view: PositionView): bigint | null {
  if (view.lock === null || view.lock.amount === 0n) return null;
  const price = auctionLinePrice(view.owed, view.loan.liqLtvBps, view.lock.amount);
  return price === 0n ? null : price;
}

/** What the loan page says under its title. `hadLoan` is true when a Borrowed log exists for the position. */
export function describeLoan(view: PositionView, now: number, hadLoan: boolean): string {
  if (view.loan.state === STATE_AUCTION) {
    if (view.auction === null) return "In auction.";
    const floorTime = view.auction.startTime + view.auction.duration;
    return `In auction since ${formatDateTime(view.auction.startTime)}; the price ${
      now >= floorTime ? "fell to" : "falls to"
    } its floor at ${formatDateTime(floorTime)}.`;
  }
  if (view.loan.state === STATE_ACTIVE) {
    if (view.overdue) return "Past its date and waiting for its auction to start.";
    if (view.unsafe === true) return "Past its auction line and waiting for its auction to start.";
    if (view.unsafe === null) {
      return `Active, due ${formatDate(view.loan.maturity)}. Mezo's price feed is not answering, so its safety cannot be checked right now.`;
    }
    return `Active and safe, due ${formatDate(view.loan.maturity)}.`;
  }
  return hadLoan ? "Closed." : "No loan on this position.";
}

export type AnyoneActionId = "startAuction" | "cancelAuction" | "prepareSettle" | "settle";

export type AnyoneAction = { id: AnyoneActionId; label: string; why: string };

/** The steps anyone may run on this loan right now, using the same conditions the contract checks. */
export function anyoneActions(view: PositionView, now: number): AnyoneAction[] {
  const actions: AnyoneAction[] = [];
  const { loan, auction, lock } = view;

  if (loan.state === STATE_ACTIVE && (view.overdue || view.unsafe === true)) {
    actions.push({
      id: "startAuction",
      label: "Start the auction",
      why: `This loan is ${view.overdue ? "overdue" : "unsafe"}. Anyone can start its auction.`,
    });
  }

  if (loan.state === STATE_AUCTION && auction !== null) {
    // An LTV auction starts at or before the due date; one started after it is for an overdue loan and stays.
    if (auction.startTime <= loan.maturity && view.unsafe === false) {
      actions.push({
        id: "cancelAuction",
        label: "Cancel the auction",
        why: "Bitcoin recovered and this loan is safe again. Anyone can cancel its auction.",
      });
    }

    const floorReached = now >= auction.startTime + auction.duration;
    const stillDeserves = view.overdue || view.unsafe === true;
    if (floorReached && stillDeserves && lock !== null) {
      if (view.voted === true || lock.isPermanent) {
        actions.push({
          id: "prepareSettle",
          label: "Prepare to settle",
          why: "Nobody bought it, and the position still has votes or a permanent lock. Preparing clears them so it can be settled.",
        });
      } else if (view.voted === false && lock.end <= now) {
        actions.push({
          id: "settle",
          label: "Settle",
          why: "Nobody bought it, so the lenders take the Bitcoin itself.",
        });
      }
    }
  }
  return actions;
}

export type SaleSplit = { toMarket: bigint; toTreasury: bigint; toBorrower: bigint };

/** Lenders get min(price, owed), the protocol its penalty out of what is left, the borrower the rest. */
export function splitSale(price: bigint, owed: bigint, penaltyBps: number): SaleSplit {
  const toMarket = price < owed ? price : owed;
  const penalty = (owed * BigInt(penaltyBps)) / BPS;
  const left = price - toMarket;
  const toTreasury = penalty < left ? penalty : left;
  return { toMarket, toTreasury, toBorrower: left - toTreasury };
}

/** A buyer never pays more than the price now plus 1%. */
export const maxPayFor = (price: bigint): bigint => price + (price * BUY_SLACK_BPS) / BPS;

export const buyDeadline = (now: number): bigint => BigInt(now + BUY_DEADLINE_SECONDS);

/** The Thursdays a loan can roll to: later than its due date, and inside the lock or the longest term. */
export function rollDates(view: PositionView, maxTermSeconds: number, now: number): number[] {
  if (view.lock === null) return [];
  const { lock } = view;
  return thursdaysWithin(now, maxTermSeconds).filter(
    (date) => date > view.loan.maturity && (lock.isPermanent || date <= lock.end),
  );
}

export type RollQuote = {
  selection: Selection;
  face: bigint;
  aprBps: number;
  /** MUSD the wallet adds because the new principal is below what is owed. */
  topUp: bigint;
  /** MUSD paid out to the wallet because the new principal is above what is owed. */
  excess: bigint;
};

export type RollInput = {
  view: PositionView;
  group: DateGroup;
  /** The new principal, 18 decimals. */
  principal: bigint;
};

/** The offers a roll would use, their quoted face, the weighted rate and the difference with what is owed. */
export async function quoteRoll(client: PublicClient, { view, group, principal }: RollInput): Promise<RollQuote> {
  const selection = selectOffers(principal, group.offers);
  const faces = await quoteFaces(client, group.maturity, selection);
  const face = faces.reduce((sum, value) => sum + value, 0n);
  return {
    selection,
    face,
    aprBps: weightedAprBps(selection.amounts, selection.aprs),
    topUp: view.owed > selection.filled ? view.owed - selection.filled : 0n,
    excess: selection.filled > view.owed ? selection.filled - view.owed : 0n,
  };
}

export const ROLL_PAUSED_LINE = "While new loans are paused, a roll can't pay out extra MUSD.";

/** Why the Roll button cannot be pressed yet, in plain words, or null when every check passes. */
export function rollProblem(input: {
  view: PositionView;
  settings: BorrowSettings;
  group: DateGroup | undefined;
  principal: bigint;
  quote: RollQuote | undefined;
  musdBalance: bigint | undefined;
}): string | null {
  const { view, settings, group, principal, quote, musdBalance } = input;
  if (!group) return "Pick a later date";
  if (principal === 0n) return "Enter an amount";
  if (principal < settings.minLoan) return explainProblem({ kind: "belowMin", minLoan: settings.minLoan });

  const selection = quote?.selection ?? selectOffers(principal, group.offers);
  if (selection.filled < principal) {
    return selection.offerIds.length >= 8
      ? explainProblem({ kind: "tooManyOffers" })
      : explainProblem({ kind: "overOffers", most: group.available });
  }
  if (principal > view.owed && settings.borrowsPaused) return ROLL_PAUSED_LINE;
  if (!quote) return "Checking the numbers";

  if (view.value !== null) {
    const maxFace = (view.value * BigInt(settings.maxLtvBps)) / BPS;
    if (quote.face > maxFace) return explainProblem({ kind: "overLimit", maxFace });
  }
  if (musdBalance !== undefined && quote.topUp > musdBalance) {
    return `You don't have that much MUSD. Your balance is ${musdText(musdBalance)} MUSD.`;
  }
  return null;
}

export type StepSpec = { id: string; label: string };

/** Repaying needs an approval for the exact amount first, unless the allowance already covers it. */
export function repaySteps(pay: bigint, allowance: bigint): StepSpec[] {
  const steps: StepSpec[] = [];
  if (allowance < pay) steps.push({ id: "approve", label: `Approve ${approveText(pay)} MUSD` });
  steps.push({ id: "repay", label: "Repay" });
  return steps;
}

/** A roll to a date past the lock end starts by extending the lock to that date. */
export function rollSteps(topUp: bigint, allowance: bigint, extendTo: number | null = null): StepSpec[] {
  const steps: StepSpec[] = [];
  if (extendTo !== null) steps.push({ id: "extend", label: `Extend lock to ${formatDate(extendTo)}` });
  if (topUp > 0n && allowance < topUp) steps.push({ id: "approve", label: `Approve ${approveText(topUp)} MUSD` });
  steps.push({ id: "roll", label: "Roll" });
  return steps;
}

export function buySteps(maxPay: bigint, allowance: bigint): StepSpec[] {
  const steps: StepSpec[] = [];
  if (allowance < maxPay) steps.push({ id: "approve", label: `Approve ${approveText(maxPay)} MUSD` });
  steps.push({ id: "buy", label: "Buy" });
  return steps;
}

/** One contract call, named by the address book entry it goes to. The write hook resolves the address. */
export type LoanCall = {
  target: "loanManager" | "musd";
  address: Address;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

export const managerCall = (functionName: string, args: readonly unknown[]): LoanCall => ({
  target: "loanManager",
  address: book.loanManager,
  abi: loanManagerAbi as Abi,
  functionName,
  args,
});

/** MUSD is approved for the exact amount the next step will pull, never more. */
export const approveMusdCall = (amount: bigint): LoanCall => ({
  target: "musd",
  address: book.musd,
  abi: erc20Abi as Abi,
  functionName: "approve",
  args: [book.loanManager, amount],
});

export const repayCall = (id: bigint, amount: bigint): LoanCall => managerCall("repay", [id, amount]);

export const rollCall = (id: bigint, newMaturity: number, selection: Selection, maxTopUp: bigint): LoanCall =>
  managerCall("roll", [id, BigInt(newMaturity), selection.offerIds, selection.amounts, selection.maxAprBps, maxTopUp]);

export const withdrawCall = (id: bigint): LoanCall => managerCall("withdrawCollateral", [id]);

export const claimCall = (): LoanCall => managerCall("claim", []);

export const purchaseCall = (id: bigint, maxPay: bigint, deadline: bigint): LoanCall =>
  managerCall("purchase", [id, maxPay, deadline]);

export const startAuctionCall = (id: bigint): LoanCall => managerCall("startAuction", [id]);

export const cancelAuctionCall = (id: bigint): LoanCall => managerCall("cancelAuction", [id]);

export const prepareSettleCall = (id: bigint): LoanCall => managerCall("prepareSettle", [id]);

export const settleCall = (id: bigint): LoanCall => managerCall("settle", [id]);

export const anyoneCallFor = (id: AnyoneActionId, tokenId: bigint): LoanCall => {
  switch (id) {
    case "startAuction":
      return startAuctionCall(tokenId);
    case "cancelAuction":
      return cancelAuctionCall(tokenId);
    case "prepareSettle":
      return prepareSettleCall(tokenId);
    case "settle":
      return settleCall(tokenId);
  }
};

export const anyoneSuccessLine = (id: AnyoneActionId, tokenId: bigint): string => {
  switch (id) {
    case "startAuction":
      return `The auction for veBTC #${tokenId} has started.`;
    case "cancelAuction":
      return `The auction for veBTC #${tokenId} is cancelled.`;
    case "prepareSettle":
      return `veBTC #${tokenId} is ready to settle.`;
    case "settle":
      return `veBTC #${tokenId} is settled. The lenders took the Bitcoin.`;
  }
};

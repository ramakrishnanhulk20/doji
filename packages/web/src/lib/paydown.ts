import {
  decodeEventLog,
  hexToBigInt,
  hexToNumber,
  pad,
  parseAbi,
  parseAbiItem,
  toEventSelector,
  toHex,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
} from "viem";
import { loanManagerAbi } from "../abi/loanManager";
import { payDownAbi } from "../abi/payDown";
import { addressBook, wave2Pair } from "./addresses";
import { explainError, findRevert } from "./errors";
import { buildClaimRewardsArgs, readVoterAddresses, readVotes, type ClaimPlan } from "./votes";

const book = addressBook[31611];

const EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const EXPLORER_PAGE_LOGS = 1_000;
const EXPLORER_MAX_CALLS = 20;
/** The testnet RPC refuses a log window wider than 10,000 blocks, so one block is left spare. */
const RPC_LOG_WINDOW = 9_999n;
const WEEK = 604_800;
const ZERO: Address = "0x0000000000000000000000000000000000000000";

const harvestedEvent = parseAbiItem(
  "event Harvested(uint256 indexed tokenId, address indexed caller, uint256 musdRepaid, uint256 btcSold, uint256 musdFromBtc)",
);
const HARVESTED_TOPIC = toEventSelector(harvestedEvent);

// Wave 2 adds the reward operator to the position record, so this slice reads both words.
const positionRead = parseAbi(["function positionOf(uint256 tokenId) view returns ((address borrower, address rewardOperator))"]);

const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();
const tokenWord = (tokenId: bigint): Hex => pad(toHex(tokenId), { size: 32 });

export type Harvest = {
  hash: Hex;
  timestamp: number;
  caller: Address;
  musdRepaid: bigint;
  btcSold: bigint;
  musdFromBtc: bigint;
};

type HarvestRow = Harvest & { block: bigint; index: number };

type RawLog = {
  address: string;
  blockNumber: Hex;
  logIndex: Hex;
  transactionHash: Hex;
  timeStamp: Hex;
  data: Hex;
  topics: (Hex | null)[];
};

const logKey = (hash: string, index: number) => `${hash.toLowerCase()}:${index}`;

/**
 * Every Harvested log PayDown emitted for one position, from the explorer. The explorer is asked for PayDown's address
 * and this token, and each log it returns is checked against both again, so a wrong answer is dropped, never counted.
 */
async function fetchExplorerHarvests(tokenId: bigint): Promise<HarvestRow[]> {
  const word = tokenWord(tokenId);
  const seen = new Set<string>();
  const rows: HarvestRow[] = [];
  let start = wave2Pair.fromBlock;

  for (let call = 0; call < EXPLORER_MAX_CALLS; call++) {
    const url = new URL(EXPLORER_API);
    url.searchParams.set("module", "logs");
    url.searchParams.set("action", "getLogs");
    url.searchParams.set("fromBlock", start.toString());
    url.searchParams.set("toBlock", "latest");
    url.searchParams.set("address", book.payDown);
    url.searchParams.set("topic0", HARVESTED_TOPIC);
    url.searchParams.set("topic1", word);
    url.searchParams.set("topic0_1_opr", "and");

    const response = await fetch(url);
    if (!response.ok) throw new Error(`explorer answered ${response.status}`);
    const body = (await response.json()) as { message?: string; result?: unknown };
    if (!Array.isArray(body.result) && body.message !== "No logs found") throw new Error("explorer log listing failed");
    const page = Array.isArray(body.result) ? (body.result as RawLog[]) : [];

    for (const raw of page) {
      if (typeof raw.address !== "string" || !sameAddress(raw.address, book.payDown)) continue;
      const [topic0, topic1] = raw.topics;
      if (!topic0 || !topic1 || topic0.toLowerCase() !== HARVESTED_TOPIC.toLowerCase() || topic1.toLowerCase() !== word.toLowerCase()) continue;

      const block = hexToBigInt(raw.blockNumber);
      if (block > start) start = block;
      const index = hexToNumber(raw.logIndex);
      const key = logKey(raw.transactionHash, index);
      if (seen.has(key)) continue;
      seen.add(key);

      const topics = raw.topics.filter((topic): topic is Hex => topic !== null);
      const event = decodeEventLog({ abi: [harvestedEvent], data: raw.data, topics: topics as [Hex, ...Hex[]] });
      rows.push({
        hash: raw.transactionHash,
        timestamp: hexToNumber(raw.timeStamp),
        caller: event.args.caller,
        musdRepaid: event.args.musdRepaid,
        btcSold: event.args.btcSold,
        musdFromBtc: event.args.musdFromBtc,
        block,
        index,
      });
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
  }
  return rows;
}

/**
 * Every harvest PayDown ran for this position, newest first. The explorer gives the whole history from the Wave 2
 * deploy block; one node request over the newest blocks adds what the explorer has not indexed yet. A harvest that
 * both return is kept once.
 */
export async function readHarvests(client: PublicClient, tokenId: bigint): Promise<Harvest[]> {
  const latest = await client.getBlockNumber();
  const windowStart = latest > RPC_LOG_WINDOW ? latest - RPC_LOG_WINDOW : 0n;
  const [indexed, recent] = await Promise.all([
    fetchExplorerHarvests(tokenId),
    client.getLogs({
      address: book.payDown,
      event: harvestedEvent,
      args: { tokenId },
      fromBlock: windowStart > wave2Pair.fromBlock ? windowStart : wave2Pair.fromBlock,
      toBlock: latest,
    }),
  ]);

  const known = new Set(indexed.map((row) => logKey(row.hash, row.index)));
  const fresh = recent.filter(
    (log) =>
      sameAddress(log.address, book.payDown) &&
      log.transactionHash !== null &&
      log.blockNumber !== null &&
      !known.has(logKey(log.transactionHash, log.logIndex ?? 0)),
  );

  // The node's logs carry no time, so each new block is asked once.
  const blocks = [...new Set(fresh.map((log) => log.blockNumber as bigint))];
  const stamps = await Promise.all(blocks.map((blockNumber) => client.getBlock({ blockNumber })));
  const timeOf = new Map(blocks.map((block, position) => [block, Number(stamps[position]?.timestamp ?? 0n)]));

  const rows: HarvestRow[] = [
    ...indexed,
    ...fresh.map((log) => ({
      hash: log.transactionHash as Hex,
      timestamp: timeOf.get(log.blockNumber as bigint) ?? 0,
      caller: log.args.caller as Address,
      musdRepaid: log.args.musdRepaid as bigint,
      btcSold: log.args.btcSold as bigint,
      musdFromBtc: log.args.musdFromBtc as bigint,
      block: log.blockNumber as bigint,
      index: log.logIndex ?? 0,
    })),
  ];
  rows.sort((a, b) => (a.block === b.block ? b.index - a.index : a.block > b.block ? -1 : 1));
  return rows.map(({ block: _block, index: _index, ...harvest }) => harvest);
}

export type PayDownState = {
  /** The one address the borrower named to claim this position's rewards. Null when none is named. */
  operator: Address | null;
  isPayDown: boolean;
  slippageBps: number;
  paused: boolean;
};

/** Whether the borrower has turned pay-down on, and PayDown's two settings, in one multicall. Any failed read throws. */
export async function readPayDownState(client: PublicClient, tokenId: bigint): Promise<PayDownState> {
  const [position, slippageBps, paused] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.loanManager, abi: positionRead, functionName: "positionOf", args: [tokenId] },
      { address: book.payDown, abi: payDownAbi, functionName: "slippageBps" },
      { address: book.payDown, abi: payDownAbi, functionName: "paused" },
    ],
  });
  const operator = position.rewardOperator.toLowerCase() === ZERO ? null : position.rewardOperator;
  return { operator, isPayDown: operator !== null && sameAddress(operator, book.payDown), slippageBps, paused };
}

/**
 * The claim plan a harvest sends: the pools this position voted for, on Wave 2's token rule. It is built the same way
 * for the estimate and for the button, so what is shown is what is sent.
 */
export async function buildPayDownPlan(client: PublicClient, tokenId: bigint): Promise<ClaimPlan> {
  const { poolsVoter, maxVotes } = await readVoterAddresses(client);
  const votes = await readVotes(client, poolsVoter, maxVotes, tokenId);
  return buildClaimRewardsArgs(
    client,
    poolsVoter,
    votes.pools.map((entry) => entry.pool),
    "wave2",
  );
}

export type HarvestQuote = { kind: "ready"; repaid: bigint } | { kind: "nothing" } | { kind: "refused"; reason: string };

/**
 * What a harvest would repay right now, from a dry run of PayDown.harvest. Harvest is open to everyone, so the
 * zero address stands in when no wallet is connected. A revert is an answer ("refused"); a failed read is thrown so
 * the screen says "unavailable" instead of guessing.
 */
export async function quoteHarvest(client: PublicClient, tokenId: bigint, account: Address): Promise<HarvestQuote> {
  const plan = await buildPayDownPlan(client, tokenId);
  if (plan.gauges.length === 0) return { kind: "nothing" };
  try {
    const { result } = await client.simulateContract({
      address: book.payDown,
      abi: payDownAbi,
      functionName: "harvest",
      args: [tokenId, plan.gauges, plan.feeTokens, plan.bribeTokens],
      account,
    });
    return result === 0n ? { kind: "nothing" } : { kind: "ready", repaid: result };
  } catch (error) {
    if (findRevert(error) === null) throw error;
    return { kind: "refused", reason: explainError(error, { phase: "simulate" }).detail };
  }
}

/** A write for useWrite, without its success line. PayDown has its own name there, which LoanCall does not list. */
export type PayDownCall = {
  target: "payDown" | "loanManager";
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
};

/** Names `operator` as the position's reward claimer on the Wave 2 LoanManager. The zero address clears it. */
export const setRewardOperatorCall = (tokenId: bigint, operator: Address): PayDownCall => ({
  target: "loanManager",
  abi: loanManagerAbi as Abi,
  functionName: "setRewardOperator",
  args: [tokenId, operator],
});

export const turnOnCall = (tokenId: bigint): PayDownCall => setRewardOperatorCall(tokenId, book.payDown);

export const turnOffCall = (tokenId: bigint): PayDownCall => setRewardOperatorCall(tokenId, ZERO);

/** A plan is built for one pair's token rule, so a plan from the 20 October pair is refused rather than sent. */
export function harvestCall(tokenId: bigint, plan: ClaimPlan): PayDownCall {
  if (plan.pair !== "wave2") throw new Error(`Pay-down works on the Wave 2 pair, not ${plan.pair}`);
  return {
    target: "payDown",
    abi: payDownAbi as unknown as Abi,
    functionName: "harvest",
    args: [tokenId, plan.gauges, plan.feeTokens, plan.bribeTokens],
  };
}

export type HarvestedAmounts = { musdRepaid: bigint; btcSold: bigint; musdFromBtc: bigint };

/** The Harvested event PayDown emitted for this position in a receipt, or null when the receipt has none. */
export function parseHarvested(receipt: Pick<TransactionReceipt, "logs">, tokenId: bigint): HarvestedAmounts | null {
  const word = tokenWord(tokenId).toLowerCase();
  for (const log of receipt.logs) {
    if (!sameAddress(log.address, book.payDown)) continue;
    if (log.topics[0]?.toLowerCase() !== HARVESTED_TOPIC.toLowerCase() || log.topics[1]?.toLowerCase() !== word) continue;
    try {
      const event = decodeEventLog({ abi: [harvestedEvent], data: log.data, topics: log.topics });
      return { musdRepaid: event.args.musdRepaid, btcSold: event.args.btcSold, musdFromBtc: event.args.musdFromBtc };
    } catch {
      continue;
    }
  }
  return null;
}

/**
 * An 18-decimal amount to a fixed number of places, rounded to nearest. A real amount too small for the places reads
 * "<0.0001", never a zero that was not read.
 */
export function fixedText(wei: bigint, places: number): string {
  if (wei <= 0n) return `0.${"0".repeat(places)}`;
  const step = 10n ** BigInt(18 - places);
  const scaled = (wei + step / 2n) / step;
  if (scaled === 0n) return `<0.${"0".repeat(places - 1)}1`;
  const digits = scaled.toString().padStart(places + 1, "0");
  return `${digits.slice(0, -places)}.${digits.slice(-places)}`;
}

/** The Done line after a harvest, from the numbers in its Harvested event. */
export function harvestedLine(tokenId: bigint, amounts: HarvestedAmounts): string {
  const base = `Harvested: ${fixedText(amounts.musdRepaid, 4)} MUSD went to loan #${tokenId}.`;
  if (amounts.btcSold <= 0n) return base;
  return `${base} ${fixedText(amounts.btcSold, 8)} BTC was sold for ${fixedText(amounts.musdFromBtc, 4)} MUSD of it.`;
}

/** The allowance in percent for the card's sentence: 100 basis points read "1", 125 read "1.25". */
export const slippageText = (slippageBps: number): string => String(Number((slippageBps / 100).toFixed(2)));

/** Thursday 00:00 UTC strictly after `now`, in unix seconds. The unix epoch began on a Thursday. */
export const nextThursday = (now: number): number => (Math.floor(now / WEEK) + 1) * WEEK;

export const sumRepaid = (harvests: readonly Harvest[]): bigint => harvests.reduce((sum, harvest) => sum + harvest.musdRepaid, 0n);

export type LedgerShares = { rewards: number; borrower: number };

/**
 * How much of the face each side has repaid, as percents of the bar. Rewards come first and the borrower takes the
 * rest of what the loan shows as repaid; together they never pass 100.
 */
export function ledgerShares(face: bigint, repaid: bigint, byRewards: bigint): LedgerShares {
  if (face <= 0n) return { rewards: 0, borrower: 0 };
  const percent = (part: bigint) => Number((part * 10_000n) / face) / 100;
  const rewards = Math.min(100, percent(byRewards));
  const byBorrower = repaid > byRewards ? repaid - byRewards : 0n;
  return { rewards, borrower: Math.min(100 - rewards, percent(byBorrower)) };
}

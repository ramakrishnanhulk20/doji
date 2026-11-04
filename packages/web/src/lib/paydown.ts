import {
  decodeEventLog,
  getAbiItem,
  parseAbi,
  toEventSelector,
  type Abi,
  type Address,
  type PublicClient,
  type TransactionReceipt,
} from "viem";
import { loanManagerAbi } from "../abi/loanManager";
import { payDownAbi } from "../abi/payDown";
import { addressBook, wave2Pair } from "./addresses";
import { explainError, findRevert } from "./errors";
import { shortAddress } from "./loans";
import { buildClaimRewardsArgs, readVoterAddresses, readVotes, type ClaimPlan } from "./votes";

const book = addressBook[31611];

const WEEK = 604_800;
const ZERO: Address = "0x0000000000000000000000000000000000000000";


// Wave 2 adds the reward operator to the position record, so this slice reads both words.
const positionRead = parseAbi(["function positionOf(uint256 tokenId) view returns ((address borrower, address rewardOperator))"]);

import { HARVESTED_TOPIC, harvestedEvent, sameAddress, tokenWord, type Harvest } from "./harvests";

export { readHarvests, readRepaidByRewards, slippageText, type Harvest } from "./harvests";

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

export type Route = { from: Address; to: Address; stable: boolean; factory: Address };

export type PendingReward = { token: Address; symbol: string; decimals: number; amount: bigint };

export type SwapQuote = { token: Address; amountIn: bigint; routes: Route[]; quotedOut: bigint; amountOutMin: bigint } | null;

/** The borrower accepts a sale at most this far below the Router's quote, in basis points of the quote. */
const SALE_FLOOR_BPS = 9_900n;
const BPS = 10_000n;

const rewardSidesAbi = parseAbi([
  "function gaugeToFees(address gauge) view returns (address)",
  "function gaugeToBribe(address gauge) view returns (address)",
]);

const earnedAbi = parseAbi(["function earned(address token, uint256 tokenId) view returns (uint256)"]);

const routerQuoteAbi = parseAbi([
  "function defaultFactory() view returns (address)",
  "function getAmountsOut(uint256 amountIn, (address from, address to, bool stable, address factory)[] routes) view returns (uint256[] amounts)",
]);

const isZeroAddress = (address: string): boolean => address.toLowerCase() === ZERO;

/**
 * What this position has earned in tokens a harvest does not sell on its own: the fees and incentives in every token
 * except MUSD and BTC, summed across the plan's gauges. MUSD and BTC are handled by every harvest, so they are left out.
 * `earned` counts finished weeks only, so a week's rewards show here after its Thursday 00:00 UTC. A failed read is
 * thrown, so the screen hides the list instead of showing a smaller one.
 */
export async function readOtherRewards(client: PublicClient, tokenId: bigint, plan: ClaimPlan): Promise<PendingReward[]> {
  if (plan.gauges.length === 0) return [];

  const sides = await client.multicall({
    allowFailure: false,
    contracts: plan.gauges.flatMap((gauge) => [
      { address: book.poolsVoter, abi: rewardSidesAbi, functionName: "gaugeToFees" as const, args: [gauge] as const },
      { address: book.poolsVoter, abi: rewardSidesAbi, functionName: "gaugeToBribe" as const, args: [gauge] as const },
    ]),
  });

  const handled = new Set([book.musd.toLowerCase(), book.btc.toLowerCase()]);
  const asked = plan.gauges.flatMap((_, index) => {
    const feeContract = sides[index * 2];
    const bribeContract = sides[index * 2 + 1];
    const fees = feeContract !== undefined && !isZeroAddress(feeContract) ? (plan.feeTokens[index] ?? []) : [];
    const bribes = bribeContract !== undefined && !isZeroAddress(bribeContract) ? (plan.bribeTokens[index] ?? []) : [];
    return [
      ...fees.map((token) => ({ reward: feeContract as Address, token })),
      ...bribes.map((token) => ({ reward: bribeContract as Address, token })),
    ].filter(({ token }) => !handled.has(token.toLowerCase()));
  });
  if (asked.length === 0) return [];

  const earned = await client.multicall({
    allowFailure: false,
    contracts: asked.map(({ reward, token }) => ({
      address: reward,
      abi: earnedAbi,
      functionName: "earned" as const,
      args: [token, tokenId] as const,
    })),
  });

  const totals = new Map<string, bigint>();
  asked.forEach(({ token }, index) => {
    const key = token.toLowerCase();
    totals.set(key, (totals.get(key) ?? 0n) + (earned[index] ?? 0n));
  });

  const pending: PendingReward[] = [];
  for (const label of plan.tokens) {
    const amount = totals.get(label.token.toLowerCase());
    if (amount === undefined || amount <= 0n) continue;
    pending.push({ token: label.token, symbol: label.symbol, decimals: label.decimals, amount });
  }
  return pending;
}

// The Router is fixed and its default factory never changes, so one read serves every quote. A failed read is not kept.
let defaultFactoryRead: Promise<Address> | null = null;

function readDefaultFactory(client: PublicClient): Promise<Address> {
  defaultFactoryRead ??= client
    .readContract({ address: book.router, abi: routerQuoteAbi, functionName: "defaultFactory" })
    .catch((error: unknown) => {
      defaultFactoryRead = null;
      throw error;
    });
  return defaultFactoryRead;
}

/**
 * What Mezo's pools would pay in MUSD for selling `amountIn` of `token` now, by the best of three routes: straight
 * through the volatile pool, straight through the stable pool, or through BTC. The minimum is 1% below the quote. Null
 * when no route pays anything. A pool that does not exist quotes 0 or fails, and either way that route is passed over.
 */
export async function quoteSale(client: PublicClient, token: Address, amountIn: bigint): Promise<SwapQuote> {
  if (amountIn <= 0n) return null;
  const factory = await readDefaultFactory(client);
  const hop = (from: Address, to: Address, stable: boolean): Route => ({ from, to, stable, factory });
  const candidates: Route[][] = [
    [hop(token, book.musd, false)],
    [hop(token, book.musd, true)],
    [hop(token, book.btc, false), hop(book.btc, book.musd, false)],
  ];

  const answers = await client.multicall({
    allowFailure: true,
    contracts: candidates.map((routes) => ({
      address: book.router,
      abi: routerQuoteAbi,
      functionName: "getAmountsOut" as const,
      args: [amountIn, routes] as const,
    })),
  });

  let best: { routes: Route[]; out: bigint } | null = null;
  answers.forEach((entry, index) => {
    if (entry.status !== "success") return;
    const out = entry.result[entry.result.length - 1] ?? 0n;
    if (out > (best?.out ?? 0n)) best = { routes: candidates[index] ?? [], out };
  });
  const chosen = best as { routes: Route[]; out: bigint } | null;
  if (chosen === null) return null;

  const amountOutMin = (chosen.out * SALE_FLOOR_BPS) / BPS;
  if (amountOutMin === 0n) return null;
  return { token, amountIn, routes: chosen.routes, quotedOut: chosen.out, amountOutMin };
}

/** The borrower's own harvest: as harvestCall, and it also sells the listed reward tokens at the borrower's minimums. */
export function harvestAndSwapCall(
  tokenId: bigint,
  plan: ClaimPlan,
  swaps: readonly { token: Address; amountOutMin: bigint; routes: Route[] }[],
): PayDownCall {
  if (plan.pair !== "wave2") throw new Error(`Pay-down works on the Wave 2 pair, not ${plan.pair}`);
  return {
    target: "payDown",
    abi: payDownAbi as unknown as Abi,
    functionName: "harvestAndSwap",
    args: [
      tokenId,
      plan.gauges,
      plan.feeTokens,
      plan.bribeTokens,
      swaps.map(({ token, amountOutMin, routes }) => ({ token, amountOutMin, routes })),
    ],
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

/** A token amount in its own decimals to a fixed number of places, with the same rounding and "<" rule as fixedText. */
export function tokenFixedText(amount: bigint, decimals: number, places: number): string {
  const scaled = decimals <= 18 ? amount * 10n ** BigInt(18 - decimals) : amount / 10n ** BigInt(decimals - 18);
  return fixedText(scaled, places);
}

const rewardSwappedEvent = getAbiItem({ abi: payDownAbi, name: "RewardSwapped" });
const REWARD_SWAPPED_TOPIC = toEventSelector(rewardSwappedEvent);

export type SwappedReward = { token: Address; symbol: string; decimals: number; amountIn: bigint; musdOut: bigint };

/**
 * The RewardSwapped events PayDown emitted for this position in a receipt, in the order they ran. Only logs from
 * PayDown's own address count (C49), and `labels` give each token its name and decimals for the Done line.
 */
export function parseSwapped(
  receipt: Pick<TransactionReceipt, "logs">,
  tokenId: bigint,
  labels: readonly { token: Address; symbol: string; decimals: number }[],
): SwappedReward[] {
  const word = tokenWord(tokenId).toLowerCase();
  const found: SwappedReward[] = [];
  for (const log of receipt.logs) {
    if (!sameAddress(log.address, book.payDown)) continue;
    if (log.topics[0]?.toLowerCase() !== REWARD_SWAPPED_TOPIC.toLowerCase() || log.topics[1]?.toLowerCase() !== word) continue;
    try {
      const event = decodeEventLog({ abi: [rewardSwappedEvent], data: log.data, topics: log.topics });
      const label = labels.find((candidate) => sameAddress(candidate.token, event.args.token));
      found.push({
        token: event.args.token,
        symbol: label?.symbol ?? shortAddress(event.args.token),
        decimals: label?.decimals ?? 18,
        amountIn: event.args.amountIn,
        musdOut: event.args.musdOut,
      });
    } catch {
      continue;
    }
  }
  return found;
}

/** The Done line after a harvest that also sold reward tokens: the harvest line, then one sentence per sale. */
export function soldLine(tokenId: bigint, amounts: HarvestedAmounts, sold: readonly SwappedReward[]): string {
  const sales = sold.map((item) => ` Sold ${tokenFixedText(item.amountIn, item.decimals, 4)} ${item.symbol} for ${fixedText(item.musdOut, 4)} MUSD.`);
  return `${harvestedLine(tokenId, amounts)}${sales.join("")}`;
}

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

import {
  decodeEventLog,
  formatUnits,
  parseAbi,
  parseAbiItem,
  toEventSelector,
  type Address,
  type PublicClient,
  type TransactionReceipt,
} from "viem";
import { bribeRewardAbi, erc20Abi, feeDistributorAbi, poolAbi, poolsVoterAbi, splitterAbi } from "../abi/external";
import { addressBook } from "./addresses";
import { lockDurationFor, thursdaysWithin } from "./borrow";
import {
  STATE_ACTIVE,
  STATE_AUCTION,
  answer,
  formatDateTime,
  managerCall,
  shortAddress,
  type Entry,
  type LoanCall,
  type Lock,
  type PositionView,
} from "./loans";

const book = addressBook[31611];

const WEEK = 604_800;
const HOUR = 3_600;
/** veBTC lets a lock end at most four weeks from now, rounded down to a Thursday. */
const MAX_LOCK_SECONDS = 4 * WEEK;
/** PassThrough refuses a claim that lists more reward tokens than this in total. */
export const MAX_REWARD_TOKENS = 16;
const ZERO = "0x0000000000000000000000000000000000000000";

const managerWiringAbi = parseAbi([
  "function poolsVoter() view returns (address)",
  "function feeDistributor() view returns (address)",
  "function maxVotes() view returns (uint16)",
]);

const forwardedEvent = parseAbiItem("event RewardsForwarded(uint256 indexed tokenId, address indexed token, uint256 amount)");
const FORWARDED_TOPIC = toEventSelector(forwardedEvent);

const indices = (count: number): bigint[] => Array.from({ length: count }, (_, index) => BigInt(index));
const isSet = (address: Address | null): address is Address => address !== null && address.toLowerCase() !== ZERO;

export type VoterAddresses = { poolsVoter: Address; feeDistributor: Address; maxVotes: number };

/** The voter, the fee distributor and the vote size limit LoanManager was deployed with. They never change. */
export async function readVoterAddresses(client: PublicClient): Promise<VoterAddresses> {
  const [poolsVoter, feeDistributor, maxVotes] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.loanManager, abi: managerWiringAbi, functionName: "poolsVoter" },
      { address: book.loanManager, abi: managerWiringAbi, functionName: "feeDistributor" },
      { address: book.loanManager, abi: managerWiringAbi, functionName: "maxVotes" },
    ],
  });
  return { poolsVoter, feeDistributor, maxVotes };
}

export type VotePool = { pool: Address; symbol: string; gauge: Address | null; alive: boolean };

/** Every pool on the voter, with its name and whether its gauge still takes votes. */
export async function readPools(client: PublicClient, voter: Address): Promise<VotePool[]> {
  const count = Number(await client.readContract({ address: voter, abi: poolsVoterAbi, functionName: "length" }));
  if (count === 0) return [];

  const addresses = await client.multicall({
    allowFailure: false,
    contracts: indices(count).map((index) => ({
      address: voter,
      abi: poolsVoterAbi,
      functionName: "pools" as const,
      args: [index] as const,
    })),
  });

  const details = (await client.multicall({
    allowFailure: true,
    contracts: addresses.flatMap((pool) => [
      { address: voter, abi: poolsVoterAbi, functionName: "gauges" as const, args: [pool] as const },
      { address: pool, abi: poolAbi, functionName: "symbol" as const },
    ]),
  })) as unknown as Entry[];

  const gauges = addresses.map((_, index) => {
    const gauge = answer<Address>(details[index * 2]);
    return isSet(gauge) ? gauge : null;
  });
  const withGauge = gauges.filter((gauge): gauge is Address => gauge !== null);
  const states = (await client.multicall({
    allowFailure: true,
    contracts: withGauge.map((gauge) => ({
      address: voter,
      abi: poolsVoterAbi,
      functionName: "isAlive" as const,
      args: [gauge] as const,
    })),
  })) as unknown as Entry[];

  let next = 0;
  return addresses.map((pool, index) => {
    const gauge = gauges[index] ?? null;
    const alive = gauge !== null ? (answer<boolean>(states[next++]) ?? false) : false;
    return { pool, symbol: answer<string>(details[index * 2 + 1]) ?? shortAddress(pool), gauge, alive };
  });
}

export type VotedPool = { pool: Address; symbol: string; weight: bigint; percent: number };

export type VoteState = {
  pools: VotedPool[];
  /** Unix seconds of the last vote, or 0 when the position never voted. */
  lastVoted: number;
};

/** The pools this position's vote stands on and each pool's share of it, in percent. */
export async function readVotes(client: PublicClient, voter: Address, maxVotes: number, tokenId: bigint): Promise<VoteState> {
  const [lastVotedAt, first] = await Promise.all([
    client.readContract({ address: voter, abi: poolsVoterAbi, functionName: "lastVoted", args: [tokenId] }),
    client.multicall({
      allowFailure: true,
      contracts: indices(maxVotes).map((index) => ({
        address: voter,
        abi: poolsVoterAbi,
        functionName: "poolVote" as const,
        args: [tokenId, index] as const,
      })),
    }) as unknown as Promise<Entry[]>,
  ]);

  const lastVoted = Number(lastVotedAt);
  const listed: Address[] = [];
  // poolVote reverts once the index runs past the last pool the position voted for.
  for (const entry of first) {
    const pool = answer<Address>(entry);
    if (pool === null) break;
    listed.push(pool);
  }
  if (listed.length === 0) return { pools: [], lastVoted };

  const second = (await client.multicall({
    allowFailure: true,
    contracts: listed.flatMap((pool) => [
      { address: voter, abi: poolsVoterAbi, functionName: "votes" as const, args: [tokenId, pool] as const },
      { address: pool, abi: poolAbi, functionName: "symbol" as const },
    ]),
  })) as unknown as Entry[];

  const rows = listed.map((pool, index) => ({
    pool,
    symbol: answer<string>(second[index * 2 + 1]) ?? shortAddress(pool),
    weight: answer<bigint>(second[index * 2]) ?? 0n,
  }));
  const total = rows.reduce((sum, row) => sum + row.weight, 0n);
  const pools = rows
    .filter((row) => row.weight > 0n)
    .map((row) => ({ ...row, percent: Number((row.weight * 10_000n) / total) / 100 }));
  return { pools, lastVoted };
}

/** Whole percents that add up to 100: each pool gets an equal share and the last one takes what is left over. */
export function evenSplit(count: number): number[] {
  if (count <= 0) return [];
  const share = Math.floor(100 / count);
  return Array.from({ length: count }, (_, index) => (index === count - 1 ? 100 - share * (count - 1) : share));
}

/** A share as the cards show it: "25", "62.5". */
export const percentText = (percent: number): string => String(Math.round(percent * 10) / 10);

/** The weights go to PoolsVoter as percent x 100, so a 25% share is 2,500. */
export const buildVoteCall = (tokenId: bigint, pools: readonly Address[], percents: readonly number[]): LoanCall =>
  managerCall("vote", [tokenId, pools, percents.map((percent) => BigInt(percent) * 100n)]);

export const buildResetCall = (tokenId: bigint): LoanCall => managerCall("resetVotes", [tokenId]);

export const buildClaimRebaseCall = (tokenId: bigint): LoanCall => managerCall("claimRebase", [tokenId]);

export const buildExtendLockCall = (tokenId: bigint, date: number, now: number): LoanCall =>
  managerCall("extendLock", [tokenId, lockDurationFor(date, now)]);

/** BTC the fee distributor holds for this position. */
export async function readRebase(client: PublicClient, feeDistributor: Address, tokenId: bigint): Promise<bigint> {
  return client.readContract({ address: feeDistributor, abi: feeDistributorAbi, functionName: "claimable", args: [tokenId] });
}

/**
 * The start of the week the fee distributor last opened its rewards round for. Its claim refuses to run until this
 * reaches the current week, because the weekly update has to come first.
 */
export async function readRewardsRound(client: PublicClient, feeDistributor: Address): Promise<number> {
  const splitter = await client.readContract({ address: feeDistributor, abi: feeDistributorAbi, functionName: "depositor" });
  return Number(await client.readContract({ address: splitter, abi: splitterAbi, functionName: "activePeriod" }));
}

/** Why the fee distributor would refuse a rebase claim right now, in plain words, or null when it would run. */
export function rebaseRefusal(openedRound: number, now: number): string | null {
  if (openedRound >= epochStart(now)) return null;
  return "Mezo has not opened this week's rewards round yet, so the fee distributor refuses claims for now. Try again once it has.";
}

/** Votes and extending need an Active loan that is on time and safe, the same check LoanManager runs. */
export const loanAllowsVoting = (view: PositionView): boolean =>
  view.loan.state === STATE_ACTIVE && !view.overdue && view.unsafe === false;

/** The lock can be pushed out: the loan allows it, the lock is a normal one, and veBTC still has a later Thursday to give. */
export const canExtendLock = (view: PositionView, now: number): boolean =>
  loanAllowsVoting(view) && view.lock !== null && !view.lock.isPermanent && extensionDates(view.lock.end, now).length > 0;

/** Claims run at any health, but never while the loan is in auction or after Doji has handed the position back. */
export const loanAllowsClaims = (view: PositionView): boolean => view.borrower !== null && view.loan.state !== STATE_AUCTION;

/** The moment a normal lock stops taking votes: one week before it ends. Null for a permanent lock. */
export function voteCutoff(lock: Lock | null): number | null {
  return lock === null || lock.isPermanent ? null : lock.end - WEEK;
}

export function votingClosed(lock: Lock | null, now: number): boolean {
  const cutoff = voteCutoff(lock);
  return cutoff !== null && now >= cutoff;
}

const epochStart = (time: number): number => Math.floor(time / WEEK) * WEEK;

/**
 * Why Mezo's voter would refuse a vote or a reset right now, in plain words, or null when it would take it. The voter
 * gives each position one vote or reset per weekly round and takes none in the first hour of a round. A vote is also
 * refused in the last hour.
 */
export function voterRefusal(kind: "vote" | "reset", lastVoted: number, now: number): string | null {
  const start = epochStart(now);
  if (start <= lastVoted) {
    return `Mezo's voter takes one vote or reset per position in each weekly round. This position has already used its turn, and the next round starts ${formatDateTime(start + WEEK)}.`;
  }
  if (now <= start + HOUR) {
    return `A new round has just started. Mezo's voter takes votes and resets from ${formatDateTime(start + HOUR)}.`;
  }
  if (kind === "vote" && now > start + WEEK - HOUR) {
    return `Mezo's voter takes no votes in the last hour of a round. Try again from ${formatDateTime(start + WEEK + HOUR)}.`;
  }
  return null;
}

/** The Thursdays after the lock end that veBTC still allows: at most four weeks from now. */
export function extensionDates(lockEnd: number, now: number): number[] {
  const latest = epochStart(now + MAX_LOCK_SECONDS);
  const dates: number[] = [];
  for (let date = epochStart(lockEnd) + WEEK; date <= latest; date += WEEK) dates.push(date);
  return dates;
}

/** The Thursdays a roll can reach only by extending the lock first: inside the longest term and the longest lock. */
export function rollExtensionDates(view: PositionView, maxTermSeconds: number, now: number): number[] {
  if (view.lock === null || !canExtendLock(view, now)) return [];
  const reachable = new Set(extensionDates(view.lock.end, now));
  return thursdaysWithin(now, maxTermSeconds).filter((date) => date > view.loan.maturity && reachable.has(date));
}

export type RewardToken = { token: Address; symbol: string; decimals: number };

export type ClaimPlan = {
  gauges: Address[];
  feeTokens: Address[][];
  bribeTokens: Address[][];
  /** Each distinct token in the call, with its name and decimals for the Done line. */
  tokens: RewardToken[];
  /** True when some tokens were left out to stay within the 16 the contract accepts. */
  truncated: boolean;
};

const distinct = (list: readonly Address[]): Address[] => {
  const seen = new Set<string>();
  return list.filter((token) => {
    const key = token.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
};

/**
 * The gauges and token lists for claimRewards. Fee tokens are each pool's two tokens, incentive tokens are the ones
 * the gauge's incentive contract lists, and only tokens PoolsVoter whitelists are kept, because the contract refuses
 * the rest. A gauge with no token left is dropped, since every listed gauge must list at least one. The contract
 * counts a token once per list it appears in, so the call is cut at 16 entries.
 */
export async function buildClaimRewardsArgs(client: PublicClient, voter: Address, pools: readonly Address[]): Promise<ClaimPlan> {
  const empty: ClaimPlan = { gauges: [], feeTokens: [], bribeTokens: [], tokens: [], truncated: false };
  if (pools.length === 0) return empty;

  const poolReads = (await client.multicall({
    allowFailure: true,
    contracts: pools.flatMap((pool) => [
      { address: voter, abi: poolsVoterAbi, functionName: "gauges" as const, args: [pool] as const },
      { address: pool, abi: poolAbi, functionName: "token0" as const },
      { address: pool, abi: poolAbi, functionName: "token1" as const },
    ]),
  })) as unknown as Entry[];

  const entries = pools
    .map((_, index) => ({
      gauge: answer<Address>(poolReads[index * 3]),
      token0: answer<Address>(poolReads[index * 3 + 1]),
      token1: answer<Address>(poolReads[index * 3 + 2]),
    }))
    .filter((entry): entry is { gauge: Address; token0: Address | null; token1: Address | null } => isSet(entry.gauge));
  if (entries.length === 0) return empty;

  const bribeReads = (await client.multicall({
    allowFailure: true,
    contracts: entries.map((entry) => ({
      address: voter,
      abi: poolsVoterAbi,
      functionName: "gaugeToBribe" as const,
      args: [entry.gauge] as const,
    })),
  })) as unknown as Entry[];
  const bribes = entries.map((_, index) => {
    const bribe = answer<Address>(bribeReads[index]);
    return isSet(bribe) ? bribe : null;
  });

  const lengthReads = (await client.multicall({
    allowFailure: true,
    contracts: bribes.filter(isSet).map((bribe) => ({ address: bribe, abi: bribeRewardAbi, functionName: "rewardsListLength" as const })),
  })) as unknown as Entry[];
  let lengthSlot = 0;
  const counts = bribes.map((bribe) =>
    bribe === null ? 0 : Math.min(Number(answer<bigint>(lengthReads[lengthSlot++]) ?? 0n), MAX_REWARD_TOKENS),
  );

  const listReads = (await client.multicall({
    allowFailure: true,
    contracts: bribes.flatMap((bribe, index) =>
      bribe === null
        ? []
        : indices(counts[index] ?? 0).map((position) => ({
            address: bribe,
            abi: bribeRewardAbi,
            functionName: "rewards" as const,
            args: [position] as const,
          })),
    ),
  })) as unknown as Entry[];
  let listSlot = 0;
  const incentives = entries.map((_, index) => {
    const found: Address[] = [];
    for (let position = 0; position < (counts[index] ?? 0); position++) {
      const token = answer<Address>(listReads[listSlot++]);
      if (isSet(token)) found.push(token);
    }
    return distinct(found);
  });
  const fees = entries.map((entry) => distinct([entry.token0, entry.token1].filter(isSet)));

  const candidates = distinct([...fees.flat(), ...incentives.flat()]);
  const whitelistReads = (await client.multicall({
    allowFailure: true,
    contracts: candidates.map((token) => ({
      address: voter,
      abi: poolsVoterAbi,
      functionName: "isWhitelistedToken" as const,
      args: [token] as const,
    })),
  })) as unknown as Entry[];
  const accepted = new Set(
    candidates.filter((_, index) => answer<boolean>(whitelistReads[index]) === true).map((token) => token.toLowerCase()),
  );

  const plan: ClaimPlan = { gauges: [], feeTokens: [], bribeTokens: [], tokens: [], truncated: false };
  let listed = 0;
  entries.forEach((entry, index) => {
    const fee = (fees[index] ?? []).filter((token) => accepted.has(token.toLowerCase()));
    const incentive = (incentives[index] ?? []).filter((token) => accepted.has(token.toLowerCase()));
    const room = MAX_REWARD_TOKENS - listed;
    const keptFee = fee.slice(0, room);
    const keptIncentive = incentive.slice(0, room - keptFee.length);
    if (keptFee.length < fee.length || keptIncentive.length < incentive.length) plan.truncated = true;
    if (keptFee.length + keptIncentive.length === 0) return;
    plan.gauges.push(entry.gauge);
    plan.feeTokens.push(keptFee);
    plan.bribeTokens.push(keptIncentive);
    listed += keptFee.length + keptIncentive.length;
  });

  const used = distinct([...plan.feeTokens.flat(), ...plan.bribeTokens.flat()]);
  if (used.length === 0) return plan;
  const labelReads = (await client.multicall({
    allowFailure: true,
    contracts: used.flatMap((token) => [
      { address: token, abi: erc20Abi, functionName: "symbol" as const },
      { address: token, abi: erc20Abi, functionName: "decimals" as const },
    ]),
  })) as unknown as Entry[];
  plan.tokens = used.map((token, index) => ({
    token,
    symbol: answer<string>(labelReads[index * 2]) ?? shortAddress(token),
    decimals: answer<number>(labelReads[index * 2 + 1]) ?? 18,
  }));
  return plan;
}

export const buildClaimRewardsCall = (tokenId: bigint, plan: ClaimPlan): LoanCall =>
  managerCall("claimRewards", [tokenId, plan.gauges, plan.feeTokens, plan.bribeTokens]);

export type Forwarded = { token: Address; symbol: string; decimals: number; amount: bigint };

/** The RewardsForwarded events LoanManager emitted in a receipt, in the order they were paid. */
export function parseForwarded(receipt: Pick<TransactionReceipt, "logs">, labels: readonly RewardToken[]): Forwarded[] {
  const found: Forwarded[] = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== book.loanManager.toLowerCase() || log.topics[0] !== FORWARDED_TOPIC) continue;
    try {
      const event = decodeEventLog({ abi: [forwardedEvent], data: log.data, topics: log.topics });
      const label = labels.find((candidate) => candidate.token.toLowerCase() === event.args.token.toLowerCase());
      found.push({
        token: event.args.token,
        symbol: label?.symbol ?? shortAddress(event.args.token),
        decimals: label?.decimals ?? 18,
        amount: event.args.amount,
      });
    } catch {
      continue;
    }
  }
  return found;
}

/** A token amount with up to six decimals and no trailing zeros. */
export function tokenAmountText(amount: bigint, decimals: number): string {
  const [whole = "0", fraction = ""] = formatUnits(amount, decimals).split(".");
  const cut = fraction.slice(0, 6).replace(/0+$/, "");
  if (cut === "" && whole === "0" && amount > 0n) return "<0.000001";
  return cut === "" ? whole : `${whole}.${cut}`;
}

/** The Done line for a pool rewards claim. */
export function forwardedLine(forwarded: readonly Forwarded[]): string {
  if (forwarded.length === 0) return "Nothing was due yet.";
  return `Forwarded ${forwarded.map((item) => `${tokenAmountText(item.amount, item.decimals)} ${item.symbol}`).join(", ")}.`;
}

/** The line under Claim rebase: where the BTC goes depends on whether the lock is still running. */
export function rebaseLine(lock: Lock | null, now: number): string {
  const running = lock === null || lock.isPermanent || lock.end > now;
  return running
    ? "Adds the rebase to your locked BTC, so the position grows."
    : "Pays the rebase to you as BTC; collect it with Claim at the top of My loans.";
}

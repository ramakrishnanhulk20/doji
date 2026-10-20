import {
  parseAbi,
  parseUnits,
  type Abi,
  type Address,
  type PublicClient,
} from "viem";
import { creditMarketsAbi } from "../abi/creditMarkets";
import { loanManagerAbi } from "../abi/loanManager";
import { addressBook, demoLoan } from "./addresses";
import { explainError, findRevert } from "./errors";
import { readOpenAuctions, scanOpenOffers, type OpenAuction, type OpenOffer } from "./stats";

export const STRANGER: Address = "0x000000000000000000000000000000000000dEaD";
export const THREAT_MODEL_URL = "https://github.com/ramakrishnanhulk20/doji/blob/main/docs/security/threat-model.md";
export const ISSUES_URL = "https://github.com/ramakrishnanhulk20/doji/issues";

const BOOK = addressBook[31611];
const WEEK_SECONDS = 604_800;
const TEN_MUSD = parseUnits("10", 18);
const ONE_MUSD = parseUnits("1", 18);
const DEADLINE_SECONDS = 600;
const MAX_APR_BPS = 5_000;
const FULL_WEIGHT = 10_000n;

// Mezo's public nodes sometimes lag one block behind each other, so a call pinned to the newest block can miss.
const ATTEMPTS = 3;
const RETRY_MS = 600;

const poolsVoterAbi = parseAbi([
  "function length() view returns (uint256)",
  "function pools(uint256 index) view returns (address)",
]);
const offerBookAbi = parseAbi([
  "function nextOfferId() view returns (uint256)",
  "function offerOf(uint256 offerId) view returns ((address maker, uint64 maturity, uint16 aprBps, uint128 remaining))",
]);

/** What the attacks point at. Every field is read from the chain or the deployment record. */
export type AttackTargets = {
  demoTokenId: bigint;
  /** False while the search for an open auction is still running. */
  auctionKnown: boolean;
  auctionTokenId: bigint | null;
  /** The first open offer by date then id, or the newest offer ever posted when none is open. Null when there are none at all. */
  offerId: bigint | null;
  /** The earliest date an open offer is for, or the next Thursday when no offer is open. */
  earliestThursday: number;
  nextThursday: number;
  /** The first pool PoolsVoter lists, or null when it lists none. */
  pool: Address | null;
};

export type ChainTargets = {
  pool: Address | null;
  newestOfferId: bigint | null;
};

export async function readChainTargets(client: PublicClient): Promise<ChainTargets> {
  const [voter, next] = await Promise.all([
    client.readContract({ address: BOOK.loanManager, abi: loanManagerAbi, functionName: "poolsVoter" }),
    client.readContract({ address: BOOK.creditMarkets, abi: offerBookAbi, functionName: "nextOfferId" }),
  ]);
  const count = await client
    .readContract({ address: voter, abi: poolsVoterAbi, functionName: "length" })
    .catch(() => 0n);
  const pool =
    count > 0n
      ? await client.readContract({ address: voter, abi: poolsVoterAbi, functionName: "pools", args: [0n] })
      : null;
  return { pool, newestOfferId: next > 1n ? next - 1n : null };
}

export type TargetInputs = {
  offers: readonly OpenOffer[];
  /** Null while the auction search is still running. */
  auctions: readonly OpenAuction[] | null;
  chain: ChainTargets;
  now: number;
};

export function buildTargets({ offers, auctions, chain, now }: TargetInputs): AttackTargets {
  const first = [...offers].sort((a, b) => a.maturity - b.maturity || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))[0];
  const nextThursday = (Math.floor(now / WEEK_SECONDS) + 1) * WEEK_SECONDS;
  return {
    demoTokenId: demoLoan.tokenId,
    auctionKnown: auctions !== null,
    auctionTokenId: auctions?.[0]?.tokenId ?? null,
    offerId: first?.id ?? chain.newestOfferId,
    earliestThursday: first?.maturity ?? nextThursday,
    nextThursday,
    pool: chain.pool,
  };
}

/** Reads every target in one go, for the check script. The page reads the same pieces through its own cached queries. */
export async function readAttackTargets(client: PublicClient, now: number): Promise<AttackTargets> {
  const [offers, auctions, chain] = await Promise.all([
    scanOpenOffers(),
    readOpenAuctions().catch(() => [] as OpenAuction[]),
    readChainTargets(client),
  ]);
  return buildTargets({ offers, auctions, chain, now });
}

export type Attack = {
  id: string;
  title: string;
  /** One line on what the attack tries, in words that hold for any caller. */
  line: string;
  contract: "LoanManager" | "CreditMarkets";
  functionName: string;
  /** The call as a person reads it. */
  call: string;
  /** The contract error the refusal should carry. */
  expected: string;
  /** Rule ids in docs/security/threat-model.md. */
  rules: readonly string[];
  /** The line shown when the simulation succeeds. */
  goesThrough: string;
  /** Why the attack cannot run right now, or null when it can. */
  unavailable: string | null;
  address: Address;
  abi: Abi;
  /** The real arguments. The deadline in the buy attack counts from the timestamp it is given. */
  args: (blockTimestamp: number) => readonly unknown[];
};

const LOAN_MANAGER_ABI = loanManagerAbi as unknown as Abi;
const CREDIT_MARKETS_ABI = creditMarketsAbi as unknown as Abi;

type Draft = Omit<Attack, "address" | "abi" | "call"> & { shown: readonly string[] };

function make(draft: Draft): Attack {
  const { shown, ...rest } = draft;
  const onLoanManager = draft.contract === "LoanManager";
  return {
    ...rest,
    call: `${draft.contract}.${draft.functionName}(${shown.join(", ")})`,
    address: onLoanManager ? BOOK.loanManager : BOOK.creditMarkets,
    abi: onLoanManager ? LOAN_MANAGER_ABI : CREDIT_MARKETS_ABI,
  };
}

/** The twelve attacks in the order the page shows them, aimed at the live targets and sent as `caller`. */
export function buildAttacks(targets: AttackTargets, caller: Address): Attack[] {
  const demo = targets.demoTokenId;
  const demoText = demo.toString();
  const { offerId, pool, earliestThursday, nextThursday } = targets;
  const noOffer = "No offer has been posted yet, so there is nothing to point this at.";
  const offerText = offerId === null ? "none" : offerId.toString();
  const offerList = offerId === null ? [] : [offerId];
  const buyId = targets.auctionTokenId ?? demo;
  const buyText = buyId.toString();
  const hasAuction = targets.auctionTokenId !== null;

  return [
    make({
      id: "withdraw-collateral",
      title: "Take someone else's Bitcoin",
      line: "Tries to pull a borrower's locked veBTC out of Doji and into the caller's wallet.",
      contract: "LoanManager",
      functionName: "withdrawCollateral",
      shown: [demoText],
      expected: "NotBorrower",
      rules: ["C4"],
      goesThrough: "The caller is this position's borrower and it has no loan on it, so Doji hands it back. That is the rule working for its owner.",
      unavailable: null,
      args: () => [demo],
    }),
    make({
      id: "borrow-against-other",
      title: "Borrow against someone else's position",
      line: "Tries to open a loan on a position that belongs to another borrower and take the MUSD.",
      contract: "LoanManager",
      functionName: "borrow",
      shown: [demoText, String(earliestThursday), `[${offerText}]`, "[10 MUSD]", String(MAX_APR_BPS)],
      expected: "NotBorrower",
      rules: ["C4"],
      goesThrough: "The caller is this position's borrower, it has no loan and the offer can lend 10 MUSD, so a loan would open. That is the rule working for its owner.",
      unavailable: offerId === null ? noOffer : null,
      args: () => [demo, BigInt(earliestThursday), offerList, [TEN_MUSD], MAX_APR_BPS],
    }),
    make({
      id: "vote-other",
      title: "Vote with someone else's position",
      line: "Tries to cast another borrower's gauge votes, which would steer where their rewards go.",
      contract: "LoanManager",
      functionName: "vote",
      shown: [demoText, `[${pool ?? "none"}]`, "[10000]"],
      expected: "NotBorrower",
      rules: ["C4", "C5"],
      goesThrough: "The caller is this position's borrower and the loan is safe and on time, so Doji casts the vote for them. That is the rule working for its owner.",
      unavailable: pool === null ? "PoolsVoter lists no pool to vote for right now." : null,
      args: () => [demo, pool === null ? [] : [pool], [FULL_WEIGHT]],
    }),
    make({
      id: "start-auction-healthy",
      title: "Start an auction on a healthy loan",
      line: "Tries to force an auction on a loan that is safe and not yet due.",
      contract: "LoanManager",
      functionName: "startAuction",
      shown: [demoText],
      expected: "NotLiquidatable",
      rules: ["C11"],
      goesThrough: "The loan is now past its date or over its auction line, so anyone may start its auction. That is the rule working, not a way around it.",
      unavailable: null,
      args: () => [demo],
    }),
    make({
      id: "settle-no-auction",
      title: "Settle a loan that isn't in auction",
      line: "Tries to settle a loan that has no auction running, to take its Bitcoin.",
      contract: "LoanManager",
      functionName: "settle",
      shown: [demoText],
      expected: "NoAuction",
      rules: ["C12"],
      goesThrough: "This loan's auction has run to its floor and nobody bought it, so anyone may settle it. That is the rule working, not a way around it.",
      unavailable: null,
      args: () => [demo],
    }),
    make({
      id: "buy-for-nothing",
      title: "Buy a position for almost nothing",
      line: hasAuction
        ? `Tries to buy veBTC #${buyText} out of its auction while paying at most 1 MUSD.`
        : "No loan is in auction right now, so this tries to buy the demo loan's position, which is not for sale.",
      contract: "LoanManager",
      functionName: "purchase",
      shown: [buyText, "1 MUSD", `now + ${DEADLINE_SECONDS}`],
      expected: hasAuction ? "PriceAboveMax" : "NoAuction",
      rules: ["C11", "C29"],
      goesThrough: "The auction price is 1 MUSD or less right now, so the buy is allowed. That is the rule working, not a way around it.",
      unavailable: targets.auctionKnown ? null : "Looking for an open auction.",
      args: (blockTimestamp) => [buyId, ONE_MUSD, BigInt(blockTimestamp + DEADLINE_SECONDS)],
    }),
    make({
      id: "fill-without-loan",
      title: "Fill an offer without a loan",
      line: "Tries to take a lender's MUSD straight from CreditMarkets, with no collateral behind it.",
      contract: "CreditMarkets",
      functionName: "fill",
      shown: [String(earliestThursday), `[${offerText}]`, "[10 MUSD]", String(MAX_APR_BPS), caller],
      expected: "NotLoanManager",
      rules: ["C27"],
      goesThrough: "The caller is Doji's LoanManager itself, the one address allowed to fill offers.",
      unavailable: offerId === null ? noOffer : null,
      args: () => [BigInt(earliestThursday), offerList, [TEN_MUSD], MAX_APR_BPS, caller],
    }),
    make({
      id: "credit-nothing",
      title: "Credit a market with nothing",
      line: "Tries to record a repayment in a market, to change what its lenders are owed.",
      contract: "CreditMarkets",
      functionName: "credit",
      shown: [String(earliestThursday), "1 MUSD", "true"],
      expected: "NotLoanManager",
      rules: ["C14", "C27"],
      goesThrough: "The caller is Doji's LoanManager itself, the one address allowed to record repayments.",
      unavailable: null,
      args: () => [BigInt(earliestThursday), ONE_MUSD, true],
    }),
    make({
      id: "cancel-other-offer",
      title: "Cancel someone else's offer",
      line: "Tries to cancel an offer another lender posted, to send that lender's MUSD away.",
      contract: "CreditMarkets",
      functionName: "cancelOffer",
      shown: [offerText],
      expected: "NotMaker",
      rules: ["C16"],
      goesThrough: "The caller posted this offer, so cancelling it returns their own MUSD to them. That is the rule working for its owner.",
      unavailable: offerId === null ? noOffer : null,
      args: () => [offerId ?? 0n],
    }),
    make({
      id: "withdraw-early",
      title: "Cash out before the date",
      line: "Tries to take collected repayments out of a market before its Thursday has passed.",
      contract: "CreditMarkets",
      functionName: "withdrawCollected",
      shown: [String(nextThursday), "0"],
      expected: "NotMatured",
      rules: ["C15"],
      goesThrough: "This Thursday has already passed, so collected repayments can be withdrawn. That is the rule working.",
      unavailable: null,
      args: () => [BigInt(nextThursday), 0n],
    }),
    make({
      id: "rescue-as-owner",
      title: "Take users' tokens as the owner",
      line: "Tries to move tokens held by LoanManager to the caller's address, as if the caller were the owner.",
      contract: "LoanManager",
      functionName: "rescueToken",
      shown: ["MUSD", caller, "1"],
      expected: "OwnableUnauthorizedAccount",
      rules: ["C19", "C28"],
      goesThrough: "The caller is the owner and the amount is spare MUSD that nobody is owed, so the owner may move it. That is the rule working.",
      unavailable: null,
      args: () => [BOOK.musd, caller, 1n],
    }),
    make({
      id: "renounce-ownership",
      title: "Give up ownership",
      line: "Tries to renounce ownership, which would leave the settings and the rescue calls with no owner for good.",
      contract: "LoanManager",
      functionName: "renounceOwnership",
      shown: [],
      expected: "RenounceDisabled",
      rules: ["C19"],
      goesThrough: "The contract accepted a renounce call. It is built to refuse every caller, so this is worth an issue.",
      unavailable: null,
      args: () => [],
    }),
  ];
}

export type AttackOutcome =
  | { kind: "refused"; errorName: string; detail: string; matches: boolean; block: number }
  | { kind: "through"; block: number }
  | { kind: "unreachable"; detail: string };

const OUTSIDE_DETAIL: Record<string, string> = {
  AlreadyVotedOrDeposited: "Mezo's voter allows one vote per position each week, and this position has already used it.",
};

/** The name of the contract error behind a failed simulation, or null when the failure was not a refusal by the contract. */
export const revertName = (error: unknown): string | null => findRevert(error)?.name ?? null;

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Simulates one attack from `account` against the newest block and says how the contract answered. Nothing is sent:
 * the call is an eth_call, so no wallet is asked and nothing changes on chain.
 */
export async function runAttack(client: PublicClient, attack: Attack, account: Address): Promise<AttackOutcome> {
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    if (attempt > 0) await wait(RETRY_MS);
    let block;
    try {
      block = await client.getBlock();
    } catch {
      continue;
    }
    try {
      await client.simulateContract({
        account,
        address: attack.address,
        abi: attack.abi,
        functionName: attack.functionName,
        args: attack.args(Number(block.timestamp)),
        blockNumber: block.number,
      });
      return { kind: "through", block: Number(block.number) };
    } catch (error) {
      const errorName = revertName(error);
      if (errorName === null) continue;
      return {
        kind: "refused",
        errorName,
        detail: OUTSIDE_DETAIL[errorName] ?? explainError(error).detail,
        matches: errorName === attack.expected,
        block: Number(block.number),
      };
    }
  }
  return { kind: "unreachable", detail: "The network did not answer. Try again in a moment." };
}

// Pure borrowing arithmetic. Nothing here reads the chain: the offers, rates and limits come in as arguments, and
// the contract has the last word (the app confirms every number with quoteFill before it shows it as final).

export const BPS = 10_000n;
const YEAR_SECONDS = 31_536_000n;
const WEEK_SECONDS = 604_800;
export const MAX_FILLS = 8;
/** The lock must end on the chosen Thursday: this puts its end half a week past it, and veBTC rounds down. */
const HALF_WEEK_SECONDS = 302_400;
/** 0.01 MUSD, the step the app uses for amounts and for stepping a maximum down. */
export const CENT = 10n ** 16n;

export type Offer = {
  id: bigint;
  maturity: number;
  aprBps: number;
  /** MUSD left on the offer, 18 decimals. */
  remaining: bigint;
};

export type DateGroup = {
  maturity: number;
  /** Cheapest rate first, then the oldest offer. */
  offers: Offer[];
  /** MUSD available across the date's offers. */
  available: bigint;
  bestAprBps: number;
};

/** Cheapest rate first, then the oldest offer id. */
export function cheapestFirst(offers: readonly Offer[]): Offer[] {
  return [...offers].sort((a, b) => a.aprBps - b.aprBps || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/** The open offers grouped by due date, earliest date first. Offers with nothing left are dropped. */
export function groupOffersByDate(offers: readonly Offer[]): DateGroup[] {
  const byDate = new Map<number, Offer[]>();
  for (const offer of offers) {
    if (offer.remaining <= 0n) continue;
    const group = byDate.get(offer.maturity);
    if (group) group.push(offer);
    else byDate.set(offer.maturity, [offer]);
  }
  return [...byDate.entries()]
    .sort(([a], [b]) => a - b)
    .map(([maturity, list]) => {
      const sorted = cheapestFirst(list);
      return {
        maturity,
        offers: sorted,
        available: sorted.reduce((sum, offer) => sum + offer.remaining, 0n),
        bestAprBps: sorted[0]?.aprBps ?? 0,
      };
    });
}

export type Selection = {
  offerIds: bigint[];
  amounts: bigint[];
  aprs: number[];
  /** The highest rate used, which is what the contract is told to accept. */
  maxAprBps: number;
  /** MUSD the chosen offers cover. Below the wanted amount when the offers run out or MAX_FILLS is reached. */
  filled: bigint;
};

/** Takes the cheapest offers first, using only part of the last one, and at most MAX_FILLS offers. */
export function selectOffers(amount: bigint, offers: readonly Offer[], maxFills: number = MAX_FILLS): Selection {
  const selection: Selection = { offerIds: [], amounts: [], aprs: [], maxAprBps: 0, filled: 0n };
  if (amount <= 0n) return selection;

  for (const offer of cheapestFirst(offers)) {
    if (selection.filled >= amount || selection.offerIds.length >= maxFills) break;
    if (offer.remaining <= 0n) continue;
    const take = offer.remaining < amount - selection.filled ? offer.remaining : amount - selection.filled;
    selection.offerIds.push(offer.id);
    selection.amounts.push(take);
    selection.aprs.push(offer.aprBps);
    selection.filled += take;
    if (offer.aprBps > selection.maxAprBps) selection.maxAprBps = offer.aprBps;
  }
  return selection;
}

/** What one fill owes at maturity: the principal plus simple interest, rounded up, as CreditMarkets prices it. */
export function faceOf(principal: bigint, aprBps: number, secondsToMaturity: number): bigint {
  const numerator = principal * BigInt(aprBps) * BigInt(secondsToMaturity);
  const denominator = BPS * YEAR_SECONDS;
  return principal + (numerator + denominator - 1n) / denominator;
}

/** Seconds from now that make the lock end on `maturity`, rounded down by veBTC to that Thursday 00:00 UTC. */
export function lockDurationFor(maturity: number, now: number): bigint {
  return BigInt(maturity + HALF_WEEK_SECONDS - now);
}

/** The Thursdays 00:00 UTC after `now` and no further than `maxTermSeconds` away. */
export function thursdaysWithin(now: number, maxTermSeconds: number): number[] {
  const dates: number[] = [];
  for (let date = (Math.floor(now / WEEK_SECONDS) + 1) * WEEK_SECONDS; date <= now + maxTermSeconds; date += WEEK_SECONDS) {
    dates.push(date);
  }
  return dates;
}

export type MaxPrincipalInput = {
  offers: readonly Offer[];
  /** The most the borrower may owe at the date: collateral value times the borrow limit. */
  maxFace: bigint;
  secondsToMaturity: number;
  maxFills?: number;
};

/**
 * The largest principal whose face stays within maxFace, taking the cheapest offers first. It is local arithmetic
 * on the offers' rates: the caller confirms it with quoteFill and steps down by CENT until the quote fits.
 */
export function maxPrincipal({ offers, maxFace, secondsToMaturity, maxFills = MAX_FILLS }: MaxPrincipalInput): bigint {
  let budget = maxFace;
  let principal = 0n;
  let used = 0;

  for (const offer of cheapestFirst(offers)) {
    if (used >= maxFills || budget <= 0n) break;
    if (offer.remaining <= 0n) continue;

    // The face of one offer grows with the amount taken, so the largest amount that fits is found by bisection.
    let low = 0n;
    let high = offer.remaining;
    while (low < high) {
      const middle = (low + high + 1n) / 2n;
      if (faceOf(middle, offer.aprBps, secondsToMaturity) <= budget) low = middle;
      else high = middle - 1n;
    }
    if (low === 0n) break;

    principal += low;
    budget -= faceOf(low, offer.aprBps, secondsToMaturity);
    used += 1;
    if (low < offer.remaining) break;
  }
  return principal;
}

/** The amount rounded down to a whole cent of MUSD, so the form never carries digits below 0.01. */
export function roundDownToCent(amount: bigint): bigint {
  return (amount / CENT) * CENT;
}

export type StepId = "approve-btc" | "lock-and-borrow" | "approve-position" | "deposit" | "borrow";

export type BorrowStep = {
  id: StepId;
  label: string;
};

export type BuildStepsInput =
  | {
      path: "lock";
      /** Already formatted, for the label: "0.001". */
      btcText: string;
      /** True when the BTC allowance to LoanManager already covers the amount. */
      allowanceCovers: boolean;
    }
  | {
      path: "position";
      tokenId: bigint;
      /** True when getApproved already names LoanManager. */
      alreadyApproved: boolean;
    };

/** The steps the confirm button walks through. A step that is already done on chain is left out. */
export function buildBorrowSteps(input: BuildStepsInput): BorrowStep[] {
  if (input.path === "lock") {
    const steps: BorrowStep[] = [];
    if (!input.allowanceCovers) steps.push({ id: "approve-btc", label: `Approve ${input.btcText} BTC` });
    steps.push({ id: "lock-and-borrow", label: "Lock and borrow" });
    return steps;
  }

  const steps: BorrowStep[] = [];
  if (!input.alreadyApproved) steps.push({ id: "approve-position", label: `Approve veBTC #${input.tokenId}` });
  steps.push({ id: "deposit", label: "Hand it to Doji" });
  steps.push({ id: "borrow", label: "Borrow" });
  return steps;
}

/** The share of the borrow limit a face uses, in basis points of the limit. Zero when the limit is zero. */
export function limitUsedBps(face: bigint, valueWei: bigint, maxLtvBps: number): number {
  const limit = (valueWei * BigInt(maxLtvBps)) / BPS;
  if (limit <= 0n) return 0;
  return Number((face * BPS) / limit);
}

/** The MUSD price of one BTC at which the loan reaches the auction line, from the face and the live line. */
export function auctionLinePrice(faceWei: bigint, liqLtvBps: number, btcWei: bigint): bigint {
  if (btcWei <= 0n || liqLtvBps <= 0) return 0n;
  return (faceWei * BPS * 10n ** 18n) / (BigInt(liqLtvBps) * btcWei);
}

/** The rate weighted by principal, in basis points. */
export function weightedAprBps(amounts: readonly bigint[], aprs: readonly number[]): number {
  let total = 0n;
  let weighted = 0n;
  amounts.forEach((amount, index) => {
    total += amount;
    weighted += amount * BigInt(aprs[index] ?? 0);
  });
  return total === 0n ? 0 : Number(weighted / total);
}

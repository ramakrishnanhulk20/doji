import {
  BaseError,
  ContractFunctionRevertedError,
  InsufficientFundsError,
  UserRejectedRequestError,
  decodeErrorResult,
  formatUnits,
  parseAbi,
  type Abi,
  type Hex,
} from "viem";
import { creditMarketsAbi } from "../abi/creditMarkets";
import { loanManagerAbi } from "../abi/loanManager";
import { formatDate, formatMusd } from "./stats";

// Every sentence a person can read when something goes wrong comes from this file, so the wording stays in one place.

export type ErrorContext = {
  /** Where it failed: the simulation, the wallet's own prompt, or the receipt after sending. */
  phase?: "simulate" | "wallet" | "receipt";
  /** "lock" lets an error the app cannot name read as Mezo's veBTC refusing the lock. */
  action?: "lock";
};

export type Explained = {
  /** "Not sent" when nothing left the wallet, "Failed" when the transaction reached the chain and reverted. */
  title: "Not sent" | "Failed";
  detail: string;
  /** True when the offers moved, so the screen should reload them. */
  refresh?: boolean;
};

/** Problems the app finds before it asks the wallet for anything, and wallet or network state it cannot work with. */
export class AppError extends Error {
  constructor(
    readonly kind: "wrongChain" | "noWallet",
    message: string = kind,
  ) {
    super(message);
    this.name = "AppError";
  }
}

const musd = (value: unknown): string => formatMusd(Number(formatUnits(BigInt(String(value)), 18)));
const date = (value: unknown): string => formatDate(Number(value));

const OFFERS_CHANGED =
  "The offers changed while you were choosing. Doji has refreshed them; check the numbers and confirm again.";
const TOKEN_SHORT = "The token transfer came up short. Check your balance and approval and try again.";
const NOTHING_TO_CLAIM = "There's nothing to claim yet.";
const NO_ACTIVE_LOAN = "This position has no active loan.";
const RUN_PREPARE = "Run the preparation step first: it clears votes and unlocks a permanent lock.";

type Args = readonly unknown[];

const REVERTS: Record<string, (args: Args) => string> = {
  BorrowsPaused: () => "New loans are paused by the guardian. Repaying and rolling still work.",
  CollateralNotAccepted: () => "This position can't be used: it is grant-backed or not a normal lock.",
  NotTokenOwner: () => "That position isn't yours.",
  NotBorrower: () => "That position isn't yours.",
  LoanOpen: () => "This position already has a loan. Repay or roll it from My loans.",
  InvalidMaturity: () => "That date isn't a Thursday open for loans.",
  MaturityAfterLockEnd: () => "Your lock ends before that Thursday. Pick an earlier date or extend the lock.",
  MaturityBeyondMaxTerm: () => "That Thursday is further away than the longest allowed term (4 weeks).",
  BelowMinLoan: (args) => `The minimum loan is ${musd(args[1])} MUSD.`,
  LtvTooHigh: (args) =>
    `That's more than this collateral allows. The most you can owe is ${musd(args[1])} MUSD.`,
  PriceUnavailable: () => "Mezo's price feed is more than 60 seconds old right now. Try again in a minute.",
  AprAboveMax: () => OFFERS_CHANGED,
  InsufficientRemaining: () => OFFERS_CHANGED,
  OfferEmpty: () => OFFERS_CHANGED,
  OfferNotFound: () => OFFERS_CHANGED,
  WrongMaturity: () => OFFERS_CHANGED,
  BadFillCount: () => "A loan can use at most 8 offers. Borrow a little less.",
  TransferShortfall: () => TOKEN_SHORT,
  TransferMismatch: () => TOKEN_SHORT,

  NotMaker: () => "Only the lender who posted this offer can cancel it.",
  OfferTooSmall: (args) => `The minimum offer is ${musd(args[1])} MUSD.`,
  AprTooHigh: () => "The highest rate allowed is 50%.",
  OffersPaused: () => "New offers are paused by the guardian. Cancelling still works.",
  NotFinal: () => "This date's market isn't closed yet. Use Withdraw what's collected in the meantime.",
  NotMatured: () => "That Thursday hasn't passed yet.",
  LoansStillOpen: (args) => `${String(args[1])} loans at this date are still open. The market closes when they end.`,
  EmptyMarket: () => "No loans were ever made at this date.",
  MarketIsFinal: () => "This date's market has already closed.",
  NothingToClaim: () => NOTHING_TO_CLAIM,
  NoActiveLoan: () => NO_ACTIVE_LOAN,
  LoanNotActive: () => NO_ACTIVE_LOAN,
  LoanInAuction: () => "This loan is in auction. You can still repay it in full to end the auction.",
  LoanOverdue: () => "This loan is past its date. It can only be repaid or resolved through the auction.",
  LoanUnsafe: () => "This loan is close to the auction line. Repay some of it first.",
  MaturityNotLater: () => "Roll to a Thursday later than the current due date.",
  TopUpTooHigh: (args) => `Rolling needs a top-up of ${musd(args[0])} MUSD. Approve it and try again.`,
  NotLiquidatable: () => "This loan is healthy and on time, so it can't be auctioned.",
  NoAuction: () => "This loan isn't in auction.",
  StillSafe: () => "The loan is safe again at the current price, so the auction can't sell it now.",
  StillUnsafe: () => "The loan is still unsafe, so the auction can't be cancelled.",
  DeadlinePassed: () => "The price quote expired. Refresh and try again.",
  PriceAboveMax: (args) => `The price moved up to ${musd(args[0])} MUSD, above your limit. Refresh and try again.`,
  FloorTimeNotReached: (args) =>
    `The auction reaches its floor at ${date(args[1])}; it can be settled after that.`,
  LockNotEnded: (args) => `The lock ends ${date(args[1])}; it can be settled after that.`,
  LockIsPermanent: () => RUN_PREPARE,
  StillVoted: () => RUN_PREPARE,
  NothingToPrepare: () => "Nothing to prepare: there are no votes and no permanent lock.",
  StillInCustody: () => "Doji still holds this position, so it can't be written off.",
  NotInCustody: () => "Doji no longer holds this position.",
  VoteTooLate: () => "Votes close one week before the lock ends.",
  OwnableUnauthorizedAccount: () => "Only the owner can do that.",
  RenounceDisabled: () => "Ownership can never be given up.",
  NotLoanManager: () => "Only Doji's LoanManager can do that.",
  NotGuardianOrOwner: () => "Only the guardian or the owner can do that.",
  ERC1155InsufficientBalance: () => "You don't hold that many credit units.",
  ERC1155MissingApprovalForAll: () => "That wallet hasn't approved you to move its credit units.",
  ERC1155InvalidReceiver: () => "That address is a contract that can't receive credit units. Send them to a wallet instead.",
};

// Errors that name a refreshed offer list are the ones where the screen should reload.
const REFRESH = new Set(["AprAboveMax", "InsufficientRemaining", "OfferEmpty", "OfferNotFound", "WrongMaturity"]);

// Mezo's voter answers a second vote in the same week with this error, which neither Doji ABI declares.
const voterErrorsAbi = parseAbi(["error AlreadyVotedOrDeposited()"]);
const knownAbi = [...loanManagerAbi, ...creditMarketsAbi, ...voterErrorsAbi] as unknown as Abi;

export type Revert = { name: string; args: Args; reason?: string };

/** The contract error behind a failed call, decoded with every ABI Doji knows, or null when it was not a revert. */
export function findRevert(error: unknown): Revert | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk((inner) => inner instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError)) return null;

  if (reverted.data?.errorName) {
    const args = reverted.data.args ?? [];
    return { name: reverted.data.errorName, args, reason: reverted.data.errorName === "Error" ? String(args[0]) : undefined };
  }
  // A contract called by LoanManager reverted with an error LoanManager does not declare, so try the other ABI.
  if (reverted.raw) {
    try {
      const decoded = decodeErrorResult({ abi: knownAbi, data: reverted.raw as Hex });
      return { name: decoded.errorName, args: (decoded.args ?? []) as Args };
    } catch {
      return { name: reverted.signature ?? reverted.raw.slice(0, 10), args: [], reason: reverted.reason };
    }
  }
  return { name: reverted.signature ?? "unknown error", args: [], reason: reverted.reason };
}

function isRejection(error: unknown): boolean {
  if (error instanceof BaseError) {
    if (error.walk((inner) => inner instanceof UserRejectedRequestError)) return true;
  }
  const code = (error as { code?: unknown } | null)?.code;
  if (code === 4001 || code === "ACTION_REJECTED") return true;
  const message = error instanceof Error ? error.message : String(error);
  return /user rejected|user denied|rejected the request|request rejected/i.test(message);
}

/** Every message in the chain of causes, so the node's own words are found under viem's generic ones. */
function allText(error: unknown): string {
  const parts: string[] = [];
  let current: unknown = error;
  for (let depth = 0; depth < 8 && current; depth++) {
    if (current instanceof Error) parts.push(current.message);
    const inner = current as { shortMessage?: string; details?: string; cause?: unknown };
    if (inner.shortMessage) parts.push(inner.shortMessage);
    if (inner.details) parts.push(inner.details);
    current = inner.cause;
  }
  return parts.join(" ");
}

function isOutOfGas(error: unknown): boolean {
  if (error instanceof BaseError && error.walk((inner) => inner instanceof InsufficientFundsError)) return true;
  return /insufficient funds/i.test(allText(error));
}

// Refusals from the node itself, before anything reaches the chain.
const NODE_REFUSALS: readonly { pattern: RegExp; detail: string }[] = [
  {
    pattern: /intrinsic gas too low|gas too low|gas limit below/i,
    detail: "The node refused the transaction's gas limit. Try again; Doji will estimate it afresh.",
  },
  { pattern: /header not found/i, detail: "A Mezo node was a moment behind. Try again in a few seconds." },
  {
    pattern: /nonce too low|already known/i,
    detail: "This transaction was already sent. Check the explorer before sending it again.",
  },
  {
    pattern: /replacement transaction underpriced/i,
    detail: "A transaction from this wallet is still waiting. Wait for it, then try again.",
  },
];

/** The plain-words text for a failed write, with the title the toast shows. */
export function explainError(error: unknown, context: ErrorContext = {}): Explained {
  const title: Explained["title"] = context.phase === "receipt" ? "Failed" : "Not sent";

  if (error instanceof AppError) {
    return {
      title,
      detail:
        error.kind === "wrongChain"
          ? "Your wallet is on another network. Switch to Mezo testnet and try again."
          : "Connect a wallet first.",
    };
  }
  if (isRejection(error)) {
    return { title: "Not sent", detail: "You cancelled it in your wallet. Nothing was sent." };
  }
  if (isOutOfGas(error)) {
    return { title, detail: "Not enough test BTC to pay for gas. Get some from the Mezo faucet." };
  }
  const refusal = NODE_REFUSALS.find((candidate) => candidate.pattern.test(allText(error)));
  if (refusal) return { title, detail: refusal.detail };

  const revert = findRevert(error);
  if (revert) {
    const known = REVERTS[revert.name];
    if (known) return { title, detail: known(revert.args), refresh: REFRESH.has(revert.name) || undefined };
    if (context.action === "lock") {
      return { title, detail: `Mezo's veBTC refused the lock: ${revert.reason ?? revert.name}.` };
    }
    return { title, detail: `The transaction would fail: ${revert.name}.` };
  }

  if (context.phase === "receipt") {
    return { title, detail: "The transaction was sent but failed on chain. Open it on the explorer to see why." };
  }
  const short = error instanceof BaseError ? error.shortMessage : error instanceof Error ? error.message : String(error);
  return { title, detail: `The transaction would fail: ${short.split("\n")[0]?.slice(0, 160) ?? "unknown error"}.` };
}

/** The sentence for a mined transaction that reverted, from the revert data when it could be found. */
export function explainReverted(data: Hex | null): Explained {
  if (data) {
    try {
      const decoded = decodeErrorResult({ abi: knownAbi, data });
      const known = REVERTS[decoded.errorName];
      return {
        title: "Failed",
        detail: known ? known((decoded.args ?? []) as Args) : `The transaction failed: ${decoded.errorName}.`,
      };
    } catch {
      // The data is not one of Doji's errors, so the plain sentence below is used.
    }
  }
  return { title: "Failed", detail: "The transaction was sent but failed on chain. Open it on the explorer to see why." };
}

/** What the connect modal says when a wallet does not connect. */
export function explainConnectError(error: unknown): string {
  if (isRejection(error)) return "The wallet closed the request. Try again.";
  const message = error instanceof BaseError ? error.shortMessage : error instanceof Error ? error.message : String(error);
  return `This wallet could not connect: ${message.split("\n")[0]?.slice(0, 160) ?? "unknown error"}`;
}

export type Problem =
  | { kind: "paused" }
  | { kind: "belowMin"; minLoan: bigint }
  | { kind: "overLimit"; maxFace: bigint }
  | { kind: "overOffers"; most: bigint }
  | { kind: "tooManyOffers" }
  | { kind: "lockEndsBefore" }
  | { kind: "noBalance"; balance: bigint }
  | { kind: "noPrice" };

/** The reasons the Borrow button can give before anything is sent, in the same words the contract errors use. */
export function explainProblem(problem: Problem): string {
  switch (problem.kind) {
    case "paused":
      return REVERTS.BorrowsPaused?.([]) ?? "";
    case "belowMin":
      return `The minimum loan is ${musd(problem.minLoan)} MUSD.`;
    case "overLimit":
      return `That's more than this collateral allows. The most you can owe is ${musd(problem.maxFace)} MUSD.`;
    case "overOffers":
      return `The offers at that date can fill at most ${musd(problem.most)} MUSD.`;
    case "tooManyOffers":
      return "A loan can use at most 8 offers. Borrow a little less.";
    case "lockEndsBefore":
      return "Your lock ends before that Thursday. Pick an earlier date or extend the lock.";
    case "noBalance":
      return `You don't have that much test BTC. Your balance is ${Number(formatUnits(problem.balance, 18)).toFixed(4)} BTC.`;
    case "noPrice":
      return "Mezo's price feed is more than 60 seconds old right now. Try again in a minute.";
  }
}

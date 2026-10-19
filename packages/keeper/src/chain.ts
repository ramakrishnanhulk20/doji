import {
  BaseError,
  ContractFunctionRevertedError,
  HttpRequestError,
  LimitExceededRpcError,
  TimeoutError,
  createPublicClient,
  createWalletClient,
  getAbiItem,
  http,
  type Address,
  type HttpTransport,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { mezoTestnet } from "viem/chains";
import type { Config } from "./config.js";

export const LOG_PAGE_BLOCKS = 5_000n;
const REQUEST_TIMEOUT_MS = 20_000;
const RETRY_DELAY_MS = 3_000;
const MAX_TEXT = 240;

// Copied from the forge-compiled ABIs of src/interfaces/ILoanManager.sol (plus LockReader's two errors, which
// lockOf and isUnsafe can revert with), src/interfaces/ICreditMarkets.sol and src/interfaces/IVeBTC.sol, trimmed
// to what the keeper calls. Every custom error is kept so a failed simulation prints its name.
export const loanManagerAbi = [
  {"type": "function", "name": "auctionOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "auction", "type": "tuple", "components": [{"name": "startTime", "type": "uint64"}, {"name": "duration", "type": "uint32"}, {"name": "penaltyBps", "type": "uint16"}, {"name": "startValue", "type": "uint128"}, {"name": "floorPrice", "type": "uint128"}]}], "stateMutability": "view"},
  {"type": "function", "name": "cancelAuction", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "creditMarkets", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "isOverdue", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "overdue", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "isUnsafe", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "unsafe", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "loanOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "loan", "type": "tuple", "components": [{"name": "maturity", "type": "uint64"}, {"name": "face", "type": "uint128"}, {"name": "repaid", "type": "uint128"}, {"name": "maxLtvBps", "type": "uint16"}, {"name": "liqLtvBps", "type": "uint16"}, {"name": "state", "type": "uint8"}]}], "stateMutability": "view"},
  {"type": "function", "name": "lockOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "amount", "type": "uint256"}, {"name": "end", "type": "uint256"}, {"name": "isPermanent", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "prepareSettle", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "settle", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "startAuction", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "veBTC", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "event", "name": "Borrowed", "inputs": [{"name": "tokenId", "type": "uint256", "indexed": true}, {"name": "borrower", "type": "address", "indexed": true}, {"name": "maturity", "type": "uint64", "indexed": true}, {"name": "principal", "type": "uint256", "indexed": false}, {"name": "face", "type": "uint256", "indexed": false}], "anonymous": false},
  {"type": "error", "name": "AuctionParamsOutOfBounds", "inputs": [{"name": "penaltyBps", "type": "uint16"}, {"name": "auctionFloorBps", "type": "uint16"}, {"name": "auctionDuration", "type": "uint32"}]},
  {"type": "error", "name": "BadLockLayout", "inputs": [{"name": "layoutWords", "type": "uint256"}]},
  {"type": "error", "name": "BadRewardTokenCount", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "BadVoteCount", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "BelowMinLoan", "inputs": [{"name": "principal", "type": "uint256"}, {"name": "minLoan", "type": "uint256"}]},
  {"type": "error", "name": "BorrowsPaused", "inputs": []},
  {"type": "error", "name": "BtcMismatch", "inputs": []},
  {"type": "error", "name": "CollateralNotAccepted", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "CreditMarketsMismatch", "inputs": []},
  {"type": "error", "name": "CustodyCheckFailed", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "DeadlinePassed", "inputs": [{"name": "deadline", "type": "uint256"}]},
  {"type": "error", "name": "DuplicateVoter", "inputs": []},
  {"type": "error", "name": "FloorTimeNotReached", "inputs": [{"name": "tokenId", "type": "uint256"}, {"name": "floorTime", "type": "uint256"}]},
  {"type": "error", "name": "InvalidMaturity", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "LengthMismatch", "inputs": []},
  {"type": "error", "name": "LoanInAuction", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LoanNotActive", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LoanOpen", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LoanOverdue", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LoanUnsafe", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LockIsPermanent", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "LockNotEnded", "inputs": [{"name": "tokenId", "type": "uint256"}, {"name": "lockEnd", "type": "uint256"}]},
  {"type": "error", "name": "LtvTooHigh", "inputs": [{"name": "face", "type": "uint256"}, {"name": "maxFace", "type": "uint256"}]},
  {"type": "error", "name": "MaturityAfterLockEnd", "inputs": [{"name": "maturity", "type": "uint64"}, {"name": "lockEnd", "type": "uint256"}]},
  {"type": "error", "name": "MaturityBeyondMaxTerm", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "MaturityNotLater", "inputs": [{"name": "oldMaturity", "type": "uint64"}, {"name": "newMaturity", "type": "uint64"}]},
  {"type": "error", "name": "MaxVotesOutOfBounds", "inputs": [{"name": "maxVotes", "type": "uint16"}]},
  {"type": "error", "name": "MinLoanOutOfBounds", "inputs": [{"name": "minLoan", "type": "uint128"}]},
  {"type": "error", "name": "MusdMismatch", "inputs": []},
  {"type": "error", "name": "NoActiveLoan", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NoAuction", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotBorrower", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotGuardianOrOwner", "inputs": []},
  {"type": "error", "name": "NotInCustody", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotLiquidatable", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotTokenOwner", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NothingToClaim", "inputs": [{"name": "account", "type": "address"}]},
  {"type": "error", "name": "NothingToPrepare", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "PositionExists", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "PriceAboveMax", "inputs": [{"name": "price", "type": "uint256"}, {"name": "maxPay", "type": "uint256"}]},
  {"type": "error", "name": "PriceUnavailable", "inputs": []},
  {"type": "error", "name": "RescueExceedsSurplus", "inputs": [{"name": "token", "type": "address"}, {"name": "amount", "type": "uint256"}, {"name": "surplus", "type": "uint256"}]},
  {"type": "error", "name": "RiskParamsOutOfBounds", "inputs": [{"name": "maxLtvBps", "type": "uint16"}, {"name": "liqLtvBps", "type": "uint16"}]},
  {"type": "error", "name": "StillInCustody", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "StillSafe", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "StillUnsafe", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "StillVoted", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "TokenNotRescuable", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "TokenNotWhitelisted", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "TopUpTooHigh", "inputs": [{"name": "topUp", "type": "uint256"}, {"name": "maxTopUp", "type": "uint256"}]},
  {"type": "error", "name": "TransferShortfall", "inputs": [{"name": "expected", "type": "uint256"}, {"name": "received", "type": "uint256"}]},
  {"type": "error", "name": "UnknownGauge", "inputs": [{"name": "gauge", "type": "address"}]},
  {"type": "error", "name": "VoteTooLate", "inputs": [{"name": "tokenId", "type": "uint256"}, {"name": "lockEnd", "type": "uint256"}]},
  {"type": "error", "name": "ZeroAddress", "inputs": []},
  {"type": "error", "name": "ZeroAmount", "inputs": []},
  {"type": "error", "name": "BadLockAmount", "inputs": []},
  {"type": "error", "name": "LockReadFailed", "inputs": []},
] as const;

export const creditMarketsAbi = [
  {"type": "function", "name": "finalize", "inputs": [{"name": "maturity", "type": "uint64"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "loanManager", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "marketOf", "inputs": [{"name": "maturity", "type": "uint64"}], "outputs": [{"name": "", "type": "tuple", "components": [{"name": "faceTotal", "type": "uint128"}, {"name": "collectedMusd", "type": "uint128"}, {"name": "openLoans", "type": "uint64"}, {"name": "isFinal", "type": "bool"}, {"name": "unitsAtFinal", "type": "uint128"}, {"name": "musdAtFinal", "type": "uint128"}, {"name": "collectedBtc", "type": "uint128"}, {"name": "btcAtFinal", "type": "uint128"}]}], "stateMutability": "view"},
  {"type": "error", "name": "AprAboveMax", "inputs": [{"name": "offerId", "type": "uint256"}, {"name": "aprBps", "type": "uint16"}, {"name": "maxAprBps", "type": "uint16"}]},
  {"type": "error", "name": "AprTooHigh", "inputs": [{"name": "aprBps", "type": "uint16"}]},
  {"type": "error", "name": "BadFillCount", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "EmptyMarket", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "FeeShareOutOfBounds", "inputs": [{"name": "feeShareBps", "type": "uint16"}]},
  {"type": "error", "name": "InsufficientRemaining", "inputs": [{"name": "offerId", "type": "uint256"}, {"name": "remaining", "type": "uint128"}, {"name": "amount", "type": "uint128"}]},
  {"type": "error", "name": "InvalidMaturity", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "LengthMismatch", "inputs": []},
  {"type": "error", "name": "LoansStillOpen", "inputs": [{"name": "maturity", "type": "uint64"}, {"name": "openLoans", "type": "uint64"}]},
  {"type": "error", "name": "MarketIsFinal", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "MaxTermOutOfBounds", "inputs": [{"name": "maxTermSeconds", "type": "uint32"}]},
  {"type": "error", "name": "MinOfferOutOfBounds", "inputs": [{"name": "minOffer", "type": "uint128"}]},
  {"type": "error", "name": "NoOpenLoans", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "NotFinal", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "NotGuardianOrOwner", "inputs": []},
  {"type": "error", "name": "NotLoanManager", "inputs": []},
  {"type": "error", "name": "NotMaker", "inputs": [{"name": "offerId", "type": "uint256"}]},
  {"type": "error", "name": "NotMatured", "inputs": [{"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "NothingToClaim", "inputs": [{"name": "account", "type": "address"}, {"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "OfferEmpty", "inputs": [{"name": "offerId", "type": "uint256"}]},
  {"type": "error", "name": "OfferNotFound", "inputs": [{"name": "offerId", "type": "uint256"}]},
  {"type": "error", "name": "OfferTooSmall", "inputs": [{"name": "amount", "type": "uint128"}, {"name": "minOffer", "type": "uint128"}]},
  {"type": "error", "name": "OffersPaused", "inputs": []},
  {"type": "error", "name": "TokenNotRescuable", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "TransferMismatch", "inputs": [{"name": "expected", "type": "uint256"}, {"name": "received", "type": "uint256"}]},
  {"type": "error", "name": "WrongMaturity", "inputs": [{"name": "offerId", "type": "uint256"}, {"name": "offerMaturity", "type": "uint64"}, {"name": "maturity", "type": "uint64"}]},
  {"type": "error", "name": "ZeroAddress", "inputs": []},
  {"type": "error", "name": "ZeroAmount", "inputs": []},
] as const;

export const veBtcAbi = [
  {"type": "function", "name": "voted", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "", "type": "bool"}], "stateMutability": "view"},
] as const;

const borrowedEvent = getAbiItem({ abi: loanManagerAbi, name: "Borrowed" });

export type Reader = PublicClient<HttpTransport, typeof mezoTestnet>;
export type Writer = WalletClient<HttpTransport, typeof mezoTestnet, PrivateKeyAccount>;

export interface Clients {
  reader: Reader;
  writer: Writer | undefined;
  account: PrivateKeyAccount | undefined;
}

// Retries are off in the transport so that the one retry the log pager allows is the only one, and a slow
// node fails a read instead of stalling the run.
export function makeClients(config: Config): Clients {
  const transport = http(config.rpcUrl, { retryCount: 0, timeout: REQUEST_TIMEOUT_MS });
  const reader = createPublicClient({ chain: mezoTestnet, transport });
  const account = config.privateKey === undefined ? undefined : privateKeyToAccount(config.privateKey);
  const writer =
    config.dry || account === undefined ? undefined : createWalletClient({ chain: mezoTestnet, transport, account });
  return { reader, writer, account };
}

export interface BorrowedLog {
  tokenId: bigint;
  maturity: bigint;
}

function isRateLimitOrTimeout(err: unknown): boolean {
  if (!(err instanceof BaseError)) return false;
  return (
    err.walk(
      (e) =>
        e instanceof TimeoutError ||
        e instanceof LimitExceededRpcError ||
        (e instanceof HttpRequestError && e.status === 429),
    ) !== null
  );
}

async function withOneRetry<T>(label: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    if (!isRateLimitOrTimeout(err)) throw err;
    console.log(`rate limited or timed out on ${label}; retrying once in ${RETRY_DELAY_MS / 1000}s`);
    await new Promise((done) => setTimeout(done, RETRY_DELAY_MS));
    return run();
  }
}

// Every Borrowed event LoanManager emitted in [fromBlock, toBlock], read in pages of LOG_PAGE_BLOCKS blocks.
// A page that still fails after its one retry stops the pass: acting on a partial loan list would quietly
// skip loans.
export async function fetchBorrowedLogs(
  reader: Reader,
  loanManager: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<BorrowedLog[]> {
  const found: BorrowedLog[] = [];
  for (let start = fromBlock; start <= toBlock; start += LOG_PAGE_BLOCKS) {
    const end = start + LOG_PAGE_BLOCKS - 1n < toBlock ? start + LOG_PAGE_BLOCKS - 1n : toBlock;
    const logs = await withOneRetry(`Borrowed logs for blocks ${start} to ${end}`, () =>
      reader.getLogs({ address: loanManager, event: borrowedEvent, fromBlock: start, toBlock: end, strict: true }),
    );
    for (const log of logs) found.push({ tokenId: log.args.tokenId, maturity: log.args.maturity });
  }
  return found;
}

// Revert reasons and node messages can carry text a stranger chose. Control characters and line breaks are
// removed so nothing printed can start a new log line, which on GitHub Actions could read as a workflow command.
export function plainText(value: string): string {
  const flat = value.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").trim();
  return flat.length > MAX_TEXT ? `${flat.slice(0, MAX_TEXT)}...` : flat;
}

// The revert as ErrorName(args) when the ABI knows it, otherwise viem's one-line summary. Never the full
// message, which repeats the RPC URL.
export function describeError(err: unknown): string {
  if (err instanceof BaseError) {
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      if (reverted.data?.errorName) {
        const args = (reverted.data.args ?? []).map((a) => String(a)).join(", ");
        return plainText(`${reverted.data.errorName}(${args})`);
      }
      if (reverted.signature) return plainText(`unknown error ${reverted.signature}`);
      if (reverted.reason) return plainText(`reverted: ${reverted.reason}`);
    }
    return plainText(err.shortMessage);
  }
  return plainText(err instanceof Error ? err.message : String(err));
}

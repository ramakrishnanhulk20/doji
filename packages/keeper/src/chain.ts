import {
  BaseError,
  ContractFunctionRevertedError,
  HttpRequestError,
  LimitExceededRpcError,
  TimeoutError,
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  getAbiItem,
  getAddress,
  hexToBigInt,
  hexToNumber,
  http,
  isAddress,
  isAddressEqual,
  isHex,
  nonceManager,
  toEventSelector,
  type Address,
  type Hex,
  type HttpTransport,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { mezoTestnet } from "viem/chains";
import type { Config } from "./config.js";

// Mezo's public RPC refuses eth_getLogs over a from-to distance above 10,000 blocks.
export const LOG_PAGE_BLOCKS = 10_000n;
// The explorer returns at most 1,000 logs per call, so each event listing reads up to about 20,000 events.
export const MAX_EXPLORER_CALLS = 20;
// 640,000 blocks, about 35 days at 4.8 s per block: what the RPC alone covers while the explorer is down.
export const MAX_RPC_FALLBACK_PAGES = 64n;
// Open loans past this wait for a later pass; the ones due first are read first. Each loan is about three
// sequential reads at roughly 0.5 s on the public RPC, so 150 keeps a pass near 4 minutes inside the 10-minute job.
export const MAX_POSITIONS_PER_RUN = 150;
// The weekly loan dates one pass checks and finalizes, the most recent first: about 7 months of dates.
export const MAX_MATURITIES_PER_RUN = 32;
const EXPLORER_PAGE_LOGS = 1_000;
const REQUEST_TIMEOUT_MS = 20_000;
const RETRY_DELAY_MS = 3_000;
const MAX_TEXT = 240;

// Copied from the forge-compiled ABIs of src/interfaces/ILoanManager.sol (plus LockReader's two errors, which
// lockOf and isUnsafe can revert with), src/interfaces/ICreditMarkets.sol and src/interfaces/IVeBTC.sol, trimmed
// to what the keeper calls. Every custom error is kept so a failed simulation prints its name. The Wave 2 entries
// (positionOf, RewardOperatorSet, savingsVault, parkedPrincipal and the ABIs after veBtcAbi) are written by hand
// from the same interfaces, because the compiled out/ folder predates them; each read was checked live on
// 2026-11-04.
export const loanManagerAbi = [
  {"type": "function", "name": "auctionOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "auction", "type": "tuple", "components": [{"name": "startTime", "type": "uint64"}, {"name": "duration", "type": "uint32"}, {"name": "penaltyBps", "type": "uint16"}, {"name": "startValue", "type": "uint128"}, {"name": "floorPrice", "type": "uint128"}]}], "stateMutability": "view"},
  {"type": "function", "name": "cancelAuction", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "creditMarkets", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "guardian", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "isOverdue", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "overdue", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "isUnsafe", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "unsafe", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "loanOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "loan", "type": "tuple", "components": [{"name": "maturity", "type": "uint64"}, {"name": "face", "type": "uint128"}, {"name": "repaid", "type": "uint128"}, {"name": "maxLtvBps", "type": "uint16"}, {"name": "liqLtvBps", "type": "uint16"}, {"name": "penaltyBps", "type": "uint16"}, {"name": "auctionFloorBps", "type": "uint16"}, {"name": "auctionDuration", "type": "uint32"}, {"name": "state", "type": "uint8"}]}], "stateMutability": "view"},
  {"type": "function", "name": "lockOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "amount", "type": "uint256"}, {"name": "end", "type": "uint256"}, {"name": "isPermanent", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "owner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "pendingOwner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "poolsVoter", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "positionOf", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "position", "type": "tuple", "components": [{"name": "borrower", "type": "address"}, {"name": "rewardOperator", "type": "address"}]}], "stateMutability": "view"},
  {"type": "function", "name": "prepareSettle", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "settle", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "startAuction", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "function", "name": "veBTC", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "event", "name": "Borrowed", "inputs": [{"name": "tokenId", "type": "uint256", "indexed": true}, {"name": "borrower", "type": "address", "indexed": true}, {"name": "maturity", "type": "uint64", "indexed": true}, {"name": "principal", "type": "uint256", "indexed": false}, {"name": "face", "type": "uint256", "indexed": false}], "anonymous": false},
  {"type": "event", "name": "LoanClosed", "inputs": [{"name": "tokenId", "type": "uint256", "indexed": true}, {"name": "maturity", "type": "uint64", "indexed": true}], "anonymous": false},
  {"type": "event", "name": "RewardOperatorSet", "inputs": [{"name": "tokenId", "type": "uint256", "indexed": true}, {"name": "operator", "type": "address", "indexed": true}], "anonymous": false},
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
  {"type": "function", "name": "guardian", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "loanManager", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "marketOf", "inputs": [{"name": "maturity", "type": "uint64"}], "outputs": [{"name": "", "type": "tuple", "components": [{"name": "faceTotal", "type": "uint128"}, {"name": "collectedMusd", "type": "uint128"}, {"name": "openLoans", "type": "uint64"}, {"name": "isFinal", "type": "bool"}, {"name": "unitsAtFinal", "type": "uint128"}, {"name": "musdAtFinal", "type": "uint128"}, {"name": "collectedBtc", "type": "uint128"}, {"name": "btcAtFinal", "type": "uint128"}]}], "stateMutability": "view"},
  {"type": "function", "name": "maxTermSeconds", "inputs": [], "outputs": [{"name": "", "type": "uint32"}], "stateMutability": "view"},
  {"type": "function", "name": "owner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "parkedPrincipal", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
  {"type": "function", "name": "pendingOwner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "savingsVault", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "treasury", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "error", "name": "NothingParked", "inputs": []},
  {"type": "error", "name": "ParkingOff", "inputs": []},
  {"type": "error", "name": "RenounceDisabled", "inputs": []},
  {"type": "error", "name": "VaultShortfall", "inputs": [{"name": "expected", "type": "uint256"}, {"name": "actual", "type": "uint256"}]},
  {"type": "error", "name": "VaultTokenMismatch", "inputs": [{"name": "vaultToken", "type": "address"}]},
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

// src/interfaces/IPayDown.sol, plus the LoanManager errors its claim and repay can bubble up, so a refused
// harvest prints its reason.
export const payDownAbi = [
  {"type": "function", "name": "btc", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "guardian", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "harvest", "inputs": [{"name": "tokenId", "type": "uint256"}, {"name": "gauges", "type": "address[]"}, {"name": "feeTokens", "type": "address[][]"}, {"name": "bribeTokens", "type": "address[][]"}], "outputs": [{"name": "repaid", "type": "uint256"}], "stateMutability": "nonpayable"},
  {"type": "function", "name": "loanManager", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "musd", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "owner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "paused", "inputs": [], "outputs": [{"name": "", "type": "bool"}], "stateMutability": "view"},
  {"type": "function", "name": "pendingOwner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "priceFeed", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "error", "name": "BadRoute", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "BadSwapToken", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "BelowFloor", "inputs": [{"name": "received", "type": "uint256"}, {"name": "floor", "type": "uint256"}]},
  {"type": "error", "name": "DuplicateToken", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "HarvestsPaused", "inputs": []},
  {"type": "error", "name": "LengthMismatch", "inputs": []},
  {"type": "error", "name": "NotBorrower", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotGuardianOrOwner", "inputs": []},
  {"type": "error", "name": "PriceUnavailable", "inputs": []},
  {"type": "error", "name": "RenounceDisabled", "inputs": []},
  {"type": "error", "name": "SlippageTooHigh", "inputs": [{"name": "slippageBps", "type": "uint16"}]},
  {"type": "error", "name": "TooManySwaps", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "TooManyTokens", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "ZeroAddress", "inputs": []},
  {"type": "error", "name": "ZeroAmount", "inputs": []},
  {"type": "error", "name": "ZeroMinimum", "inputs": [{"name": "token", "type": "address"}]},
  {"type": "error", "name": "BadRewardTokenCount", "inputs": [{"name": "count", "type": "uint256"}]},
  {"type": "error", "name": "LoanInAuction", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NoActiveLoan", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "NotInCustody", "inputs": [{"name": "tokenId", "type": "uint256"}]},
  {"type": "error", "name": "TokenNotReward", "inputs": [{"name": "rewardContract", "type": "address"}, {"name": "token", "type": "address"}]},
  {"type": "error", "name": "TransferShortfall", "inputs": [{"name": "expected", "type": "uint256"}, {"name": "received", "type": "uint256"}]},
  {"type": "error", "name": "UnknownGauge", "inputs": [{"name": "gauge", "type": "address"}]},
] as const;

// src/interfaces/IUnitMarket.sol, the reads the role and record checks make.
export const unitMarketAbi = [
  {"type": "function", "name": "creditMarkets", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "guardian", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "owner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "pendingOwner", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "treasury", "inputs": [], "outputs": [{"name": "", "type": "address"}], "stateMutability": "view"},
] as const;

// src/interfaces/IMUSDSavingsRate.sol, with the vault's own errors from reference/briefs/smusd-brief.md so a VAULT
// ALERT names the reason (InsufficientBalance() is 0xf4d678b8).
export const savingsVaultAbi = [
  {"type": "function", "name": "withdraw", "inputs": [{"name": "amount", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
  {"type": "error", "name": "AmountTooSmall", "inputs": []},
  {"type": "error", "name": "InsufficientBalance", "inputs": []},
  {"type": "error", "name": "SameStrategy", "inputs": []},
  {"type": "error", "name": "ZeroAddress", "inputs": []},
  {"type": "error", "name": "ZeroAmount", "inputs": []},
] as const;

// PoolsVoter's public poolVote array and gauges mapping, and the two lookups in src/interfaces/IPoolsVoter.sol.
// poolVote reverts past the end of a position's list, which is how the list's length is found.
export const poolsVoterAbi = [
  {"type": "function", "name": "gaugeToBribe", "inputs": [{"name": "gauge", "type": "address"}], "outputs": [{"name": "bribe", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "gaugeToFees", "inputs": [{"name": "gauge", "type": "address"}], "outputs": [{"name": "fees", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "gauges", "inputs": [{"name": "pool", "type": "address"}], "outputs": [{"name": "gauge", "type": "address"}], "stateMutability": "view"},
  {"type": "function", "name": "poolVote", "inputs": [{"name": "tokenId", "type": "uint256"}, {"name": "index", "type": "uint256"}], "outputs": [{"name": "pool", "type": "address"}], "stateMutability": "view"},
] as const;

// src/interfaces/IVotingReward.sol, plus earned from Mezo's Reward base: what a claim would pay this tokenId now.
export const votingRewardAbi = [
  {"type": "function", "name": "earned", "inputs": [{"name": "token", "type": "address"}, {"name": "tokenId", "type": "uint256"}], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
  {"type": "function", "name": "isReward", "inputs": [{"name": "token", "type": "address"}], "outputs": [{"name": "listed", "type": "bool"}], "stateMutability": "view"},
] as const;

// src/interfaces/IPriceFeed.sol. USD per BTC with 18 decimals; reverts when the oracle is over 60 seconds old.
export const priceFeedAbi = [
  {"type": "function", "name": "fetchPrice", "inputs": [], "outputs": [{"name": "", "type": "uint256"}], "stateMutability": "view"},
] as const;

const borrowedEvent = getAbiItem({ abi: loanManagerAbi, name: "Borrowed" });
const loanClosedEvent = getAbiItem({ abi: loanManagerAbi, name: "LoanClosed" });
const loanEvents = [borrowedEvent, loanClosedEvent] as const;
export type LoanEventName = (typeof loanEvents)[number]["name"];
const eventTopics: Record<LoanEventName, string> = {
  Borrowed: toEventSelector(borrowedEvent).toLowerCase(),
  LoanClosed: toEventSelector(loanClosedEvent).toLowerCase(),
};
const operatorEvent = getAbiItem({ abi: loanManagerAbi, name: "RewardOperatorSet" });
const operatorTopic = toEventSelector(operatorEvent).toLowerCase();

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
  // A lagging node behind rpc.test.mezo.org can report the nonce from before the last confirmed send, which got the
  // second of two sends in one pass rejected on 2026-10-22. The nonce manager never reuses a nonce it has handed out.
  const account =
    config.privateKey === undefined ? undefined : privateKeyToAccount(config.privateKey, { nonceManager });
  const writer =
    config.dry || account === undefined ? undefined : createWalletClient({ chain: mezoTestnet, transport, account });
  return { reader, writer, account };
}

// One Borrowed or LoanClosed event. (blockNumber, logIndex) orders them, which matters because roll emits
// LoanClosed for the old loan and then Borrowed for the new one in the same transaction.
export interface LoanLog {
  event: LoanEventName;
  tokenId: bigint;
  maturity: bigint;
  blockNumber: bigint;
  logIndex: number;
}

// One RewardOperatorSet event: a borrower named `operator` (zero for none) as the position's reward operator.
export interface OperatorLog {
  tokenId: bigint;
  operator: Address;
  blockNumber: bigint;
  logIndex: number;
}

// True when the node ran the call and the contract reverted, as opposed to the request failing. Only that case
// may be read as an answer (the end of a list, a function the contract does not have); any other failure is a
// failed read.
export function isRevert(err: unknown): boolean {
  return err instanceof BaseError && err.walk((e) => e instanceof ContractFunctionRevertedError) !== null;
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

export async function withOneRetry<T>(label: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    if (!isRateLimitOrTimeout(err)) throw err;
    console.log(`rate limited or timed out on ${label}; retrying once in ${RETRY_DELAY_MS / 1000}s`);
    await new Promise((done) => setTimeout(done, RETRY_DELAY_MS));
    return run();
  }
}

// Every Borrowed and LoanClosed event LoanManager emitted in [fromBlock, toBlock], both events in one request per
// page of LOG_PAGE_BLOCKS blocks. A page that still fails after its one retry stops the pass: acting on a partial
// loan list would quietly skip loans.
export async function fetchLoanLogs(
  reader: Reader,
  loanManager: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<LoanLog[]> {
  const found: LoanLog[] = [];
  for (let start = fromBlock; start <= toBlock; start += LOG_PAGE_BLOCKS) {
    const end = start + LOG_PAGE_BLOCKS - 1n < toBlock ? start + LOG_PAGE_BLOCKS - 1n : toBlock;
    const logs = await withOneRetry(`loan events for blocks ${start} to ${end}`, () =>
      reader.getLogs({ address: loanManager, events: loanEvents, fromBlock: start, toBlock: end, strict: true }),
    );
    for (const log of logs) {
      found.push({
        event: log.eventName,
        tokenId: log.args.tokenId,
        maturity: log.args.maturity,
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
      });
    }
  }
  return found;
}

// Every RewardOperatorSet event LoanManager emitted in [fromBlock, toBlock], paged and retried like the loan events.
export async function fetchOperatorLogs(
  reader: Reader,
  loanManager: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<OperatorLog[]> {
  const found: OperatorLog[] = [];
  for (let start = fromBlock; start <= toBlock; start += LOG_PAGE_BLOCKS) {
    const end = start + LOG_PAGE_BLOCKS - 1n < toBlock ? start + LOG_PAGE_BLOCKS - 1n : toBlock;
    const logs = await withOneRetry(`operator events for blocks ${start} to ${end}`, () =>
      reader.getLogs({ address: loanManager, event: operatorEvent, fromBlock: start, toBlock: end, strict: true }),
    );
    for (const log of logs) {
      found.push({
        tokenId: log.args.tokenId,
        operator: getAddress(log.args.operator),
        blockNumber: log.blockNumber,
        logIndex: log.logIndex,
      });
    }
  }
  return found;
}

const isHexString = (v: unknown): v is Hex => typeof v === "string" && isHex(v, { strict: true });
const isQuantity = (v: unknown): v is Hex => isHexString(v) && v.length > 2;
const isWord = (v: unknown): v is Hex => isHexString(v) && v.length === 66;

// Blockscout pads topics to four entries with null, so trailing nulls are dropped; any other entry must be a word.
function explorerTopics(raw: unknown): Hex[] | undefined {
  if (!Array.isArray(raw) || raw.length > 4) return undefined;
  let end = raw.length;
  while (end > 0 && raw[end - 1] === null) end -= 1;
  const topics = raw.slice(0, end);
  return topics.length > 0 && topics.every(isWord) ? topics : undefined;
}

interface ExplorerLog {
  topics: [Hex, ...Hex[]];
  data: Hex;
  blockNumber: bigint;
  logIndex: number;
  key: string;
}

// One explorer log's envelope, checked like any other input: it must come from `address` and carry the topic of
// the event being listed. The caller then decodes it strictly against that event's ABI item. Anything else is
// dropped.
function explorerLog(raw: unknown, address: Address, topic0: string): ExplorerLog | undefined {
  if (typeof raw !== "object" || raw === null) return undefined;
  const { address: emitter, topics: rawTopics, data, blockNumber, logIndex, transactionHash } = raw as Record<string, unknown>;
  if (typeof emitter !== "string" || !isAddress(emitter, { strict: false })) return undefined;
  if (!isAddressEqual(emitter, address)) return undefined;
  const topics = explorerTopics(rawTopics);
  if (topics === undefined || topics[0]?.toLowerCase() !== topic0) return undefined;
  if (!isHexString(data) || !isQuantity(blockNumber) || !isQuantity(logIndex) || !isWord(transactionHash)) return undefined;
  try {
    const index = hexToNumber(logIndex);
    return {
      topics: topics as [Hex, ...Hex[]],
      data,
      blockNumber: hexToBigInt(blockNumber),
      logIndex: index,
      key: `${transactionHash.toLowerCase()}:${index}`,
    };
  } catch {
    return undefined;
  }
}

function parseLoanLog(raw: unknown, loanManager: Address, event: LoanEventName): ExplorerItem<LoanLog> | undefined {
  const log = explorerLog(raw, loanManager, eventTopics[event]);
  if (log === undefined) return undefined;
  try {
    const decoded = decodeEventLog({ abi: loanEvents, data: log.data, topics: log.topics, strict: true });
    if (decoded.eventName !== event) return undefined;
    const value = {
      event,
      tokenId: decoded.args.tokenId,
      maturity: decoded.args.maturity,
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
    };
    return { value, blockNumber: log.blockNumber, key: log.key };
  } catch {
    return undefined;
  }
}

function parseOperatorLog(raw: unknown, loanManager: Address): ExplorerItem<OperatorLog> | undefined {
  const log = explorerLog(raw, loanManager, operatorTopic);
  if (log === undefined) return undefined;
  try {
    const decoded = decodeEventLog({ abi: [operatorEvent], data: log.data, topics: log.topics, strict: true });
    const value = {
      tokenId: decoded.args.tokenId,
      operator: getAddress(decoded.args.operator),
      blockNumber: log.blockNumber,
      logIndex: log.logIndex,
    };
    return { value, blockNumber: log.blockNumber, key: log.key };
  } catch {
    return undefined;
  }
}

function explorerFailed(reason: string): null {
  console.log(`explorer call failed: ${plainText(reason)}`);
  return null;
}

// One explorer GET. Anything short of a clean answer with a JSON object body is null, so the caller falls back
// to the RPC.
async function explorerGet(url: URL): Promise<Record<string, unknown> | null> {
  let body: unknown;
  try {
    const res = await fetch(url, { headers: { accept: "application/json" }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
    if (!res.ok) return explorerFailed(`HTTP ${res.status}`);
    body = await res.json();
  } catch (err) {
    if (err instanceof SyntaxError) return explorerFailed("response is not JSON");
    if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) return explorerFailed("timed out");
    return explorerFailed(err instanceof Error ? err.message : String(err));
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) return explorerFailed("response is not a JSON object");
  return body as Record<string, unknown>;
}

async function explorerLogsPage(
  explorerApi: string,
  address: Address,
  topic0: string,
  fromBlock: bigint,
): Promise<unknown[] | null> {
  const url = new URL(explorerApi);
  url.searchParams.set("module", "logs");
  url.searchParams.set("action", "getLogs");
  url.searchParams.set("fromBlock", fromBlock.toString());
  url.searchParams.set("toBlock", "latest");
  url.searchParams.set("address", address);
  url.searchParams.set("topic0", topic0);
  const body = await explorerGet(url);
  if (body === null) return null;
  const { status, message, result } = body;
  if (status === "1" && Array.isArray(result)) return result;
  if (status === "0" && message === "No logs found") return [];
  return explorerFailed(`status ${JSON.stringify(status)}, message ${JSON.stringify(message)}`);
}

// The newest block the explorer has indexed, from its v2 API beside the configured ".../api" base.
export async function fetchExplorerHeight(explorerApi: string): Promise<bigint | null> {
  const url = new URL(explorerApi);
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/v2/blocks`;
  url.searchParams.set("type", "block");
  const body = await explorerGet(url);
  if (body === null) return null;
  const items = body.items;
  const first: unknown = Array.isArray(items) ? items[0] : undefined;
  const height = typeof first === "object" && first !== null ? (first as Record<string, unknown>).height : undefined;
  if (typeof height !== "number" || !Number.isSafeInteger(height) || height < 0) return explorerFailed("no indexed block height");
  return BigInt(height);
}

interface ExplorerItem<T> {
  value: T;
  blockNumber: bigint;
  key: string;
}

export interface ExplorerListing<T> {
  logs: T[];
  // Set when MAX_EXPLORER_CALLS ran out: the listing is complete only below this block.
  cappedAt: bigint | undefined;
}

// Every event of one kind `address` emitted from fromBlock on, as the block explorer has indexed it. A full page
// of 1,000 logs means there may be more, so the next call starts at the last block seen and repeats are dropped.
// The explorer is a hint source only: null on any failed call sends the caller to the RPC rather than acting on
// a partial list, and every object it names is still read from the RPC before anything is decided.
async function listFromExplorer<T>(
  explorerApi: string,
  address: Address,
  topic0: string,
  label: string,
  fromBlock: bigint,
  parse: (raw: unknown) => ExplorerItem<T> | undefined,
): Promise<ExplorerListing<T> | null> {
  const seen = new Set<string>();
  const logs: T[] = [];
  let dropped = 0;
  let cappedAt: bigint | undefined;
  let calls = 0;
  let start = fromBlock;
  for (;;) {
    calls += 1;
    const page = await explorerLogsPage(explorerApi, address, topic0, start);
    if (page === null) return null;
    let added = 0;
    for (const raw of page) {
      const log = parse(raw);
      if (log === undefined) {
        dropped += 1;
        continue;
      }
      if (log.blockNumber > start) start = log.blockNumber;
      if (seen.has(log.key)) continue;
      seen.add(log.key);
      logs.push(log.value);
      added += 1;
    }
    if (page.length < EXPLORER_PAGE_LOGS) break;
    if (calls >= MAX_EXPLORER_CALLS || added === 0) {
      cappedAt = start;
      break;
    }
  }
  if (dropped > 0) console.log(`warning: dropped ${dropped} explorer ${label} logs that failed validation`);
  if (cappedAt !== undefined) {
    console.log(`warning: explorer ${label} listing capped after ${calls} calls at block ${cappedAt}; the RPC reads from there`);
  }
  return { logs, cappedAt };
}

export function fetchLoanEventsFromExplorer(
  explorerApi: string,
  loanManager: Address,
  event: LoanEventName,
  fromBlock: bigint,
): Promise<ExplorerListing<LoanLog> | null> {
  return listFromExplorer(explorerApi, loanManager, eventTopics[event], event, fromBlock, (raw) =>
    parseLoanLog(raw, loanManager, event),
  );
}

export function fetchOperatorEventsFromExplorer(
  explorerApi: string,
  loanManager: Address,
  fromBlock: bigint,
): Promise<ExplorerListing<OperatorLog> | null> {
  return listFromExplorer(explorerApi, loanManager, operatorTopic, "RewardOperatorSet", fromBlock, (raw) =>
    parseOperatorLog(raw, loanManager),
  );
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
    return plainText(err.details ? `${err.shortMessage} (${err.details})` : err.shortMessage);
  }
  return plainText(err instanceof Error ? err.message : String(err));
}

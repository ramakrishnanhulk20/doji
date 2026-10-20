import { parseAbi, type Address, type PublicClient } from "viem";
import { addressBook } from "./addresses";
import { faceOf, type Selection } from "./borrow";

// Small read-only slices, so the compiler does not have to carry the full contract ABIs through every read.
const loanManagerReads = parseAbi([
  "function maxLtvBps() view returns (uint16)",
  "function liqLtvBps() view returns (uint16)",
  "function minLoan() view returns (uint128)",
  "function borrowsPaused() view returns (bool)",
  "function lockOf(uint256 tokenId) view returns (uint256 amount, uint256 end, bool isPermanent)",
]);
const creditMarketsReads = parseAbi([
  "function maxTermSeconds() view returns (uint32)",
  "function quoteFill(uint128 principal, uint16 aprBps, uint64 maturity) view returns (uint256 face, uint256 makerUnits, uint256 treasuryUnits)",
]);
const veBtcReads = parseAbi([
  "function balanceOf(address owner) view returns (uint256)",
  "function ownerToNFTokenIdList(address owner, uint256 index) view returns (uint256)",
  "function escrowType(uint256 tokenId) view returns (uint8)",
  "function grantManager(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
]);
const erc20Reads = parseAbi(["function allowance(address owner, address spender) view returns (uint256)"]);
const priceReads = parseAbi(["function fetchPrice() view returns (uint256)"]);

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const MAX_POSITIONS = 50;
const NORMAL_ESCROW = 0;

const book = addressBook[31611];

export type BorrowSettings = {
  maxLtvBps: number;
  liqLtvBps: number;
  minLoan: bigint;
  borrowsPaused: boolean;
  maxTermSeconds: number;
};

export async function readBorrowSettings(client: PublicClient): Promise<BorrowSettings> {
  const [maxLtvBps, liqLtvBps, minLoan, borrowsPaused, maxTermSeconds] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: book.loanManager, abi: loanManagerReads, functionName: "maxLtvBps" },
      { address: book.loanManager, abi: loanManagerReads, functionName: "liqLtvBps" },
      { address: book.loanManager, abi: loanManagerReads, functionName: "minLoan" },
      { address: book.loanManager, abi: loanManagerReads, functionName: "borrowsPaused" },
      { address: book.creditMarkets, abi: creditMarketsReads, functionName: "maxTermSeconds" },
    ],
  });
  return { maxLtvBps, liqLtvBps, minLoan, borrowsPaused, maxTermSeconds };
}

/** MUSD per BTC, 18 decimals. Reverts when Mezo's oracle is more than 60 seconds old. */
export async function readPrice(client: PublicClient): Promise<bigint> {
  return client.readContract({ address: book.priceFeed, abi: priceReads, functionName: "fetchPrice" });
}

export async function readBtcAllowance(client: PublicClient, owner: Address): Promise<bigint> {
  return client.readContract({
    address: book.btc,
    abi: erc20Reads,
    functionName: "allowance",
    args: [owner, book.loanManager],
  });
}

export type Position = {
  id: bigint;
  /** BTC locked, 18 decimals. */
  amount: bigint;
  /** Unix seconds. */
  end: number;
  isPermanent: boolean;
  /** Normal lock with no grant behind it. Only these can back a loan. */
  accepted: boolean;
  /** getApproved already names LoanManager. */
  approved: boolean;
  /** Doji already holds this position for the wallet and it has no loan, so it needs no approval or deposit. */
  inDoji: boolean;
  /** amount times the oracle price, MUSD, 18 decimals. */
  value: bigint;
};

/** The veBTC positions a wallet owns (at most 50), each with its lock and whether Doji accepts it. */
export async function readPositions(client: PublicClient, owner: Address, price: bigint): Promise<Position[]> {
  const count = await client.readContract({ address: book.veBTC, abi: veBtcReads, functionName: "balanceOf", args: [owner] });
  const wanted = Number(count < BigInt(MAX_POSITIONS) ? count : BigInt(MAX_POSITIONS));
  if (wanted === 0) return [];

  const ids = await client.multicall({
    allowFailure: false,
    contracts: Array.from({ length: wanted }, (_, index) => ({
      address: book.veBTC,
      abi: veBtcReads,
      functionName: "ownerToNFTokenIdList" as const,
      args: [owner, BigInt(index)] as const,
    })),
  });

  const details = await client.multicall({
    allowFailure: false,
    contracts: ids.flatMap((id) => [
      { address: book.loanManager, abi: loanManagerReads, functionName: "lockOf" as const, args: [id] as const },
      { address: book.veBTC, abi: veBtcReads, functionName: "escrowType" as const, args: [id] as const },
      { address: book.veBTC, abi: veBtcReads, functionName: "grantManager" as const, args: [id] as const },
      { address: book.veBTC, abi: veBtcReads, functionName: "getApproved" as const, args: [id] as const },
    ]),
  });

  return ids.map((id, index) => {
    const lock = details[index * 4] as readonly [bigint, bigint, boolean];
    const escrow = details[index * 4 + 1] as number;
    const grant = details[index * 4 + 2] as Address;
    const approvedTo = details[index * 4 + 3] as Address;
    return {
      id,
      amount: lock[0],
      end: Number(lock[1]),
      isPermanent: lock[2],
      accepted: escrow === NORMAL_ESCROW && grant === ZERO_ADDRESS,
      approved: approvedTo.toLowerCase() === book.loanManager.toLowerCase(),
      inDoji: false,
      value: (lock[0] * price) / 10n ** 18n,
    };
  });
}

/** The face CreditMarkets quotes for each pick, in order. Reverts on a date that is not open for loans. */
export async function quoteFaces(client: PublicClient, maturity: number, picks: Pick<Selection, "amounts" | "aprs">): Promise<bigint[]> {
  if (picks.amounts.length === 0) return [];
  const quotes = await client.multicall({
    allowFailure: false,
    contracts: picks.amounts.map((amount, index) => ({
      address: book.creditMarkets,
      abi: creditMarketsReads,
      functionName: "quoteFill" as const,
      args: [amount, picks.aprs[index] ?? 0, BigInt(maturity)] as const,
    })),
  });
  return quotes.map((quote) => quote[0]);
}

export type ConfirmedMax = {
  principal: bigint;
  face: bigint;
};

/**
 * Confirms a local maximum with the contract's own quotes: while the quoted face is above maxFace the principal
 * steps down by 0.01 MUSD, and the offers are re-picked for each smaller amount.
 */
export async function confirmMaxPrincipal(
  client: PublicClient,
  input: {
    maturity: number;
    start: bigint;
    maxFace: bigint;
    pick: (principal: bigint) => Selection;
    step: bigint;
    attempts?: number;
  },
): Promise<ConfirmedMax> {
  let principal = input.start;
  for (let attempt = 0; attempt < (input.attempts ?? 40) && principal > 0n; attempt++) {
    const picks = input.pick(principal);
    const faces = await quoteFaces(client, input.maturity, picks);
    const face = faces.reduce((sum, value) => sum + value, 0n);
    if (face <= input.maxFace) return { principal, face };
    principal -= input.step;
  }
  return { principal: 0n, face: 0n };
}

/** Local stand-in for a quote, used only to pick the first guess before the contract confirms it. */
export function localFace(picks: Pick<Selection, "amounts" | "aprs">, secondsToMaturity: number): bigint {
  return picks.amounts.reduce((sum, amount, index) => sum + faceOf(amount, picks.aprs[index] ?? 0, secondsToMaturity), 0n);
}

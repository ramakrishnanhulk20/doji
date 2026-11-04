import { isAddress, type Address } from "viem";
import { deployment, legacyDeployment } from "../generated/deployment";

type DojiAddresses = {
  /** The Wave 2 pair, where everything new starts. */
  readonly loanManager: Address;
  readonly creditMarkets: Address;
  readonly passThrough: Address;
  readonly payDown: Address;
  readonly unitMarket: Address;
  readonly savingsVault: Address;
  readonly router: Address;
  readonly poolsVoter: Address;
  /** The 20 October pair, kept for the loans, offers, units and claims made on it. */
  readonly legacyLoanManager: Address;
  readonly legacyCreditMarkets: Address;
  readonly musd: Address;
  readonly btc: Address;
  readonly veBTC: Address;
  readonly priceFeed: Address;
  readonly feeDistributor: Address;
};

type MezoAddresses = {
  readonly veBTC: Address;
  readonly priceFeed: Address;
};

export const addressBook: { readonly 31611: DojiAddresses; readonly 31612: MezoAddresses } = {
  31611: {
    loanManager: deployment.loanManager,
    creditMarkets: deployment.creditMarkets,
    passThrough: deployment.passThrough,
    payDown: deployment.payDown,
    unitMarket: deployment.unitMarket,
    savingsVault: deployment.savingsVault,
    router: deployment.router,
    poolsVoter: deployment.poolsVoter,
    legacyLoanManager: legacyDeployment.loanManager,
    legacyCreditMarkets: legacyDeployment.creditMarkets,
    musd: deployment.musd,
    btc: deployment.btc,
    veBTC: deployment.veBTC,
    priceFeed: deployment.priceFeed,
    feeDistributor: deployment.feeDistributor,
  },
  31612: {
    veBTC: "0x3D4b1b884A7a1E59fE8589a3296EC8f8cBB6f279",
    priceFeed: "0xc5aC5A8892230E0A3e1c473881A2de7353fFcA88",
  },
};

export type PairKey = "wave2" | "legacy";

/**
 * One LoanManager and the CreditMarkets it fills from. A loan, an offer or a unit lives in exactly one pair. The ABIs
 * stay out of this record so the landing page, which reads addresses only, does not ship four contract ABIs.
 */
export type Pair = {
  key: PairKey;
  loanManager: Address;
  creditMarkets: Address;
  /** The pair's deployment block: no log of it can be older. */
  fromBlock: bigint;
};

export const wave2Pair: Pair = {
  key: "wave2",
  loanManager: deployment.loanManager,
  creditMarkets: deployment.creditMarkets,
  fromBlock: BigInt(deployment.block),
};

export const legacyPair: Pair = {
  key: "legacy",
  loanManager: legacyDeployment.loanManager,
  creditMarkets: legacyDeployment.creditMarkets,
  fromBlock: BigInt(legacyDeployment.block),
};

/** Wave 2 first: where a list is cut or a tie is broken, the pair new activity goes to wins. */
export const pairs: readonly Pair[] = [wave2Pair, legacyPair];

export const pairOf = (key: PairKey): Pair => (key === "wave2" ? wave2Pair : legacyPair);

// Both sides go through the same lowercasing, so a checksummed and a plain spelling of one address always match.
const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

/** The pair whose LoanManager is `address`, in any letter case. Null for anything else, including a malformed address. */
export function pairByLoanManager(address: Address): Pair | null {
  if (!isAddress(address, { strict: false })) return null;
  return pairs.find((pair) => sameAddress(pair.loanManager, address)) ?? null;
}

/** The pair whose CreditMarkets is `address`, in any letter case. Null for anything else, including a malformed address. */
export function pairByCreditMarkets(address: Address): Pair | null {
  if (!isAddress(address, { strict: false })) return null;
  return pairs.find((pair) => sameAddress(pair.creditMarkets, address)) ?? null;
}

/** The seeded loan the stamp moment reads: its position token and the transaction that opened it. */
export const demoLoan = deployment.demoLoan;

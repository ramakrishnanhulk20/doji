import type { Address } from "viem";
import { deployment } from "../generated/deployment";

type DojiAddresses = {
  readonly loanManager: Address;
  readonly creditMarkets: Address;
  readonly passThrough: Address;
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

/** The seeded loan the stamp moment reads: its position token and the transaction that opened it. */
export const demoLoan = deployment.demoLoan;

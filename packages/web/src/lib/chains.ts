import { defineChain } from "viem";
import { mezo, mezoTestnet } from "viem/chains";

// The testnet entry from viem already points at https://rpc.test.mezo.org and the explorer.
export const mezoTestnetChain = mezoTestnet;

// Mezo's public mainnet RPCs that allow browser requests. On 2026-10-21 dRPC was the only one that held up under
// the fork test suites, and jsonrpc-mezo.boar.network was timing out, so they go first and last.
export const mezoMainnetRpcs = [
  "https://mezo.drpc.org",
  "https://mezo-mainnet.boar.network",
  "https://mainnet.mezo.public.validationcloud.io",
  "https://jsonrpc-mezo.boar.network",
] as const;

export const mezoMainnetChain = defineChain({
  ...mezo,
  rpcUrls: {
    default: { http: mezoMainnetRpcs },
  },
});

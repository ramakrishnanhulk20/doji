import { defineChain } from "viem";
import { mezo, mezoTestnet } from "viem/chains";

// The testnet entry from viem already points at https://rpc.test.mezo.org and the explorer.
export const mezoTestnetChain = mezoTestnet;

// viem's default mainnet RPC is not the one checked for browser access, so only the URL is replaced.
export const mezoMainnetChain = defineChain({
  ...mezo,
  rpcUrls: {
    default: { http: ["https://jsonrpc-mezo.boar.network"] },
  },
});

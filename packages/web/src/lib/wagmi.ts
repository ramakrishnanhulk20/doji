import { createConfig, http, injected } from "wagmi";
import { mezoTestnetChain } from "./chains";

/** The one chain the app writes to. Writes go to the address book entry for this id after the wallet's chain is checked. */
export const APP_CHAIN_ID = mezoTestnetChain.id;

export const wagmiConfig = createConfig({
  chains: [mezoTestnetChain],
  connectors: [injected()],
  // EIP-6963: every browser wallet announces itself, so MetaMask, Rabby and the others show up by name and icon.
  multiInjectedProviderDiscovery: true,
  transports: { [mezoTestnetChain.id]: http(undefined, { batch: true }) },
  ssr: true,
});

// A local signing wallet for development. The dynamic import sits inside a check that is false in a production
// build, so the build contains none of it.
if (typeof window !== "undefined" && process.env.NODE_ENV === "development") {
  void import("./local-signer").then(({ attachLocalSigner }) => attachLocalSigner(wagmiConfig));
}

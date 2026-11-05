import { createConfig, createConnector, http, injected } from "wagmi";
import { walletConnect } from "wagmi/connectors";
import { showToast } from "../components/app/toast-store";
import { mezoTestnetChain } from "./chains";

/** The one chain the app writes to. Writes go to the address book entry for this id after the wallet's chain is checked. */
export const APP_CHAIN_ID = mezoTestnetChain.id;

export const PHONE_WALLET_ID = "walletConnect";

export const ADD_NETWORK_REFUSED =
  "This wallet could not add Mezo testnet. Try MetaMask, or add the network in your wallet and connect again.";

/** Thrown from connect when the wallet paired but refused to add or switch to Mezo testnet. */
export class AddNetworkRefusedError extends Error {
  constructor() {
    super(ADD_NETWORK_REFUSED);
    this.name = "AddNetworkRefusedError";
  }
}

// Fixed text, never read from the page address or the Host header, so a look-alike domain cannot lend its name to a
// wallet's connection prompt.
const SITE_URL = "https://www.dojis.site";
const WALLET_METADATA = {
  name: "Doji",
  description: "Fixed-rate MUSD loans against locked Bitcoin",
  url: SITE_URL,
  icons: [`${SITE_URL}/favicon.svg`],
};

const SESSION_KEY = "walletConnect.hasSession";
const USER_REJECTED_CODE = 4001;

type SessionMemory = {
  getItem(key: string): unknown;
  setItem(key: string, value: unknown): unknown;
  removeItem(key: string): unknown;
};

/**
 * WalletConnect for phone wallets. The stock connector loads WalletConnect's provider as soon as the page starts, and
 * wagmi asks every connector for its provider on each page load. This wrapper keeps the provider unloaded until the
 * person picks the row, or until a WalletConnect session from an earlier visit needs to be picked up again.
 */
function phoneWallet(projectId: string) {
  const stock = walletConnect({
    projectId,
    showQrModal: true,
    qrModalOptions: { themeMode: "dark", themeVariables: { "--wcm-accent-color": "#c43646" } },
    metadata: WALLET_METADATA,
  });

  return createConnector((config) => {
    const real = stock(config);
    const memory = config.storage as unknown as SessionMemory | null | undefined;
    let awake = false;

    const remember = async () => {
      await memory?.setItem(SESSION_KEY, true);
    };
    const forget = async () => {
      await memory?.removeItem(SESSION_KEY);
    };
    const asleep = async () => !awake && (await memory?.getItem(SESSION_KEY)) !== true;
    config.emitter.on("disconnect", () => void forget());

    const connector = {
      ...real,
      // The stock setup loads the provider at once. Connecting and reconnecting do their own wiring.
      async setup() {},
      async getProvider(parameters?: { chainId?: number }) {
        if (await asleep()) return undefined;
        awake = true;
        return real.getProvider(parameters);
      },
      async connect(parameters?: Parameters<typeof real.connect>[0]) {
        awake = true;
        try {
          const result = await real.connect(parameters);
          await remember();
          return result;
        } catch (error) {
          // A refusal after the pairing succeeded can only come from the add or switch network step.
          const provider = await real.getProvider().catch(() => undefined);
          if (provider?.session && (error as { code?: unknown } | null)?.code === USER_REJECTED_CODE) {
            await provider.disconnect().catch(() => undefined);
            throw new AddNetworkRefusedError();
          }
          throw error;
        }
      },
      async disconnect() {
        try {
          await real.disconnect();
        } finally {
          await forget();
        }
      },
      async isAuthorized() {
        if (await asleep()) return false;
        const authorized = await real.isAuthorized();
        if (!authorized) await forget();
        return authorized;
      },
      async switchChain(parameters: { chainId: number }) {
        try {
          return await real.switchChain!(parameters as never);
        } catch (error) {
          showToast({ id: "phone-wallet-network", kind: "problem", title: "Network not added", detail: ADD_NETWORK_REFUSED });
          throw error;
        }
      },
    };

    return connector as unknown as typeof real;
  });
}

const walletConnectProjectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID;

export const wagmiConfig = createConfig({
  chains: [mezoTestnetChain],
  connectors: walletConnectProjectId ? [injected(), phoneWallet(walletConnectProjectId)] : [injected()],
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

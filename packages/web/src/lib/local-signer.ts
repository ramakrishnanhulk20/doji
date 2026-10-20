import { createConnector, type Config } from "wagmi";
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mezoTestnetChain } from "./chains";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// Mezo's public RPC answers some calls with "header not found" when a node behind it is a block late, so a read that
// fails that way is asked again, up to three times in all.
async function withRetry<T>(run: () => Promise<T>): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await run();
    } catch (error) {
      const message = error instanceof Error ? `${error.message} ${(error as { details?: string }).details ?? ""}` : "";
      if (attempt >= 3 || !/header not found/i.test(message)) throw error;
      await sleep(500);
    }
  }
}

// Development only. Signs with the key in NEXT_PUBLIC_DEV_TEST_KEY so real flows can be driven without a browser
// wallet. wagmi.ts loads this file only when NODE_ENV is "development", and nothing is added unless the variable is
// set. The key is never logged or shown.
function devTestWallet() {
  return createConnector((config) => {
    const account = privateKeyToAccount(process.env.NEXT_PUBLIC_DEV_TEST_KEY as Hex);
    const publicClient = createPublicClient({ chain: mezoTestnetChain, transport: http() });
    const walletClient = createWalletClient({ account, chain: mezoTestnetChain, transport: http() });
    const chainIdHex = `0x${mezoTestnetChain.id.toString(16)}`;

    type Request = { method: string; params?: readonly unknown[] };

    const provider = {
      async request({ method, params = [] }: Request): Promise<unknown> {
        switch (method) {
          case "eth_requestAccounts":
          case "eth_accounts":
            return [account.address];
          case "eth_chainId":
            return chainIdHex;
          case "net_version":
            return String(mezoTestnetChain.id);
          case "wallet_switchEthereumChain":
          case "wallet_addEthereumChain":
            return null;
          case "eth_sendTransaction": {
            const tx = params[0] as { to?: Hex; data?: Hex; value?: Hex };
            const value = tx.value ? BigInt(tx.value) : undefined;

            // Every field is given here, so viem never asks the node to fill the transaction in. Mezo's node answers
            // that call with the bare minimum gas on many tries, and then refuses the signed transaction.
            const estimated = await withRetry(() =>
              publicClient.estimateGas({ account: account.address, to: tx.to, data: tx.data, value }),
            );
            const nonce = await withRetry(() =>
              publicClient.getTransactionCount({ address: account.address, blockTag: "pending" }),
            );
            const fees = await withRetry(() => publicClient.estimateFeesPerGas());
            const priced =
              fees.gasPrice !== undefined
                ? { type: "legacy" as const, gasPrice: fees.gasPrice }
                : { type: "eip1559" as const, maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas };

            return walletClient.sendTransaction({
              to: tx.to,
              data: tx.data,
              value,
              gas: (estimated * 125n) / 100n,
              nonce,
              ...priced,
            } as never);
          }
          case "personal_sign":
            return account.signMessage({ message: { raw: params[0] as Hex } });
          default:
            return publicClient.request({ method, params } as never);
        }
      },
      on() {},
      removeListener() {},
    };

    return {
      id: "devTestWallet",
      name: "Dev test wallet (local only)",
      type: "devTestWallet",
      async setup() {},
      async connect() {
        return { accounts: [account.address], chainId: mezoTestnetChain.id } as never;
      },
      async disconnect() {},
      async getAccounts() {
        return [account.address];
      },
      async getChainId() {
        return mezoTestnetChain.id;
      },
      async isAuthorized() {
        return false;
      },
      async switchChain() {
        return mezoTestnetChain;
      },
      onAccountsChanged() {},
      onChainChanged() {},
      onDisconnect() {
        config.emitter.emit("disconnect");
      },
      async getProvider() {
        return provider;
      },
    };
  });
}

/** Adds the test wallet to the config when the key is set. Called from a dynamic import that exists in development only. */
export function attachLocalSigner(config: Config) {
  if (!process.env.NEXT_PUBLIC_DEV_TEST_KEY) return;
  const connector = config._internal.connectors.setup(devTestWallet());
  config._internal.connectors.setState((existing) =>
    existing.some((candidate) => candidate.id === connector.id) ? existing : [...existing, connector],
  );
}

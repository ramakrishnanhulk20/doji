"use client";

import { useCallback, useRef, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi, Address, Hex, TransactionReceipt } from "viem";
import { useAccount, usePublicClient, useWalletClient } from "wagmi";
import { dismissToast, showToast } from "../components/app/toast-store";
import { addressBook } from "../lib/addresses";
import { AppError, explainError, type ErrorContext } from "../lib/errors";
import { APP_CHAIN_ID } from "../lib/wagmi";

const RECEIPT_ATTEMPTS = 8;
const RECEIPT_RETRY_MS = 1_500;
const EXPLORER_TX = "https://explorer.test.mezo.org/tx/";

export type WriteTarget = "loanManager" | "creditMarkets" | "btc" | "veBTC";

export type WriteRequest = {
  /** The contract, by name. The address comes from the address book for the connected chain. */
  target: WriteTarget;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
  /** The line the Done toast shows. */
  successLine: string;
  /** "lock" lets an error the app cannot name read as Mezo's veBTC refusing the lock. */
  action?: ErrorContext["action"];
};

export type WriteResult =
  | { ok: true; hash: Hex; receipt: TransactionReceipt }
  | { ok: false; refresh: boolean };

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

let counter = 0;

/**
 * One way to send any transaction. It simulates with the connected account first and only then asks the wallet, so a
 * call that would fail never reaches a prompt. It then waits for the receipt, which Mezo's public nodes sometimes
 * answer with null for a few seconds, and refreshes every read.
 */
export function useWrite() {
  const { address, chainId } = useAccount();
  const publicClient = usePublicClient({ chainId: APP_CHAIN_ID });
  const { data: walletClient } = useWalletClient();
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState(false);
  const running = useRef(false);

  const write = useCallback(
    async (request: WriteRequest): Promise<WriteResult> => {
      const id = `write-${(counter += 1)}`;
      const fail = (error: unknown, context: ErrorContext, hash?: Hex): WriteResult => {
        const explained = explainError(error, { ...context, action: request.action });
        showToast({
          id,
          kind: "problem",
          title: explained.title,
          detail: explained.detail,
          href: hash ? `${EXPLORER_TX}${hash}` : undefined,
        });
        if (explained.refresh) void queryClient.invalidateQueries();
        return { ok: false, refresh: Boolean(explained.refresh) };
      };

      if (running.current) return { ok: false, refresh: false };
      running.current = true;
      setBusy(true);
      try {
        if (!address || !walletClient) return fail(new AppError("noWallet"), { phase: "simulate" });
        if (chainId !== APP_CHAIN_ID || !publicClient) return fail(new AppError("wrongChain"), { phase: "simulate" });

        const to: Address = addressBook[APP_CHAIN_ID][request.target as "loanManager"];

        let simulated;
        try {
          simulated = await publicClient.simulateContract({
            account: address,
            address: to,
            abi: request.abi,
            functionName: request.functionName,
            args: request.args,
          } as never);
        } catch (error) {
          return fail(error, { phase: "simulate" });
        }

        showToast({ id, kind: "wallet", title: "Confirm in your wallet" });
        let hash: Hex;
        try {
          hash = await walletClient.writeContract((simulated as unknown as { request: never }).request);
        } catch (error) {
          return fail(error, { phase: "wallet" });
        }

        showToast({ id, kind: "sending", title: "Sending", href: `${EXPLORER_TX}${hash}` });

        let receipt: TransactionReceipt | null = null;
        for (let attempt = 0; attempt < RECEIPT_ATTEMPTS && receipt === null; attempt++) {
          try {
            receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000, retryCount: 0 });
          } catch {
            // A node may answer null for a receipt the others already have, so the lookup is tried again.
            await wait(RECEIPT_RETRY_MS);
          }
        }
        if (receipt === null) {
          return fail(new Error("The receipt did not arrive."), { phase: "receipt" }, hash);
        }
        if (receipt.status !== "success") return fail(new Error("reverted"), { phase: "receipt" }, hash);

        showToast({ id, kind: "done", title: "Done", detail: request.successLine, href: `${EXPLORER_TX}${hash}` });
        await queryClient.invalidateQueries();
        return { ok: true, hash, receipt };
      } finally {
        running.current = false;
        setBusy(false);
      }
    },
    [address, chainId, publicClient, queryClient, walletClient],
  );

  return { write, busy, dismiss: dismissToast };
}

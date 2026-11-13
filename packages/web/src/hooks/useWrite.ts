"use client";

import { useCallback, useRef, useState } from "react";
import { useQueryClient, type QueryClient } from "@tanstack/react-query";
import {
  encodeFunctionData,
  hexToNumber,
  numberToHex,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { useAccount, useDisconnect, usePublicClient, useWalletClient } from "wagmi";
import { openConnectModal } from "../components/app/connect-modal-store";
import { dismissToast, showToast } from "../components/app/toast-store";
import { addressBook } from "../lib/addresses";
import { confirmTransaction, fetchRevertData, type Confirmation } from "../lib/confirm";
import {
  AppError,
  explainError,
  explainReverted,
  inAppBrowserHint,
  isAccountRefusal,
  isNodeHiccup,
  isRejection,
  type ErrorContext,
} from "../lib/errors";
import { APP_CHAIN_ID } from "../lib/wagmi";
import { getPending, setPending, usePendingConfirmation } from "./pending";

const EXPLORER_TX = "https://explorer.test.mezo.org/tx/";
const REGRANT_DETAIL =
  "Your wallet has not allowed this account on Mezo testnet yet. Approve it in your wallet, then confirm the transaction.";

export type WriteTarget =
  | "loanManager"
  | "creditMarkets"
  | "payDown"
  | "unitMarket"
  | "legacyLoanManager"
  | "legacyCreditMarkets"
  | "btc"
  | "veBTC"
  | "musd";

export type SuccessLine = string | ((receipt: TransactionReceipt) => string);

export type WriteRequest = {
  /** The contract, by name. The address comes from the address book for the connected chain. */
  target: WriteTarget;
  abi: Abi;
  functionName: string;
  args: readonly unknown[];
  /** The line the Done toast shows. A function gets the receipt, for lines that depend on what the transaction did. */
  successLine: SuccessLine;
  /** "lock" lets an error the app cannot name read as Mezo's veBTC refusing the lock. */
  action?: ErrorContext["action"];
};

/**
 * ok: mined and succeeded. Otherwise the transaction either never left (a refusal, a cancel) or reverted, or, with
 * `confirming` set, it was sent and Mezo has not shown it yet. That last case is never a failure: the hash is known,
 * so nothing may be sent again for the same step.
 */
export type WriteResult =
  | { ok: true; hash: Hex; receipt: TransactionReceipt }
  | { ok: false; refresh: boolean; hash?: Hex; confirming?: boolean };

let counter = 0;
let queryClientRef: QueryClient | null = null;

// rpc.test.mezo.org balances across nodes that trailed the explorer by up to 494 s on 2026-10-20, and the explorer can
// confirm a step first. For ten minutes after any confirmation a failed simulation or gas estimate is asked again for
// up to 90 s, so the next step is never refused for a state older than the receipt it follows.
let lastConfirmedAt = 0;
const CATCH_UP_WINDOW_MS = 10 * 60_000;
const CATCH_UP_WAIT_MS = 90_000;
// A node's internal error is not the contract's answer, so even a first write asks again before refusing.
const HICCUP_WAIT_MS = 15_000;
const CATCH_UP_POLL_MS = 3_000;
const GAS_HEADROOM_PERCENT = 125n;
// A node that has not caught up can estimate a contract call as if no code ran (21,204 gas for a settle on
// 2026-10-25), and the network then refuses the transaction. Every token approve costs more than 23,000 and every
// Doji write more than 30,000, so a lower estimate is asked again, and after five tries the wallet estimates instead.
const minPlausibleGas = (functionName: string) => (functionName === "approve" ? 23_000n : 30_000n);
const ESTIMATE_TRIES = 5;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

// The pending record keeps only text, so a line that is a function waits here until its transaction is settled.
const lineFunctions = new Map<string, (receipt: TransactionReceipt) => string>();

// A flow that is waiting on a transaction after the first ten minutes asks for the next answer here.
const waiters: { hash: Hex; resolve: (result: WriteResult) => void }[] = [];

/** Resolves with the next outcome for this hash, which arrives when the transaction is confirmed or checked again. */
export function waitForSettlement(hash: Hex): Promise<WriteResult> {
  return new Promise((resolve) => waiters.push({ hash, resolve }));
}

/** A line that fails to build must never hide a transaction that went through, so it falls back to plain words. */
function lineFor(line: SuccessLine, receipt: TransactionReceipt): string {
  if (typeof line === "string") return line;
  try {
    return line(receipt);
  } catch {
    return "Confirmed on Mezo.";
  }
}

function toReceipt(hash: Hex, confirmed: Extract<Confirmation, { status: "success" }>): TransactionReceipt {
  return {
    status: "success",
    transactionHash: hash,
    blockNumber: confirmed.blockNumber ?? undefined,
    logs: confirmed.logs,
  } as unknown as TransactionReceipt;
}

/**
 * Follows one sent transaction until it is confirmed, reverted, or ten minutes pass without an answer. The last case
 * is shown as "Sent, still confirming" with a button that asks again; it is never shown as a failure.
 */
async function settle(hash: Hex, toastId: string, successLine: SuccessLine): Promise<WriteResult> {
  const href = `${EXPLORER_TX}${hash}`;
  if (typeof successLine === "function") lineFunctions.set(toastId, successLine);
  const pendingLine = typeof successLine === "string" ? successLine : "";
  setPending({ toastId, hash, stalled: false, successLine: pendingLine });
  showToast({ id: toastId, kind: "sending", title: "Sending", detail: "Waiting for Mezo to confirm", href });

  const outcome = await confirmTransaction(hash);
  let result: WriteResult;

  if (outcome.status === "success") {
    lastConfirmedAt = Date.now();
    setPending(null);
    const receipt = toReceipt(hash, outcome);
    const detail = lineFor(successLine, receipt);
    lineFunctions.delete(toastId);
    showToast({ id: toastId, kind: "done", title: "Done", detail, href });
    await queryClientRef?.invalidateQueries();
    result = { ok: true, hash, receipt };
  } else if (outcome.status === "reverted") {
    setPending(null);
    lineFunctions.delete(toastId);
    const explained = explainReverted(await fetchRevertData(hash));
    showToast({ id: toastId, kind: "problem", title: explained.title, detail: explained.detail, href });
    await queryClientRef?.invalidateQueries();
    result = { ok: false, refresh: false, hash };
  } else {
    setPending({ toastId, hash, stalled: true, successLine: pendingLine });
    showToast({
      id: toastId,
      kind: "stalled",
      title: "Sent, still confirming",
      detail: "Mezo has not confirmed it yet. It may still go through, so check the explorer before doing anything else.",
      href,
      action: { label: "Check again", run: () => recheckConfirmation() },
    });
    result = { ok: false, refresh: false, hash, confirming: true };
  }

  for (const waiter of waiters.splice(0)) {
    if (waiter.hash === hash) waiter.resolve(result);
    else waiters.push(waiter);
  }
  return result;
}

/** Asks about the stalled transaction again for another ten minutes. */
export function recheckConfirmation() {
  const current = getPending();
  if (current === null) return;
  void settle(current.hash, current.toastId, lineFunctions.get(current.toastId) ?? current.successLine);
}

export type PlainCall = { from: Address; to: Address; abi: Abi; functionName: string; args: readonly unknown[]; gas?: bigint };

/**
 * One contract call through eth_sendTransaction, with the same fields viem's writeContract sends. When a wallet refuses
 * those, viem retries with wallet_sendTransaction and the wallet's answer to the retry replaces the first refusal:
 * MetaMask on a phone answered "wallet_sendTransaction does not exist", which hid why the send was refused. Never
 * retried, so a step is never sent twice.
 */
export async function sendPlain(walletClient: Pick<WalletClient, "request">, call: PlainCall): Promise<Hex> {
  const data = encodeFunctionData({ abi: call.abi, functionName: call.functionName, args: call.args } as never);
  const gas = call.gas === undefined ? {} : { gas: numberToHex(call.gas) };
  return walletClient.request(
    { method: "eth_sendTransaction", params: [{ from: call.from, to: call.to, data, ...gas }] },
    { retryCount: 0 },
  );
}

/** What the wallet is being asked for, so the toast can say it. */
export type SendStage = "confirm" | "regrant";

/**
 * sendPlain, and when the wallet answers that the account is not granted: one request to grant it again, then one more
 * send. MetaMask 13.55 leaves a site's accounts off a network the site adds after connecting (metamask-extension issue
 * 47773), so a newcomer's first send on Mezo testnet is refused with 4100 while the site shows as connected. That
 * refusal comes before any confirmation, so the second send cannot double a step. The new grant can move the wallet to
 * another network, and a send carries no chain id, so the chain is read again before the second send.
 */
export async function sendRegranting(
  walletClient: Pick<WalletClient, "request">,
  call: PlainCall,
  chainId: number,
  onStage: (stage: SendStage) => void,
): Promise<Hex> {
  onStage("confirm");
  try {
    return await sendPlain(walletClient, call);
  } catch (refused) {
    if (!isAccountRefusal(refused)) throw refused;
    onStage("regrant");
    try {
      await walletClient.request({ method: "wallet_requestPermissions", params: [{ eth_accounts: {} }] }, { retryCount: 0 });
    } catch (declined) {
      // A wallet without this method keeps the first refusal, whose message offers Reconnect.
      throw isRejection(declined) ? declined : refused;
    }
    const walletChain = await walletClient.request({ method: "eth_chainId" }, { retryCount: 0 });
    if (hexToNumber(walletChain) !== chainId) throw new AppError("wrongChain");
    onStage("confirm");
    return sendPlain(walletClient, call);
  }
}

/**
 * One way to send any transaction. It simulates with the connected account first and only then asks the wallet, so a
 * call that would fail never reaches a prompt. Once the wallet returns a hash it never reports a failure unless the
 * chain shows a revert: the RPC and the explorer are both asked every three seconds for up to ten minutes.
 */
export function useWrite() {
  const { address, chainId } = useAccount();
  const publicClient = usePublicClient({ chainId: APP_CHAIN_ID });
  const { data: walletClient } = useWalletClient();
  const { disconnectAsync } = useDisconnect();
  const queryClient = useQueryClient();
  const pending = usePendingConfirmation();
  const [busy, setBusy] = useState(false);
  const running = useRef(false);

  const write = useCallback(
    async (request: WriteRequest): Promise<WriteResult> => {
      const id = `write-${(counter += 1)}`;
      queryClientRef = queryClient;
      const fail = (error: unknown, context: ErrorContext): WriteResult => {
        const explained = explainError(error, { ...context, action: request.action });
        const hint =
          explained.walletRefused && typeof navigator !== "undefined"
            ? inAppBrowserHint(navigator.userAgent, explained.reconnect)
            : null;
        // wagmi's disconnect also asks the wallet to drop this site's permission, so the next connect grants the account
        // afresh on every network the wallet now has. That is the way out MetaMask's own bug report gives.
        const reconnect = () => {
          dismissToast(id);
          void disconnectAsync()
            .catch(() => undefined)
            .finally(openConnectModal);
        };
        showToast({
          id,
          kind: "problem",
          title: explained.title,
          detail: hint ? `${explained.detail} ${hint}` : explained.detail,
          action: explained.reconnect
            ? { label: "Reconnect", run: reconnect }
            : hint
              ? { label: "Copy link", run: () => void navigator.clipboard?.writeText(window.location.href) }
              : undefined,
        });
        if (explained.refresh) void queryClient.invalidateQueries();
        return { ok: false, refresh: Boolean(explained.refresh) };
      };

      // A transaction that is still unconfirmed blocks the next one, so the same step is never sent twice.
      if (running.current || getPending() !== null) return { ok: false, refresh: false };
      running.current = true;
      setBusy(true);
      try {
        if (!address || !walletClient) return fail(new AppError("noWallet"), { phase: "simulate" });
        if (chainId !== APP_CHAIN_ID || !publicClient) return fail(new AppError("wrongChain"), { phase: "simulate" });

        const to: Address = addressBook[APP_CHAIN_ID][request.target];

        const call = {
          account: address,
          address: to,
          abi: request.abi,
          functionName: request.functionName,
          args: request.args,
        } as never;
        let gas: bigint | undefined;
        const askedAt = Date.now();
        for (;;) {
          try {
            await publicClient.simulateContract(call);
            gas = undefined;
            for (let tries = 0; tries < ESTIMATE_TRIES && gas === undefined; tries++) {
              const estimate = await publicClient.estimateContractGas(call);
              if (estimate >= minPlausibleGas(request.functionName)) gas = estimate;
              else await sleep(CATCH_UP_POLL_MS);
            }
            break;
          } catch (error) {
            const catchingUp = Date.now() - lastConfirmedAt < CATCH_UP_WINDOW_MS && Date.now() - askedAt < CATCH_UP_WAIT_MS;
            const stumbled = isNodeHiccup(error) && Date.now() - askedAt < HICCUP_WAIT_MS;
            if (!catchingUp && !stumbled) return fail(error, { phase: "simulate" });
            showToast({
              id,
              kind: "sending",
              title: "Checking",
              detail: catchingUp ? "Waiting for Mezo's nodes to catch up with your last step" : "A Mezo node stumbled. Asking again.",
            });
            await sleep(CATCH_UP_POLL_MS);
          }
        }

        let hash: Hex;
        try {
          // The gas is passed so the wallet does not estimate again on a node that may still be behind.
          const gasLimit = gas === undefined ? undefined : (gas * GAS_HEADROOM_PERCENT) / 100n;
          hash = await sendRegranting(
            walletClient,
            { from: address, to, abi: request.abi, functionName: request.functionName, args: request.args, gas: gasLimit },
            APP_CHAIN_ID,
            (stage) =>
              showToast(
                stage === "regrant"
                  ? { id, kind: "wallet", title: "Approve the account again", detail: REGRANT_DETAIL }
                  : { id, kind: "wallet", title: "Confirm in your wallet" },
              ),
          );
        } catch (error) {
          return fail(error, { phase: "wallet" });
        }

        return await settle(hash, id, request.successLine);
      } finally {
        running.current = false;
        setBusy(false);
      }
    },
    [address, chainId, disconnectAsync, publicClient, queryClient, walletClient],
  );

  // The buttons stay off for as long as a sent transaction is unconfirmed, not only while the wallet prompt is open.
  return { write, busy: busy || pending !== null, dismiss: dismissToast };
}

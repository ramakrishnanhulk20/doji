import type { Address, Hex } from "viem";

// Mezo's public RPC sits behind load-balanced nodes, and some of them lag. A mined transaction can stay invisible
// to one node for minutes while another node, and the explorer, have it at once. So a sent transaction is confirmed
// from two sources in parallel, each asked afresh every round, and the first definite answer wins.

const RPC_URL = "https://rpc.test.mezo.org";
const EXPLORER_TX = "https://api.explorer.test.mezo.org/api/v2/transactions";

export const CONFIRM_INTERVAL_MS = 3_000;
export const CONFIRM_TIMEOUT_MS = 600_000;
const REQUEST_TIMEOUT_MS = 8_000;

export type ConfirmedLog = {
  address: Address;
  topics: Hex[];
  data: Hex;
};

export type Confirmation =
  | { status: "success"; source: "rpc" | "explorer"; blockNumber: bigint | null; logs: ConfirmedLog[] }
  | { status: "reverted"; source: "rpc" | "explorer"; blockNumber: bigint | null }
  /** Neither source answered within the time given. The transaction may still be mined. */
  | { status: "pending" };

type Verdict = Confirmation & { status: "success" | "reverted" };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function getJson(url: string, init?: RequestInit): Promise<{ status: number; body: unknown }> {
  const response = await fetch(url, { ...init, cache: "no-store", signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  let body: unknown = null;
  try {
    body = await response.json();
  } catch {
    body = null;
  }
  return { status: response.status, body };
}

/** One fresh request, never batched or cached: the receipt as the RPC has it right now. */
export async function askRpc(hash: Hex): Promise<Verdict> {
  const { body } = await getJson(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: Date.now(), method: "eth_getTransactionReceipt", params: [hash] }),
  });
  const receipt = (body as { result?: Record<string, unknown> | null } | null)?.result;
  if (!receipt) throw new Error("the node has no receipt yet");

  const blockNumber = typeof receipt.blockNumber === "string" ? BigInt(receipt.blockNumber) : null;
  if (receipt.status === "0x1") {
    const logs = (Array.isArray(receipt.logs) ? receipt.logs : []) as { address: Address; topics: Hex[]; data: Hex }[];
    return {
      status: "success",
      source: "rpc",
      blockNumber,
      logs: logs.map((log) => ({ address: log.address, topics: log.topics, data: log.data })),
    };
  }
  if (receipt.status === "0x0") return { status: "reverted", source: "rpc", blockNumber };
  throw new Error("the receipt has no status");
}

// Throws rather than returning an empty list: the success cards read ids and amounts from these logs, so a partial
// answer must lose to the RPC or the next round instead of showing "#0".
async function explorerLogs(hash: Hex): Promise<ConfirmedLog[]> {
  const { status, body } = await getJson(`${EXPLORER_TX}/${hash}/logs`);
  const items = (body as { items?: { address?: { hash?: string }; topics?: (string | null)[]; data?: string }[] } | null)?.items;
  if (status !== 200 || !Array.isArray(items)) throw new Error("the explorer has not indexed the logs yet");
  return items.map((item) => ({
    address: (item.address?.hash ?? "0x") as Address,
    topics: (item.topics ?? []).filter((topic): topic is Hex => typeof topic === "string"),
    data: (item.data ?? "0x") as Hex,
  }));
}

/** One fresh request to the explorer's transaction page. 404 and a still-pending transaction both mean keep waiting. */
export async function askExplorer(hash: Hex): Promise<Verdict> {
  const { status, body } = await getJson(`${EXPLORER_TX}/${hash}`);
  if (status !== 200 || typeof body !== "object" || body === null) throw new Error("the explorer does not have it yet");

  const tx = body as { status?: string | null; result?: string | null; block_number?: number | null };
  const blockNumber = typeof tx.block_number === "number" ? BigInt(tx.block_number) : null;
  if (tx.status === "ok" && tx.result === "success") {
    return { status: "success", source: "explorer", blockNumber, logs: await explorerLogs(hash) };
  }
  if (tx.status === "error") return { status: "reverted", source: "explorer", blockNumber };
  throw new Error("the explorer shows it as pending");
}

export type ConfirmOptions = {
  /** Total time to keep asking. Ten minutes unless a test passes less. */
  timeoutMs?: number;
  intervalMs?: number;
};

/**
 * Asks the RPC and the explorer together every few seconds until one of them shows the transaction mined, with a
 * success or a revert. "pending" comes back only when the time runs out, and it is never a failure.
 */
export async function confirmTransaction(hash: Hex, options: ConfirmOptions = {}): Promise<Confirmation> {
  const timeoutMs = options.timeoutMs ?? CONFIRM_TIMEOUT_MS;
  const intervalMs = options.intervalMs ?? CONFIRM_INTERVAL_MS;
  const deadline = Date.now() + timeoutMs;

  for (;;) {
    try {
      return await Promise.any([askRpc(hash), askExplorer(hash)]);
    } catch {
      // Neither source had a definite answer this round.
    }
    const remaining = deadline - Date.now();
    if (remaining <= 0) return { status: "pending" };
    await sleep(Math.min(intervalMs, remaining));
  }
}

/**
 * The revert data of a mined transaction that failed, found by running its call again on the block before it. Null
 * when the explorer or the node cannot say, so the caller falls back to a plain sentence.
 */
export async function fetchRevertData(hash: Hex): Promise<Hex | null> {
  try {
    const { status, body } = await getJson(`${EXPLORER_TX}/${hash}`);
    const tx = body as {
      from?: { hash?: string };
      to?: { hash?: string };
      raw_input?: string;
      value?: string;
      block_number?: number;
    } | null;
    if (status !== 200 || !tx?.from?.hash || !tx.to?.hash || typeof tx.block_number !== "number") return null;

    const { body: reply } = await getJson(RPC_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "eth_call",
        params: [
          { from: tx.from.hash, to: tx.to.hash, data: tx.raw_input ?? "0x", value: `0x${BigInt(tx.value ?? "0").toString(16)}` },
          `0x${(tx.block_number - 1).toString(16)}`,
        ],
      }),
    });
    const data = (reply as { error?: { data?: unknown } } | null)?.error?.data;
    return typeof data === "string" && data.startsWith("0x") && data.length >= 10 ? (data as Hex) : null;
  } catch {
    return null;
  }
}

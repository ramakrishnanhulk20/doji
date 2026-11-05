import "server-only";
import {
  BaseError,
  RpcRequestError,
  createPublicClient,
  encodeFunctionData,
  http,
  keccak256,
  parseAbi,
  type Address,
  type Hash,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { parseAddress } from "@/lib/address";
import { addressBook } from "@/lib/addresses";
import { mezoTestnetChain } from "@/lib/chains";
import type { ClaimReply, FaucetCode } from "@/lib/faucet-codes";

// C59: this is everything a signature can contain. None of it comes from a request or an RPC answer.
const CHAIN_ID = 31611;
const FAUCET = addressBook[CHAIN_ID].faucet;
const FAUCET_ABI = parseAbi([
  "function claim(address to)",
  "function claimed(address account) view returns (bool)",
  "function claimsOpen() view returns (uint256)",
  "function nextOpenAt() view returns (uint256)",
  "function paused() view returns (bool)",
]);
// A claim uses about 150,000 gas and the worst case in tests was 181,107. Mezo bills at least half the limit whatever
// a transaction uses, so a looser limit costs real gas on every claim.
const GAS_LIMIT = 230_000n;
const GAS_PRICE_CEILING = 10_000n;
const IN_FLIGHT_LIMIT = 3;

const ROUTE_BUDGET_MS = 8_000;
const VERIFY_TIMEOUT_MS = 5_000;
const RPC_TIMEOUT_MS = 4_000;
const MAX_TOKEN_CHARS = 2_048;
const SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export const MAX_BODY_BYTES = 4_096;

const liveClient: PublicClient = createPublicClient({
  chain: mezoTestnetChain,
  transport: http(undefined, { timeout: RPC_TIMEOUT_MS, retryCount: 0, batch: true }),
});

export type TokenVerdict = "pass" | "bot_check_failed" | "unavailable";

export type ClaimTransaction = { to: Address; nonce: number; gasPrice: bigint };

export type SendOutcome = { sent: true; hash: Hash } | { sent: false; code: "busy" | "unavailable" };

export type ClaimDeps = {
  verifyToken: (token: string, ip: string | null) => Promise<TokenVerdict>;
  client: PublicClient;
  /** Null when no usable relayer key is set: every claim is then refused. */
  relayer: Address | null;
  signAndSend: (claim: ClaimTransaction) => Promise<SendOutcome>;
  /** Milliseconds. */
  now: () => number;
};

// Parallel calls on one server all read the same nonces before any of them has sent, so the chain cannot stop them all
// signing. This counts the calls now between their chain reads and their send. It sees one server only. Separate
// servers are held by the chain instead: a node keeps one transaction per nonce, and the losers get `busy`.
let claimsAtChain = 0;

const refuse = (code: FaucetCode, nextOpenAt?: number): ClaimReply =>
  nextOpenAt === undefined ? { ok: false, code } : { ok: false, code, nextOpenAt };

/** VERCEL_ENV is set on every Vercel deployment, so a preview or a fork's build can never reach a signature. */
function isPreviewBuild(): boolean {
  const stage = process.env.VERCEL_ENV;
  return stage !== undefined && stage !== "production";
}

function parseClaim(body: string): { wallet: Address; token: string } | null {
  if (body.length > MAX_BODY_BYTES) return null;
  let value: unknown;
  try {
    value = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const { address, turnstileToken } = value as Record<string, unknown>;
  if (typeof address !== "string" || typeof turnstileToken !== "string") return null;
  if (turnstileToken.length === 0 || turnstileToken.length > MAX_TOKEN_CHARS) return null;
  const wallet = parseAddress(address);
  return wallet === null ? null : { wallet, token: turnstileToken };
}

function withinBudget<T>(work: () => Promise<T>, deadline: number, now: () => number): Promise<T> {
  const left = deadline - now();
  if (left <= 0) return Promise.reject(new Error("budget spent"));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const expiry = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("budget spent")), left);
  });
  return Promise.race([Promise.resolve().then(work), expiry]).finally(() => clearTimeout(timer));
}

/**
 * The one check on the way to the signer (C60). Passes only on a parsed reply with `success` exactly true, Doji's host
 * and the faucet's action. A made-up token comes back from Cloudflare as a 200 with `success` false, which is
 * `bot_check_failed`. A wrong secret comes back as a 400, which is `unavailable`, so the two can be told apart after a
 * deploy (C82). Cloudflare's always-pass test secret fails here too: its reply names example.com and has no action.
 * @param token The caller's Turnstile token, sent through a form encoder so it cannot add fields.
 * @param ip The address the platform reports, or null to leave the field out (C61).
 */
export async function verifyToken(token: string, ip: string | null): Promise<TokenVerdict> {
  const secret = process.env.TURNSTILE_SECRET_KEY;
  if (!secret) return "unavailable";
  const form = new URLSearchParams({ secret, response: token });
  if (ip !== null) form.set("remoteip", ip);

  let answer: unknown;
  try {
    const reply = await fetch(SITEVERIFY_URL, {
      method: "POST",
      body: form,
      redirect: "error",
      cache: "no-store",
      signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS),
    });
    if (reply.status !== 200) return "unavailable";
    answer = await reply.json();
  } catch {
    return "unavailable";
  }
  if (typeof answer !== "object" || answer === null) return "unavailable";

  const { success, hostname, action } = answer as Record<string, unknown>;
  const dojiHost =
    hostname === "www.dojis.site" ||
    hostname === "dojis.site" ||
    (hostname === "localhost" && process.env.NODE_ENV === "development");
  return success === true && dojiHost && action === "faucet" ? "pass" : "bot_check_failed";
}

function relayerAccount(): PrivateKeyAccount | null {
  const key = process.env.RELAYER_PRIVATE_KEY;
  if (key === undefined || !/^0x[0-9a-fA-F]{64}$/.test(key)) return null;
  try {
    return privateKeyToAccount(key as Hex);
  } catch {
    return null;
  }
}

/**
 * The server's only way to spend the relayer key, and its only input is a claim: it cannot sign anything else (C59).
 * The hash comes from the signed bytes, because a reply from the RPC proves nothing (C63). Any refusal the node answers
 * with is `busy`, whatever words that node uses for a taken nonce or a transaction it already holds. A send that gets
 * no answer is `unavailable`. Neither ever gives a hash.
 */
function relayerSender(client: PublicClient, account: PrivateKeyAccount): ClaimDeps["signAndSend"] {
  return async ({ to, nonce, gasPrice }) => {
    if (gasPrice > GAS_PRICE_CEILING) return { sent: false, code: "unavailable" };
    const signed = await account.signTransaction({
      type: "legacy",
      chainId: CHAIN_ID,
      to: FAUCET,
      data: encodeFunctionData({ abi: FAUCET_ABI, functionName: "claim", args: [to] }),
      value: 0n,
      gas: GAS_LIMIT,
      gasPrice,
      nonce,
    });
    const hash = keccak256(signed);
    try {
      await client.request({ method: "eth_sendRawTransaction", params: [signed] });
    } catch (error) {
      const nodeRefused =
        error instanceof BaseError && error.walk((cause) => cause instanceof RpcRequestError) !== null;
      return { sent: false, code: nodeRefused ? "busy" : "unavailable" };
    }
    return { sent: true, hash };
  };
}

/** Real dependencies. The relayer key is read here and nowhere else (C65). */
export function liveClaimDeps(client: PublicClient = liveClient): ClaimDeps {
  const account = relayerAccount();
  return {
    verifyToken,
    client,
    relayer: account?.address ?? null,
    signAndSend: account ? relayerSender(client, account) : async () => ({ sent: false, code: "unavailable" }),
    now: Date.now,
  };
}

async function claimOnChain(
  wallet: Address,
  relayer: Address,
  deps: ClaimDeps,
  deadline: number,
): Promise<ClaimReply> {
  const { client } = deps;
  const faucet = { address: FAUCET, abi: FAUCET_ABI } as const;

  // These pick the message a refusal carries. They never permit a send: only the simulation below does (C62).
  const [chainId, alreadyClaimed, claimsOpen, nextOpenAt, paused, balance, latest, pending, gasPrice] = await withinBudget(
    () =>
      Promise.all([
        client.getChainId(),
        client.readContract({ ...faucet, functionName: "claimed", args: [wallet] }),
        client.readContract({ ...faucet, functionName: "claimsOpen" }),
        client.readContract({ ...faucet, functionName: "nextOpenAt" }),
        client.readContract({ ...faucet, functionName: "paused" }),
        client.getBalance({ address: relayer }),
        client.getTransactionCount({ address: relayer, blockTag: "latest" }),
        client.getTransactionCount({ address: relayer, blockTag: "pending" }),
        client.getGasPrice(),
      ]),
    deadline,
    deps.now,
  );

  // The transaction's chain id stays the constant. This only stops an RPC on another chain from being answered at all.
  if (chainId !== CHAIN_ID) return refuse("unavailable");
  if (alreadyClaimed) return refuse("already_claimed");
  if (paused) return refuse("paused");
  if (claimsOpen === 0n) {
    // The faucet reports 0 when waiting alone will open nothing.
    if (nextOpenAt === 0n) return refuse("faucet_empty");
    return refuse("none_open", nextOpenAt <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(nextOpenAt) : undefined);
  }
  if (gasPrice <= 0n || gasPrice > GAS_PRICE_CEILING) return refuse("unavailable");
  if (pending < latest) return refuse("busy");

  // At the limit there is no store to say how old the head is, so this caller's claim takes its nonce at a higher
  // price. That frees a stuck head. A caller replaced this way times out and retries: `claimed` stays false for them.
  const atLimit = pending - latest >= IN_FLIGHT_LIMIT;
  const bumped = (gasPrice * 12n + 9n) / 10n;
  const nonce = atLimit ? latest : pending;
  const price = !atLimit ? gasPrice : bumped < GAS_PRICE_CEILING ? bumped : GAS_PRICE_CEILING;

  if (balance < GAS_LIMIT * price) {
    // The reply list has no code for this: a tester only needs to know no kit can go out. The log tells the two apart,
    // because topping up the relayer and refilling the faucet are different jobs.
    console.warn(JSON.stringify({ faucet: "relayer_short" }));
    return refuse("faucet_empty");
  }

  await withinBudget(
    () => client.simulateContract({ ...faucet, functionName: "claim", args: [wallet], account: relayer, gas: GAS_LIMIT }),
    deadline,
    deps.now,
  );

  const outcome = await withinBudget(() => deps.signAndSend({ to: wallet, nonce, gasPrice: price }), deadline, deps.now);
  return outcome.sent ? { ok: true, hash: outcome.hash } : refuse(outcome.code);
}

async function attemptClaim(
  claim: { wallet: Address; token: string },
  ip: string | null,
  deps: ClaimDeps,
): Promise<ClaimReply> {
  try {
    const deadline = deps.now() + ROUTE_BUDGET_MS;
    if (isPreviewBuild() || deps.relayer === null) return refuse("unavailable");

    const verdict = await withinBudget(() => deps.verifyToken(claim.token, ip), deadline, deps.now);
    if (verdict !== "pass") return refuse(verdict === "bot_check_failed" ? "bot_check_failed" : "unavailable");

    if (claimsAtChain >= IN_FLIGHT_LIMIT) return refuse("busy");
    claimsAtChain += 1;
    try {
      return await claimOnChain(claim.wallet, deps.relayer, deps, deadline);
    } finally {
      claimsAtChain -= 1;
    }
  } catch {
    // Upstream errors carry RPC URLs and node text, so nothing about this one is kept (C64).
    return refuse("unavailable");
  }
}

/**
 * Takes one claim from the browser and, if everything holds, has the relayer send one `claim` for that wallet.
 * The cheapest check runs first and the first failure ends it: format, then Turnstile, then chain reads, then the
 * simulation, then the signature. Never throws. Logs the outcome and the parsed wallet, never the token or the IP.
 * @param input `body` is the raw request text. `ip` is the platform's value, or null.
 * @param deps Real ones from `liveClaimDeps`, or mocks in scripts.
 * @returns A hash computed from the signed bytes, or one code from the closed list.
 */
export async function handleClaim(input: { body: string; ip: string | null }, deps: ClaimDeps): Promise<ClaimReply> {
  const claim = parseClaim(input.body);
  const reply = claim === null ? refuse("bad_request") : await attemptClaim(claim, input.ip, deps);
  console.info(JSON.stringify({ faucet: reply.ok ? "sent" : reply.code, wallet: claim?.wallet ?? null }));
  return reply;
}

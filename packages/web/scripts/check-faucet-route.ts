import { readFileSync, readdirSync } from "node:fs";
import { registerHooks } from "node:module";
import { resolve } from "node:path";
import {
  RpcRequestError,
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeErrorResult,
  encodeFunctionData,
  encodeFunctionResult,
  formatUnits,
  getAddress,
  http,
  keccak256,
  numberToHex,
  parseAbi,
  parseEventLogs,
  parseTransaction,
  recoverTransactionAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { addressBook } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import { FAUCET_CODES, type ClaimReply, type FaucetCode } from "../src/lib/faucet-codes";

// Mocks by default: no network and no real key. A throwaway key signs for real, so the signed bytes can be read back,
// and a mock node takes the send. `--live` instead sends one real claim to a fresh address, which needs
// RELAYER_PRIVATE_KEY in the environment and a faucet holding a kit.
// Not covered: Cloudflare's real replies (the mocks copy shapes read from the live endpoint), how Mezo's own node
// treats a same-nonce replacement, and the browser half of C64, which is not built yet.

// Next swaps this package for an empty file at build time. tsx has no such swap, and the package is not installed.
registerHooks({
  resolve: (specifier, context, next) =>
    specifier === "server-only" ? { url: "data:text/javascript,", format: "module", shortCircuit: true } : next(specifier, context),
});

type FaucetModule = typeof import("../src/server/faucet");
type ClaimDeps = import("../src/server/faucet").ClaimDeps;
type RouteModule = typeof import("../src/app/api/faucet/route");

const { handleClaim, liveClaimDeps, readNonces, verifyToken }: FaucetModule = await import("../src/server/faucet");

const env = process.env as Record<string, string | undefined>;
const LIVE = process.argv.includes("--live");
const FAUCET = addressBook[31611].faucet;
const NORMAL_GAS_PRICE = 146n; // What Mezo testnet answered on 2026-11-05.
const GAS_LIMIT = 230_000n;
const CEILING = 10_000n;
const IN_FLIGHT = 3;
const NONCE_READS = 3;
const STUCK_AFTER_MS = 60_000;
const MARKER = "UPSTREAM-TEXT-MARKER https://rpc.internal.example/secret-path";
const TOKEN = "turnstile-token-marker";
const IP = "203.0.113.7";

const faucetAbi = parseAbi([
  "function claim(address to)",
  "function claimed(address account) view returns (bool)",
  "function claimsOpen() view returns (uint256)",
  "function nextOpenAt() view returns (uint256)",
  "function paused() view returns (bool)",
  "function btcPerClaim() view returns (uint128)",
  "function musdPerClaim() view returns (uint128)",
  "error AlreadyClaimed(address to)",
  "error BtcPaymentFailed(address to)",
  "event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day)",
]);
const erc20Abi = parseAbi(["function balanceOf(address account) view returns (uint256)"]);

const failures: string[] = [];
const check = (name: string, passed: boolean) => {
  process.stdout.write(`${passed ? "ok  " : "FAIL"} ${name}\n`);
  if (!passed) failures.push(name);
};
function finish(): never {
  if (failures.length > 0) {
    process.stderr.write(`\n${failures.length} check(s) failed\n`);
    process.exit(1);
  }
  process.stdout.write("\nall checks passed\n");
  process.exit(0);
}

const randomWallet = (): Address => privateKeyToAccount(generatePrivateKey()).address;
const claimBody = (wallet: Address, token = TOKEN): string => JSON.stringify({ address: wallet, turnstileToken: token });

const logged: string[] = [];
const capture = (...parts: unknown[]) => {
  logged.push(parts.map(String).join(" "));
};
for (const method of ["log", "info", "warn", "error", "debug"] as const) console[method] = capture;

/** Throws what viem's http transport throws when a node answers with a JSON-RPC error. */
const nodeError = (message: string, data?: Hex): RpcRequestError =>
  new RpcRequestError({ body: {}, error: { code: -32000, message, data }, url: "https://mock.invalid" });

type Queued = { raw: Hex; to: Address; nonce: number; gasPrice: bigint };

type NodeSetup = {
  chainId: number;
  gasPrice: bigint;
  balance: bigint;
  paused: boolean;
  noBtc: boolean;
  noMusd: boolean;
  dayFull: boolean;
  claimed: Address[];
  hostile: Address[];
  /** Every view says all is well, so only the simulation can refuse. */
  viewsLie: boolean;
  latest: number;
  /** Added to the real queue length, for a queue this check did not fill itself. */
  pendingExtra: number;
  /** Which of each set of nonce reads a node one nonce behind answers, or null when none does. */
  laggingRead: number | null;
  acceptReplacement: boolean;
  simulationBroken: boolean;
  readsBroken: boolean;
  sendAnswer: "hash" | "wrong_hash" | "network_failure";
  hang: string | null;
};

function mockNode(setup: Partial<NodeSetup> = {}) {
  const world: NodeSetup = {
    chainId: 31611,
    gasPrice: NORMAL_GAS_PRICE,
    balance: 10n ** 16n,
    paused: false,
    noBtc: false,
    noMusd: false,
    dayFull: false,
    claimed: [],
    hostile: [],
    viewsLie: false,
    latest: 7,
    pendingExtra: 0,
    laggingRead: null,
    acceptReplacement: false,
    simulationBroken: false,
    readsBroken: false,
    sendAnswer: "hash",
    hang: null,
    ...setup,
  };
  const calls: string[] = [];
  const simulations: Record<string, string | undefined>[] = [];
  const claimed = new Set(world.claimed);
  const queue: Queued[] = [];
  const startingNonce = world.latest;
  const nonceReads = { latest: 0, pending: 0 };
  let landed = 0;
  let failed = 0;

  const noKit = () => world.noBtc || world.noMusd;

  const answerCall = (request: Record<string, string | undefined>): Hex => {
    if (request.to !== undefined && getAddress(request.to) !== FAUCET) throw nodeError(`call to a stranger. ${MARKER}`);
    const { functionName, args } = decodeFunctionData({ abi: faucetAbi, data: request.data as Hex }) as {
      functionName: string;
      args?: readonly unknown[];
    };
    const encode = (result: boolean | bigint) =>
      encodeFunctionResult({ abi: faucetAbi, functionName: functionName as "paused", result: result as never });
    if (functionName === "claim") {
      simulations.push(request);
      if (world.simulationBroken) throw new Error(MARKER);
      const wallet = args?.[0] as Address;
      if (claimed.has(wallet)) {
        throw nodeError(`execution reverted ${MARKER}`, encodeErrorResult({ abi: faucetAbi, errorName: "AlreadyClaimed", args: [wallet] }));
      }
      if (world.paused || world.dayFull || noKit()) throw nodeError(`execution reverted ${MARKER}`);
      if (world.hostile.includes(wallet)) {
        throw nodeError(`execution reverted ${MARKER}`, encodeErrorResult({ abi: faucetAbi, errorName: "BtcPaymentFailed", args: [wallet] }));
      }
      return "0x";
    }
    if (world.readsBroken) throw new Error(MARKER);
    if (world.viewsLie) {
      if (functionName === "claimed" || functionName === "paused") return encode(false);
      if (functionName === "claimsOpen") return encode(5n);
      return encode(1_800_000_000n);
    }
    if (functionName === "claimed") return encode(claimed.has(args?.[0] as Address));
    if (functionName === "paused") return encode(world.paused);
    if (functionName === "claimsOpen") return encode(world.paused || world.dayFull || noKit() ? 0n : 5n);
    if (functionName === "nextOpenAt") return encode(world.paused || noKit() ? 0n : 1_800_000_000n);
    throw new Error(`mock has no ${functionName}`);
  };

  const acceptRaw = async (raw: Hex): Promise<Hex> => {
    if (world.sendAnswer === "network_failure") throw new Error(MARKER);
    const parsed = parseTransaction(raw);
    const nonce = parsed.nonce ?? 0;
    const entry: Queued = { raw, to: decodeRecipient(parsed.data), nonce, gasPrice: parsed.gasPrice ?? 0n };
    if (nonce < world.latest) throw nodeError(`nonce too low ${MARKER}`);
    if (queue.some((queued) => queued.raw === raw)) throw nodeError(`already known ${MARKER}`);
    const sameNonce = queue.findIndex((queued) => queued.nonce === nonce);
    if (sameNonce >= 0) {
      if (!world.acceptReplacement) throw nodeError(`replacement transaction underpriced ${MARKER}`);
      queue[sameNonce] = entry;
    } else {
      queue.push(entry);
    }
    return world.sendAnswer === "wrong_hash" ? keccak256("0xdead") : keccak256(raw);
  };

  const request = async ({ method, params }: { method: string; params?: unknown }): Promise<unknown> => {
    calls.push(method);
    // Yields to the event loop so parallel calls interleave the way network calls do.
    await new Promise((done) => setImmediate(done));
    if (world.hang === method) return new Promise(() => undefined);
    const list = (params ?? []) as unknown[];
    switch (method) {
      case "eth_chainId":
        return numberToHex(world.chainId);
      case "eth_gasPrice":
        if (world.readsBroken) throw new Error(MARKER);
        return numberToHex(world.gasPrice);
      case "eth_getBalance":
        return numberToHex(world.balance);
      case "eth_getTransactionCount": {
        const tag = list[1] === "pending" ? "pending" : "latest";
        const lag = nonceReads[tag]++ % NONCE_READS === world.laggingRead ? 1 : 0;
        return numberToHex((tag === "pending" ? world.latest + queue.length + world.pendingExtra : world.latest) - lag);
      }
      case "eth_call":
        return answerCall(list[0] as Record<string, string | undefined>);
      case "eth_sendRawTransaction":
        return acceptRaw(list[0] as Hex);
      default:
        throw new Error(`mock has no ${method}`);
    }
  };

  const client = createPublicClient({
    chain: mezoTestnetChain,
    transport: custom({ request } as never, { retryCount: 0 }),
  }) as PublicClient;

  return {
    client,
    world,
    calls,
    simulations,
    queue,
    claimed,
    startingNonce,
    counts: () => ({ landed, failed }),
    mine: () => {
      for (const entry of [...queue].sort((a, b) => a.nonce - b.nonce)) {
        if (claimed.has(entry.to)) failed += 1;
        else {
          claimed.add(entry.to);
          landed += 1;
        }
        world.latest += 1;
      }
      queue.length = 0;
    },
  };
}

function decodeRecipient(data: Hex | undefined): Address {
  const { args } = decodeFunctionData({ abi: faucetAbi, data: data ?? "0x" }) as { args?: readonly unknown[] };
  return args?.[0] as Address;
}

type Node = ReturnType<typeof mockNode>;

function setup(start: Partial<NodeSetup> = {}) {
  const node = mockNode(start);
  const real = liveClaimDeps(node.client);
  let signs = 0;
  let tokenChecks = 0;
  const deps: ClaimDeps = {
    ...real,
    verifyToken: async () => {
      tokenChecks += 1;
      return "pass";
    },
    signAndSend: async (claim) => {
      signs += 1;
      return real.signAndSend(claim);
    },
  };
  return { node, deps, signs: () => signs, tokenChecks: () => tokenChecks };
}

const nothingSigned = (node: Node, signs: number): boolean =>
  signs === 0 &&
  !node.calls.includes("eth_sendRawTransaction") &&
  node.queue.length === 0 &&
  node.world.latest === node.startingNonce;

const refusedWith = (reply: ClaimReply, code: FaucetCode): boolean => !reply.ok && reply.code === code;

async function withEnv<T>(changes: Record<string, string | undefined>, work: () => Promise<T>): Promise<T> {
  const before = Object.fromEntries(Object.keys(changes).map((name) => [name, env[name]]));
  const assign = (values: Record<string, string | undefined>) => {
    for (const [name, value] of Object.entries(values)) {
      if (value === undefined) delete env[name];
      else env[name] = value;
    }
  };
  assign(changes);
  try {
    return await work();
  } finally {
    assign(before);
  }
}

type Siteverify = (form: URLSearchParams, init: RequestInit) => Promise<Response> | Response;

const realFetch = globalThis.fetch;
const forms: URLSearchParams[] = [];
let fetchCalls = 0;

function stubCloudflare(answer: Siteverify) {
  globalThis.fetch = (async (url: string | URL | Request, init: RequestInit = {}) => {
    fetchCalls += 1;
    if (String(url) !== "https://challenges.cloudflare.com/turnstile/v0/siteverify") throw new Error("wrong host");
    if (init.method !== "POST" || init.redirect !== "error") throw new Error("wrong request shape");
    const form = new URLSearchParams(String(init.body));
    forms.push(form);
    return answer(form, init);
  }) as typeof fetch;
}

const jsonReply = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });
const goodAnswer = { success: true, hostname: "www.dojis.site", action: "faucet", "error-codes": [] };

async function checkTransactionShape() {
  const wallet = randomWallet();
  const { node, deps } = setup({ sendAnswer: "wrong_hash" });
  const body = JSON.stringify({
    address: wallet.toLowerCase(),
    turnstileToken: TOKEN,
    chainId: 31612,
    to: randomWallet(),
    value: "1000000",
    gas: "99999999",
    gasPrice: "99999999",
    data: "0xdeadbeef",
    function: "withdraw",
  });
  const reply = await handleClaim({ body, ip: null }, deps);
  const raw = node.queue[0]?.raw;
  check("happy path returns a hash", reply.ok);
  if (!raw || !reply.ok) return;
  const tx = parseTransaction(raw);
  check("C59 the signed bytes name chain 31611", tx.chainId === 31611);
  check("C59 the target is the address-book faucet", tx.to !== undefined && tx.to !== null && getAddress(tx.to) === FAUCET);
  check(
    "C59 the call is claim of the parsed wallet, whatever else the body said",
    tx.data === encodeFunctionData({ abi: faucetAbi, functionName: "claim", args: [wallet] }),
  );
  check("C59 the value is zero", (tx.value ?? 0n) === 0n);
  check(`C59 the gas limit is ${GAS_LIMIT}`, tx.gas === GAS_LIMIT);
  check("C59 the gas price is the current one, under the ceiling", tx.gasPrice === NORMAL_GAS_PRICE);
  check("C59 the type is a legacy transaction", tx.type === "legacy");
  check("the signer is the relayer", (await recoverTransactionAddress({ serializedTransaction: raw as never })) === deps.relayer);
  check("C63 the reply's hash is computed from the signed bytes", reply.hash === keccak256(raw));
  check("C63 an RPC answering a different hash changes nothing", reply.hash !== keccak256("0xdead"));
  const simulation = node.simulations[0];
  check(
    "C62 the simulation ran from the relayer, to the faucet, at the gas limit, with no value",
    simulation !== undefined &&
      simulation.from !== undefined &&
      getAddress(simulation.from) === deps.relayer &&
      simulation.to !== undefined &&
      getAddress(simulation.to) === FAUCET &&
      simulation.gas === numberToHex(GAS_LIMIT) &&
      simulation.data === tx.data &&
      BigInt(simulation.value ?? "0x0") === 0n,
  );
  const order = node.calls.indexOf("eth_sendRawTransaction") > node.calls.lastIndexOf("eth_call");
  check("C64 the send comes after the simulation", order);
}

async function checkSigningLimits() {
  const onChain31612 = setup({ chainId: 31612 });
  const reply31612 = await handleClaim({ body: claimBody(randomWallet()), ip: null }, onChain31612.deps);
  check(
    "C59 a mock RPC on chain 31612 gets nothing signed",
    refusedWith(reply31612, "unavailable") && nothingSigned(onChain31612.node, onChain31612.signs()),
  );

  const dearGas = setup({ gasPrice: NORMAL_GAS_PRICE * 1_000n });
  const replyDear = await handleClaim({ body: claimBody(randomWallet()), ip: null }, dearGas.deps);
  check("C59 a gas price 1,000 times normal gets nothing signed", refusedWith(replyDear, "unavailable") && nothingSigned(dearGas.node, dearGas.signs()));

  const zeroGas = setup({ gasPrice: 0n });
  const replyZero = await handleClaim({ body: claimBody(randomWallet()), ip: null }, zeroGas.deps);
  check("C59 a gas price of zero gets nothing signed", refusedWith(replyZero, "unavailable") && nothingSigned(zeroGas.node, zeroGas.signs()));

  const atCeiling = setup({ gasPrice: CEILING });
  const replyCeiling = await handleClaim({ body: claimBody(randomWallet()), ip: null }, atCeiling.deps);
  check("C59 a gas price exactly at the ceiling still goes", replyCeiling.ok && atCeiling.node.queue[0]?.gasPrice === CEILING);

  const direct = mockNode();
  const signer = liveClaimDeps(direct.client);
  const overCeiling = await signer.signAndSend({ to: randomWallet(), nonce: 1, gasPrice: CEILING + 1n });
  check("C59 the signer itself refuses a price over the ceiling", !overCeiling.sent && !direct.calls.includes("eth_sendRawTransaction"));

  const exported = Object.keys(await import("../src/server/faucet")).sort().join(",");
  check("C59 the server module exports no general send", exported === "MAX_BODY_BYTES,handleClaim,liveClaimDeps,readNonces,verifyToken");

  await withEnv({ RELAYER_PRIVATE_KEY: undefined }, async () => {
    const node = mockNode();
    const deps = liveClaimDeps(node.client);
    const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps);
    check("C65 a missing relayer key refuses before any call", refusedWith(reply, "unavailable") && node.calls.length === 0);
  });
  await withEnv({ RELAYER_PRIVATE_KEY: "0x1234" }, async () => {
    const node = mockNode();
    const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, liveClaimDeps(node.client));
    check("C65 a malformed relayer key refuses before any call", refusedWith(reply, "unavailable") && node.calls.length === 0);
  });
}

async function checkTokenRefusals() {
  env.TURNSTILE_SECRET_KEY = "check-secret";
  const refusals: [string, Siteverify, FaucetCode][] = [
    ["success false", () => jsonReply({ ...goodAnswer, success: false, "error-codes": [MARKER] }), "bot_check_failed"],
    ["success as the string true", () => jsonReply({ ...goodAnswer, success: "true" }), "bot_check_failed"],
    ["success missing", () => jsonReply({ hostname: "www.dojis.site", action: "faucet" }), "bot_check_failed"],
    ["wrong hostname", () => jsonReply({ ...goodAnswer, hostname: "evil.example" }), "bot_check_failed"],
    ["look-alike hostname", () => jsonReply({ ...goodAnswer, hostname: "www.dojis.site.evil.example" }), "bot_check_failed"],
    ["localhost outside development", () => jsonReply({ ...goodAnswer, hostname: "localhost" }), "bot_check_failed"],
    ["wrong action", () => jsonReply({ ...goodAnswer, action: "login" }), "bot_check_failed"],
    ["no action", () => jsonReply({ success: true, hostname: "www.dojis.site" }), "bot_check_failed"],
    [
      "Cloudflare's always-pass test reply, copied from the live endpoint",
      () => jsonReply({ success: true, hostname: "example.com", "error-codes": [], metadata: { result_with_testing_key: true } }),
      "bot_check_failed",
    ],
    [
      "C82 a made-up token, copied from the live endpoint",
      () => jsonReply({ success: false, "error-codes": ["invalid-input-response"], messages: [] }),
      "bot_check_failed",
    ],
    [
      "C82 a wrong secret, copied from the live endpoint",
      () => jsonReply({ success: false, "error-codes": ["invalid-input-secret"], messages: [] }, 400),
      "unavailable",
    ],
    ["non-200 with a passing body", () => jsonReply(goodAnswer, 500), "unavailable"],
    ["malformed JSON", () => new Response(`<html>${MARKER}</html>`), "unavailable"],
    ["JSON that is not an object", () => new Response("null"), "unavailable"],
    [
      "network error",
      () => {
        throw new Error(MARKER);
      },
      "unavailable",
    ],
  ];
  for (const [name, answer, code] of refusals) {
    stubCloudflare(answer);
    const { node, deps, signs } = setup();
    deps.verifyToken = verifyToken;
    const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps);
    check(`C60 ${name}: ${code}, RPC untouched`, refusedWith(reply, code) && node.calls.length === 0 && signs() === 0);
  }

  stubCloudflare(
    (_form, init) =>
      new Promise((_, reject) => {
        init.signal?.addEventListener("abort", () => reject(new Error(MARKER)));
      }),
  );
  const slow = setup();
  slow.deps.verifyToken = verifyToken;
  const started = Date.now();
  const timedOut = await handleClaim({ body: claimBody(randomWallet()), ip: null }, slow.deps);
  const waited = Date.now() - started;
  check(`C60 a timeout refuses after about 5 s (took ${waited} ms)`, refusedWith(timedOut, "unavailable") && waited >= 4_800 && waited < 6_500);

  await withEnv({ TURNSTILE_SECRET_KEY: undefined }, async () => {
    const before = fetchCalls;
    stubCloudflare(() => jsonReply(goodAnswer));
    const missing = setup();
    missing.deps.verifyToken = verifyToken;
    const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, missing.deps);
    check("C60 a missing secret refuses with no call to Cloudflare", refusedWith(reply, "unavailable") && fetchCalls === before && missing.node.calls.length === 0);
  });

  const seen = new Set<string>();
  stubCloudflare((form) => {
    const token = form.get("response") ?? "";
    if (seen.has(token)) return jsonReply({ success: false, "error-codes": ["timeout-or-duplicate"] });
    seen.add(token);
    return jsonReply(goodAnswer);
  });
  const replay = setup();
  replay.deps.verifyToken = verifyToken;
  const firstUse = await handleClaim({ body: claimBody(randomWallet(), "single-use"), ip: null }, replay.deps);
  const secondUse = await handleClaim({ body: claimBody(randomWallet(), "single-use"), ip: null }, replay.deps);
  check("C60 a token passes once", firstUse.ok);
  check("C60 a replayed token is refused", refusedWith(secondUse, "bot_check_failed"));

  forms.length = 0;
  stubCloudflare(() => jsonReply({ success: false }));
  const sneaky = "abc&secret=forged&remoteip=198.51.100.1&response=other";
  const injection = setup();
  injection.deps.verifyToken = verifyToken;
  await handleClaim({ body: claimBody(randomWallet(), sneaky), ip: null }, injection.deps);
  const form = forms[0];
  check(
    "C60 a token full of form syntax stays one field",
    form !== undefined &&
      form.get("response") === sneaky &&
      form.getAll("response").length === 1 &&
      form.getAll("secret").length === 1 &&
      form.get("secret") === "check-secret" &&
      !form.has("remoteip"),
  );

  for (const hostname of ["www.dojis.site", "dojis.site"]) {
    stubCloudflare(() => jsonReply({ ...goodAnswer, hostname }));
    const { deps } = setup();
    deps.verifyToken = verifyToken;
    check(`C60 ${hostname} passes`, (await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps)).ok);
  }
  await withEnv({ NODE_ENV: "development" }, async () => {
    stubCloudflare(() => jsonReply({ ...goodAnswer, hostname: "localhost" }));
    const { deps } = setup();
    deps.verifyToken = verifyToken;
    check("C60 localhost passes only under development", (await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps)).ok);
  });
}

async function checkOddVerdicts() {
  for (const verdict of [true, "PASS", "", undefined, null, { pass: true }]) {
    const { node, deps, signs } = setup();
    deps.verifyToken = (async () => verdict) as unknown as ClaimDeps["verifyToken"];
    const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps);
    check(`C60 only the exact word pass opens the way, not ${JSON.stringify(verdict)}`, !reply.ok && node.calls.length === 0 && signs() === 0);
  }
}

async function checkIpHandling(route: RouteModule) {
  const post = (headers: Record<string, string>, body = claimBody(randomWallet())) =>
    route.POST(new Request("https://www.dojis.site/api/faucet", { method: "POST", headers, body }));
  const forged = { "x-forwarded-for": "198.51.100.9", "x-real-ip": "198.51.100.9", "cf-connecting-ip": "198.51.100.9", forwarded: "for=198.51.100.9" };

  stubCloudflare(() => jsonReply({ success: false, "error-codes": [MARKER] }));
  forms.length = 0;
  await post({ ...forged, "x-vercel-forwarded-for": IP });
  check("C61 off Vercel every address header is ignored, so remoteip is left out", forms[0] !== undefined && !forms[0].has("remoteip"));

  await withEnv({ VERCEL: "1" }, async () => {
    forms.length = 0;
    await post({ ...forged, "x-vercel-forwarded-for": IP });
    check("C61 on Vercel remoteip is the platform's value and nothing else", forms[0]?.get("remoteip") === IP);

    forms.length = 0;
    await post(forged);
    check("C61 on Vercel with no platform value, remoteip is left out", forms[0] !== undefined && !forms[0].has("remoteip"));

    forms.length = 0;
    await post({ "x-vercel-forwarded-for": "not-an-address" });
    check("C61 a platform value that is not an address is left out", forms[0] !== undefined && !forms[0].has("remoteip"));
  });
  check("C61 no log line holds the IP or the token", !logged.some((line) => line.includes(IP) || line.includes(TOKEN) || line.includes("198.51.100")));
}

async function checkSimulationGate() {
  const wallet = randomWallet();
  const cases: [string, Partial<NodeSetup>, FaucetCode][] = [
    ["paused", { paused: true }, "paused"],
    ["no BTC", { noBtc: true }, "faucet_empty"],
    ["no MUSD", { noMusd: true }, "faucet_empty"],
    ["day full", { dayFull: true }, "none_open"],
    ["already claimed", { claimed: [wallet] }, "already_claimed"],
  ];
  for (const [name, start, code] of cases) {
    const honest = setup(start);
    const reply = await handleClaim({ body: claimBody(wallet), ip: null }, honest.deps);
    check(`C62 ${name}: ${code}, nothing signed, nonce unchanged`, refusedWith(reply, code) && nothingSigned(honest.node, honest.signs()));
    if (code === "none_open") check("C62 day full names when the next claim opens", !reply.ok && reply.nextOpenAt === 1_800_000_000);
  }
  const withLyingViews: [string, Partial<NodeSetup>][] = [...cases.map(([name, start]): [string, Partial<NodeSetup>] => [name, start]), ["hostile recipient", { hostile: [wallet] }]];
  for (const [name, start] of withLyingViews) {
    const lied = setup({ ...start, viewsLie: true });
    const reply = await handleClaim({ body: claimBody(wallet), ip: null }, lied.deps);
    check(
      `C62 ${name} while every view says all is well: the simulation alone refuses, nothing signed`,
      refusedWith(reply, "unavailable") && lied.node.simulations.length === 1 && nothingSigned(lied.node, lied.signs()),
    );
  }

  const hostile = setup({ hostile: [wallet] });
  const hostileReply = await handleClaim({ body: claimBody(wallet), ip: null }, hostile.deps);
  check("C62 hostile recipient: nothing signed", refusedWith(hostileReply, "unavailable") && nothingSigned(hostile.node, hostile.signs()));

  const broken = setup({ simulationBroken: true });
  const brokenReply = await handleClaim({ body: claimBody(wallet), ip: null }, broken.deps);
  check("C62 a simulation that cannot run refuses", refusedWith(brokenReply, "unavailable") && nothingSigned(broken.node, broken.signs()));

  const reads = setup({ readsBroken: true });
  const readsReply = await handleClaim({ body: claimBody(wallet), ip: null }, reads.deps);
  check("C62 a read that fails refuses before any simulation", refusedWith(readsReply, "unavailable") && reads.node.simulations.length === 0 && nothingSigned(reads.node, reads.signs()));

  logged.length = 0;
  const short = setup({ balance: GAS_LIMIT * NORMAL_GAS_PRICE - 1n });
  const shortReply = await handleClaim({ body: claimBody(wallet), ip: null }, short.deps);
  check("C62 a relayer short of one claim's cost refuses, nothing signed", refusedWith(shortReply, "faucet_empty") && nothingSigned(short.node, short.signs()));
  check("C62 the log names the short relayer on its own line", logged.some((line) => line.includes("relayer_short")));

  const enough = setup({ balance: GAS_LIMIT * NORMAL_GAS_PRICE });
  check("C62 a relayer holding exactly one claim's cost sends", (await handleClaim({ body: claimBody(wallet), ip: null }, enough.deps)).ok);
}

async function checkNonces() {
  const wallet = randomWallet();

  const oneServer = setup();
  const parallel = await Promise.all(
    Array.from({ length: 20 }, (_, index) => handleClaim({ body: claimBody(wallet, `token-${index}`), ip: null }, oneServer.deps)),
  );
  const hashes = parallel.filter((reply) => reply.ok);
  check(`C63 20 parallel calls for one address sign at most ${IN_FLIGHT} (signed ${oneServer.signs()})`, oneServer.signs() <= IN_FLIGHT);
  check("C63 exactly one of them gets a hash", hashes.length === 1);
  check("C63 every other one gets busy", parallel.filter((reply) => refusedWith(reply, "busy")).length === 19);
  oneServer.node.mine();
  check("C63 one claim lands and none fails", oneServer.node.counts().landed === 1 && oneServer.node.counts().failed === 0);

  const servers = await Promise.all(
    Array.from(
      { length: 20 },
      (_, index) => import(`../src/server/faucet.ts?server=${index}`) as Promise<FaucetModule>,
    ),
  );
  check("the parallel check below really uses 20 separate module copies", new Set(servers.map((server) => server.handleClaim)).size === 20);
  const sharedNode = mockNode();
  const separate = await Promise.all(
    servers.map((server, index) =>
      server.handleClaim(
        { body: claimBody(wallet, `token-${index}`), ip: null },
        { ...server.liveClaimDeps(sharedNode.client), verifyToken: async () => "pass" },
      ),
    ),
  );
  check("C63 20 separate servers, one address: the node holds one, one hash", sharedNode.queue.length === 1 && separate.filter((reply) => reply.ok).length === 1);
  check("C63 20 separate servers, one address: the rest get busy", separate.filter((reply) => refusedWith(reply, "busy")).length === 19);

  const mixedNode = mockNode();
  const mixed = await Promise.all(
    servers.map((server, index) =>
      server.handleClaim(
        { body: claimBody(randomWallet(), `token-${index}`), ip: null },
        { ...server.liveClaimDeps(mixedNode.client), verifyToken: async () => "pass" },
      ),
    ),
  );
  check("C63 20 separate servers, 20 addresses: one nonce, one hash, the rest busy", mixedNode.queue.length === 1 && mixed.filter((reply) => reply.ok).length === 1 && mixed.filter((reply) => refusedWith(reply, "busy")).length === 19);

  const staggered = setup();
  const inTurn: ClaimReply[] = [];
  for (let index = 0; index < 6; index += 1) {
    inTurn.push(await handleClaim({ body: claimBody(wallet, `turn-${index}`), ip: null }, staggered.deps));
  }
  check(`C63 calls one after another fill at most ${IN_FLIGHT} slots`, staggered.node.queue.length === IN_FLIGHT);
  check("C63 past the limit the route answers busy, never a hash", inTurn.slice(IN_FLIGHT).every((reply) => refusedWith(reply, "busy")));
  staggered.node.mine();
  check(`C63 one lands and at most ${IN_FLIGHT} fail`, staggered.node.counts().landed === 1 && staggered.node.counts().failed <= IN_FLIGHT);

  // Each relayer takes its own nonce, because the route remembers the last head it saw for as long as the module lives.
  const fullQueue = (nonce: number, start: Partial<NodeSetup> = {}) => {
    const rig = setup({ latest: nonce, acceptReplacement: true, ...start });
    rig.node.queue.push({ raw: "0xaa", to: randomWallet(), nonce, gasPrice: NORMAL_GAS_PRICE });
    rig.node.world.pendingExtra = IN_FLIGHT - 1;
    let clock = 1_000_000;
    rig.deps.now = () => clock;
    return {
      ...rig,
      claim: () => handleClaim({ body: claimBody(wallet), ip: null }, rig.deps),
      wait: (ms: number) => {
        clock += ms;
      },
      noSend: () => rig.signs() === 0 && !rig.node.calls.includes("eth_sendRawTransaction"),
    };
  };

  const firstSight = fullQueue(101);
  check("C63 at the limit, first sight of the head: busy, nothing signed", refusedWith(await firstSight.claim(), "busy") && firstSight.noSend());

  const young = fullQueue(102);
  await young.claim();
  young.wait(STUCK_AFTER_MS - 1_000);
  check("C63 at the limit, same head 59 s later: busy, nothing signed", refusedWith(await young.claim(), "busy") && young.noSend());

  const stuck = fullQueue(103);
  await stuck.claim();
  stuck.wait(STUCK_AFTER_MS);
  const replacement = await stuck.claim();
  const replaced = stuck.node.queue[0];
  check("C63 at the limit, same head 60 s later: the claim goes at the head nonce", replacement.ok && replaced?.nonce === 103 && replaced.to === wallet);
  check("C63 the replacement pays 1.2 times the gas price", replaced?.gasPrice === (NORMAL_GAS_PRICE * 12n + 9n) / 10n);
  stuck.wait(1_000);
  check("C63 a replacement restarts the clock: the next claim is busy, nothing signed", refusedWith(await stuck.claim(), "busy") && stuck.signs() === 1);

  const postSizes: number[] = [];
  const batching = createPublicClient({
    transport: http("https://mock.invalid", {
      batch: true,
      retryCount: 0,
      fetchFn: async (_url, init) => {
        const body = JSON.parse(String(init?.body)) as { id: number } | { id: number }[];
        const calls = Array.isArray(body) ? body : [body];
        postSizes.push(calls.length);
        const answers = calls.map(({ id }) => ({ jsonrpc: "2.0", id, result: numberToHex(postSizes.length) }));
        return Response.json(Array.isArray(body) ? answers : answers[0]);
      },
    }),
  });
  const rounds = await readNonces(batching as PublicClient, wallet);
  check(
    `C63 on a batching client the nonce reads leave as ${NONCE_READS} posts, so more than one node can answer, and the highest wins`,
    postSizes.length === NONCE_READS && rounds.latest === NONCE_READS && rounds.pending === NONCE_READS,
  );

  const moved = fullQueue(104);
  await moved.claim();
  moved.node.mine();
  moved.node.world.pendingExtra = IN_FLIGHT;
  moved.wait(STUCK_AFTER_MS);
  check("C63 at the limit, a head that moved restarts the clock: busy after 60 s, nothing signed", refusedWith(await moved.claim(), "busy") && moved.noSend());

  const nearCeiling = fullQueue(106, { gasPrice: CEILING - 1n });
  await nearCeiling.claim();
  nearCeiling.wait(STUCK_AFTER_MS);
  await nearCeiling.claim();
  check("C63 the replacement stays within the ceiling", nearCeiling.node.queue[0]?.gasPrice === CEILING);

  const refusedHead = fullQueue(107, { acceptReplacement: false });
  await refusedHead.claim();
  refusedHead.wait(STUCK_AFTER_MS);
  const refusedReply = await refusedHead.claim();
  check("C63 a replacement the node refuses is busy", refusedWith(refusedReply, "busy") && refusedHead.node.calls.includes("eth_sendRawTransaction"));

  for (let position = 0; position < NONCE_READS; position += 1) {
    const nonce = 110 + position;
    const lagging = setup({ latest: nonce, pendingExtra: IN_FLIGHT - 1, laggingRead: position });
    const lagReply = await handleClaim({ body: claimBody(wallet), ip: null }, lagging.deps);
    check(
      `C63 a lagging node answers read ${position + 1} of ${NONCE_READS}: the signed nonce is the highest pending, and the gap is measured from the highest latest`,
      lagReply.ok && lagging.node.queue[0]?.nonce === nonce + IN_FLIGHT - 1,
    );
  }

  const laggingHead = fullQueue(120, { laggingRead: 1 });
  await laggingHead.claim();
  laggingHead.wait(STUCK_AFTER_MS);
  const laggingHeadReply = await laggingHead.claim();
  check("C63 a lagging node: the replacement takes the highest latest", laggingHeadReply.ok && laggingHead.node.queue[0]?.nonce === 120);

  const crowded = setup({ pendingExtra: IN_FLIGHT - 1 });
  const crowd = await Promise.all(
    Array.from({ length: IN_FLIGHT + 1 }, (_, index) => handleClaim({ body: claimBody(randomWallet(), `crowd-${index}`), ip: null }, crowded.deps)),
  );
  const crowdHashes = crowd.filter((reply) => reply.ok);
  check(`C63 ${IN_FLIGHT + 1} parallel claims one below the limit sign at most ${IN_FLIGHT} (signed ${crowded.signs()})`, crowded.signs() <= IN_FLIGHT);
  check(
    "C63 of those, each hash is a transaction the node holds, and every other caller gets busy",
    crowdHashes.length === crowded.node.queue.length &&
      crowdHashes.every((reply) => crowded.node.queue.some((queued) => keccak256(queued.raw) === reply.hash)) &&
      crowd.filter((reply) => refusedWith(reply, "busy")).length === crowd.length - crowdHashes.length,
  );

  const stale = mockNode({ latest: 9 });
  const staleSend = await liveClaimDeps(stale.client).signAndSend({ to: wallet, nonce: 8, gasPrice: NORMAL_GAS_PRICE });
  check("C63 nonce too low is busy, never a hash", !staleSend.sent && staleSend.code === "busy");

  const known = mockNode();
  const signer = liveClaimDeps(known.client);
  await signer.signAndSend({ to: wallet, nonce: 7, gasPrice: NORMAL_GAS_PRICE });
  const again = await signer.signAndSend({ to: wallet, nonce: 7, gasPrice: NORMAL_GAS_PRICE });
  check("C63 already known is busy, never a hash", !again.sent && again.code === "busy");

  const lost = setup({ sendAnswer: "network_failure" });
  const lostReply = await handleClaim({ body: claimBody(wallet), ip: null }, lost.deps);
  check("C63 a send with no answer is unavailable, never a hash", refusedWith(lostReply, "unavailable"));

  const backwards = setup({ latest: 7, pendingExtra: -2 });
  const backwardsReply = await handleClaim({ body: claimBody(wallet), ip: null }, backwards.deps);
  check("C63 a pending nonce behind the latest one is busy, nothing signed", refusedWith(backwardsReply, "busy") && nothingSigned(backwards.node, backwards.signs()));
}

async function checkFormatAndBudget(route: RouteModule) {
  const wallet = randomWallet();
  const lower = wallet.toLowerCase().slice(2);
  // One letter in the other case keeps the address mixed-case and breaks its checksum.
  const letterAt = wallet.slice(2).search(/[a-fA-F]/) + 2;
  const letter = wallet.charAt(letterAt);
  const swapped = letter === letter.toLowerCase() ? letter.toUpperCase() : letter.toLowerCase();
  const flipped = `${wallet.slice(0, letterAt)}${swapped}${wallet.slice(letterAt + 1)}`;
  const bodies: [string, string][] = [
    ["empty body", ""],
    ["not JSON", "address=0x1"],
    ["JSON null", "null"],
    ["JSON array", "[]"],
    ["JSON string", '"hello"'],
    ["JSON number", "7"],
    ["no address", JSON.stringify({ turnstileToken: TOKEN })],
    ["no token", JSON.stringify({ address: wallet })],
    ["address as a number", JSON.stringify({ address: 7, turnstileToken: TOKEN })],
    ["address as an array", JSON.stringify({ address: [wallet], turnstileToken: TOKEN })],
    ["address as an object", JSON.stringify({ address: { toString: wallet }, turnstileToken: TOKEN })],
    ["token as a number", JSON.stringify({ address: wallet, turnstileToken: 7 })],
    ["token as an object", JSON.stringify({ address: wallet, turnstileToken: {} })],
    ["empty token", JSON.stringify({ address: wallet, turnstileToken: "" })],
    ["token of 2,049 characters", JSON.stringify({ address: wallet, turnstileToken: "a".repeat(2_049) })],
    ["5 KB body", JSON.stringify({ address: wallet, turnstileToken: TOKEN, padding: "a".repeat(5_120) })],
    ["mixed-case address failing its checksum", JSON.stringify({ address: flipped, turnstileToken: TOKEN })],
    ["address too short", JSON.stringify({ address: `0x${lower.slice(2)}`, turnstileToken: TOKEN })],
    ["address with no 0x", JSON.stringify({ address: lower, turnstileToken: TOKEN })],
  ];
  for (const [name, body] of bodies) {
    const { node, deps, signs, tokenChecks } = setup();
    const reply = await handleClaim({ body, ip: null }, deps);
    check(`C64 ${name}: bad_request, no token check, no RPC`, refusedWith(reply, "bad_request") && tokenChecks() === 0 && node.calls.length === 0 && signs() === 0);
  }
  const longest = setup();
  check("C64 a token of exactly 2,048 characters is allowed", (await handleClaim({ body: claimBody(wallet, "a".repeat(2_048)), ip: null }, longest.deps)).ok);

  const validButLong = JSON.stringify({ address: wallet, turnstileToken: TOKEN, padding: "a".repeat(5_120) });
  const oversize = await route.POST(new Request("https://www.dojis.site/api/faucet", { method: "POST", body: validButLong }));
  check("C64 the route refuses a 5 KB body", oversize.status === 400 && ((await oversize.json()) as { code: string }).code === "bad_request");

  let chunksPulled = 0;
  const endless = new ReadableStream<Uint8Array>({
    pull: (controller) => {
      chunksPulled += 1;
      controller.enqueue(new Uint8Array(1_024));
    },
  });
  const flood = await route.POST(
    new Request("https://www.dojis.site/api/faucet", { method: "POST", body: endless, duplex: "half" } as RequestInit),
  );
  check(`C64 an endless body stops at the 4 KB cap (pulled ${chunksPulled} KB)`, flood.status === 400 && chunksPulled <= 8);

  const verifyFirst = setup();
  verifyFirst.deps.verifyToken = async () => {
    verifyFirst.node.calls.push("token");
    return "pass";
  };
  await handleClaim({ body: claimBody(wallet), ip: null }, verifyFirst.deps);
  const steps = verifyFirst.node.calls;
  check(
    "C64 the order is token, reads, simulation, send",
    steps[0] === "token" && steps.at(-1) === "eth_sendRawTransaction" && steps.at(-2) === "eth_call" && steps.includes("eth_getBalance"),
  );

  const hungRead = setup({ hang: "eth_gasPrice" });
  const startedRead = Date.now();
  const hungReply = await handleClaim({ body: claimBody(wallet), ip: null }, hungRead.deps);
  const tookRead = Date.now() - startedRead;
  check(`C64 a hung RPC ends at the 8 s budget (took ${tookRead} ms)`, refusedWith(hungReply, "unavailable") && tookRead >= 7_800 && tookRead < 9_000 && hungRead.signs() === 0);

  let clock = 0;
  const lateToken = setup();
  lateToken.deps.now = () => clock;
  lateToken.deps.verifyToken = async () => {
    clock = 8_001;
    return "pass";
  };
  const lateReply = await handleClaim({ body: claimBody(wallet), ip: null }, lateToken.deps);
  check("C64 a budget spent on the token check stops before any RPC call", refusedWith(lateReply, "unavailable") && lateToken.node.calls.length === 0);

  clock = 0;
  const lateSim = setup({ hang: "eth_call" });
  lateSim.deps.now = () => clock;
  lateSim.deps.verifyToken = async () => {
    clock = 7_950;
    return "pass";
  };
  const lateSimReply = await handleClaim({ body: claimBody(wallet), ip: null }, lateSim.deps);
  check("C64 the budget holds for a hung read near the deadline", refusedWith(lateSimReply, "unavailable") && lateSim.signs() === 0);

  const hungSend = setup({ hang: "eth_sendRawTransaction" });
  clock = 0;
  hungSend.deps.now = () => clock;
  hungSend.deps.verifyToken = async () => {
    clock = 7_900;
    return "pass";
  };
  const hungSendReply = await handleClaim({ body: claimBody(wallet), ip: null }, hungSend.deps);
  check("C64 a send that never answers is unavailable, never a hash", refusedWith(hungSendReply, "unavailable"));

  const thrower = setup();
  thrower.deps.verifyToken = () => {
    throw new Error(MARKER);
  };
  const thrownReply = await handleClaim({ body: claimBody(wallet), ip: null }, thrower.deps);
  check("C64 a dependency that throws is a refusal, not a crash", refusedWith(thrownReply, "unavailable"));

  check("C64 POST is the only method the route exports", Object.keys(route).sort().join(",") === "POST,maxDuration");
}

async function checkClosedReplies() {
  logged.length = 0;
  const wallet = randomWallet();
  const replies: ClaimReply[] = [];
  const noisy: Partial<NodeSetup>[] = [
    { paused: true },
    { noBtc: true },
    { dayFull: true },
    { claimed: [wallet] },
    { hostile: [wallet] },
    { viewsLie: true, paused: true },
    { simulationBroken: true },
    { readsBroken: true },
    { sendAnswer: "network_failure" },
    { chainId: 31612 },
    { gasPrice: 1n << 60n },
  ];
  for (const start of noisy) {
    const { deps } = setup(start);
    replies.push(await handleClaim({ body: claimBody(wallet), ip: IP }, deps));
  }
  stubCloudflare(() => {
    throw new Error(MARKER);
  });
  const token = setup();
  token.deps.verifyToken = verifyToken;
  replies.push(await handleClaim({ body: claimBody(wallet), ip: IP }, token.deps));

  const wire = JSON.stringify(replies);
  check("C64 no reply carries upstream text", !wire.includes("UPSTREAM") && !wire.includes("rpc.internal"));
  check(
    "C64 every refusal is on the closed list and carries nothing else",
    replies.every(
      (reply) =>
        !reply.ok &&
        (FAUCET_CODES as readonly string[]).includes(reply.code) &&
        Object.keys(reply).every((key) => ["ok", "code", "nextOpenAt"].includes(key)),
    ),
  );
  check("C64 no log line carries upstream text", !logged.some((line) => line.includes("UPSTREAM") || line.includes("rpc.internal")));
  check("C64 no log line carries the IP or the token", !logged.some((line) => line.includes(IP) || line.includes(TOKEN)));
  const hostileBody = JSON.stringify({ address: "0x<script>\n{\"forged\":1}", turnstileToken: TOKEN });
  logged.length = 0;
  const { deps } = setup();
  await handleClaim({ body: hostileBody, ip: null }, deps);
  check("C64 text a caller typed never reaches the log", logged.length === 1 && logged[0] === JSON.stringify({ faucet: "bad_request", wallet: null }));
}

async function checkPreviewBuilds(route: RouteModule) {
  for (const stage of ["preview", "development", ""]) {
    await withEnv({ VERCEL_ENV: stage }, async () => {
      const { node, deps, signs, tokenChecks } = setup();
      const reply = await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps);
      check(`C82 VERCEL_ENV "${stage}": refused before any token check or RPC`, refusedWith(reply, "unavailable") && tokenChecks() === 0 && node.calls.length === 0 && signs() === 0);
    });
  }
  await withEnv({ VERCEL_ENV: "preview" }, async () => {
    const before = fetchCalls;
    const answer = await route.POST(new Request("https://preview.example/api/faucet", { method: "POST", body: claimBody(randomWallet()) }));
    check("C82 a preview build's route refuses", answer.status === 503 && ((await answer.json()) as { code: string }).code === "unavailable" && fetchCalls === before);
  });
  await withEnv({ VERCEL_ENV: "production" }, async () => {
    const { deps } = setup();
    check("C82 production is allowed through", (await handleClaim({ body: claimBody(randomWallet()), ip: null }, deps)).ok);
  });

  stubCloudflare(() => jsonReply({ success: false, "error-codes": ["invalid-input-response"], messages: [] }));
  await withEnv({ TURNSTILE_SECRET_KEY: "check-secret" }, async () => {
    const answer = await route.POST(new Request("https://www.dojis.site/api/faucet", { method: "POST", body: claimBody(randomWallet(), "made-up-token") }));
    check("C82 a POST with a made-up token comes back as the Turnstile refusal", answer.status === 403 && ((await answer.json()) as { code: string }).code === "bot_check_failed");
  });
}

function checkKeyPlacement() {
  const root = resolve(import.meta.dirname, "../src");
  const readers = (readdirSync(root, { recursive: true, encoding: "utf8" }) as string[])
    .filter((file) => /\.tsx?$/.test(file))
    .filter((file) => /RELAYER_PRIVATE_KEY|TURNSTILE_SECRET_KEY/.test(readFileSync(resolve(root, file), "utf8")));
  check("C65 only src/server/faucet.ts names either key", readers.length === 1 && readers[0]?.replaceAll("\\", "/") === "server/faucet.ts");
  const source = readFileSync(resolve(root, "server/faucet.ts"), "utf8");
  check('C65 the server module opens with import "server-only"', source.startsWith('import "server-only";'));
  const codes = readFileSync(resolve(root, "lib/faucet-codes.ts"), "utf8");
  check("C65 the shared codes file pulls in no server code", [...codes.matchAll(/^import .*$/gm)].every(([line]) => line.startsWith("import type")));
}

async function runMocks() {
  // A throwaway key: a mock run must never be able to touch the real relayer.
  const throwaway = generatePrivateKey();
  env.RELAYER_PRIVATE_KEY = throwaway;
  for (const name of ["VERCEL", "VERCEL_ENV", "NODE_ENV"]) delete env[name];
  const route: RouteModule = await import("../src/app/api/faucet/route");

  await checkTransactionShape();
  await checkSigningLimits();
  await checkTokenRefusals();
  await checkOddVerdicts();
  await checkIpHandling(route);
  await checkSimulationGate();
  await checkNonces();
  await checkFormatAndBudget(route);
  await checkClosedReplies();
  await checkPreviewBuilds(route);
  checkKeyPlacement();
  globalThis.fetch = realFetch;
}

// The public RPC is several nodes behind one address, and a lagging one answers "not found" for a mined transaction.
async function readMined(client: PublicClient, hash: Hex) {
  for (let tries = 1; ; tries += 1) {
    try {
      return await client.getTransaction({ hash });
    } catch (error) {
      if (tries === 6) throw error;
      await new Promise((done) => setTimeout(done, 1_000));
    }
  }
}

async function runLive() {
  const client: PublicClient = createPublicClient({ chain: mezoTestnetChain, transport: http() });
  const faucet = { address: FAUCET, abi: faucetAbi } as const;
  const real = liveClaimDeps();
  if (real.relayer === null) {
    process.stderr.write("RELAYER_PRIVATE_KEY is not set in this process\n");
    process.exit(2);
  }
  const deps: ClaimDeps = { ...real, verifyToken: async () => "pass" };

  const open = await client.readContract({ ...faucet, functionName: "claimsOpen" });
  process.stdout.write(`faucet ${FAUCET}, relayer ${real.relayer}, claims open now: ${open}\n`);
  if (open === 0n) {
    const nextOpen = await client.readContract({ ...faucet, functionName: "nextOpenAt" });
    process.stderr.write(`no kit can go out now (nextOpenAt ${nextOpen}), so no live claim was sent\n`);
    process.exit(3);
  }

  const [btcKit, musdKit] = await Promise.all([
    client.readContract({ ...faucet, functionName: "btcPerClaim" }),
    client.readContract({ ...faucet, functionName: "musdPerClaim" }),
  ]);
  const wallet = randomWallet();
  process.stdout.write(`fresh wallet ${wallet}\n`);

  const started = Date.now();
  const reply = await handleClaim({ body: claimBody(wallet, "live-run"), ip: null }, deps);
  process.stdout.write(`handleClaim replied in ${Date.now() - started} ms: ${JSON.stringify(reply)}\n`);
  check("handleClaim returns a hash", reply.ok);
  if (!reply.ok) finish();
  const { hash } = reply;

  // How the public node counts a transaction it holds but has not mined. The in-flight limit stands on this reading.
  const [latest, pending] = await Promise.all([
    client.getTransactionCount({ address: real.relayer, blockTag: "latest" }),
    client.getTransactionCount({ address: real.relayer, blockTag: "pending" }),
  ]);
  process.stdout.write(`right after the send: latest nonce ${latest}, pending nonce ${pending}
`);

  const receipt = await client.waitForTransactionReceipt({ hash, timeout: 120_000 });
  const claimedLogs = parseEventLogs({ abi: faucetAbi, eventName: "Claimed", logs: receipt.logs });
  const log = claimedLogs.find((entry) => entry.args.to === wallet && getAddress(entry.address) === FAUCET);
  const [btc, musd, claimed] = await Promise.all([
    client.getBalance({ address: wallet }),
    client.readContract({ address: addressBook[31611].musd, abi: erc20Abi, functionName: "balanceOf", args: [wallet] }),
    client.readContract({ ...faucet, functionName: "claimed", args: [wallet] }),
  ]);
  check("the transaction succeeded", receipt.status === "success");
  check("it came from the relayer and went to the faucet", receipt.from.toLowerCase() === real.relayer.toLowerCase() && receipt.to?.toLowerCase() === FAUCET.toLowerCase());
  check("the faucet's Claimed event names the wallet", log !== undefined);
  check(`the wallet holds ${formatUnits(btcKit, 18)} BTC`, btc === BigInt(btcKit));
  check(`the wallet holds ${formatUnits(musdKit, 18)} MUSD`, musd === BigInt(musdKit));
  check("claimed(wallet) reads true", claimed);

  const second = await handleClaim({ body: claimBody(wallet, "live-run-2"), ip: null }, deps);
  process.stdout.write(`second claim for the same wallet: ${JSON.stringify(second)}\n`);
  check("a second claim for that wallet is already_claimed", refusedWith(second, "already_claimed"));

  // Mezo's receipts carry no effectiveGasPrice, so the price comes from the mined transaction.
  const mined = await readMined(client, hash);
  const gasPrice = mined.gasPrice ?? 0n;
  check("C59 the mined transaction has the gas limit, no value, and a price within the ceiling", mined.gas === GAS_LIMIT && mined.value === 0n && gasPrice > 0n && gasPrice <= CEILING);
  process.stdout.write(
    `block ${receipt.blockNumber}, gas used ${receipt.gasUsed}, gas price ${gasPrice} wei, relayer paid ${formatUnits(receipt.gasUsed * gasPrice, 18)} BTC\n`,
  );
  process.stdout.write(`hash ${hash}\n`);
}

if (LIVE) await runLive();
else await runMocks();
finish();

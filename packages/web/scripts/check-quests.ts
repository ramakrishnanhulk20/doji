import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  encodeAbiParameters,
  encodeEventTopics,
  getAddress,
  http,
  parseAbi,
  toEventSelector,
  toHex,
  type Abi,
  type AbiEvent,
  type Address,
  type Hex,
} from "viem";
import { creditMarketsAbi } from "../src/abi/creditMarkets";
import { loanManagerAbi } from "../src/abi/loanManager";
import { payDownAbi } from "../src/abi/payDown";
import { unitMarketAbi } from "../src/abi/unitMarket";
import { parseAddress } from "../src/lib/address";
import { addressBook } from "../src/lib/addresses";
import { mezoTestnetChain } from "../src/lib/chains";
import { dojiWallets, isDojiWallet } from "../src/lib/doji-wallets";
import { compareProgress, computeProgress, walletsIn, type BonusEntry, type WalletProgress } from "../src/lib/quests/exp";
import { decodeQuestLog, normalizeLog, readExplorerLogs, readRecentLogs, stampLogs, type ExplorerQuery, type NormalizedLog } from "../src/lib/quests/logs";
import { RANKS, nextRank, rankOf } from "../src/lib/quests/ranks";
import { readWalletProgress } from "../src/lib/quests/read-wallet";
import { CONTRACTS, EVENTS, FROM_BLOCK, QUESTS, QUEST_EVENTS, type EventName } from "../src/lib/quests/table";

// The quest engine on fixtures, then read-only on live Mezo testnet. No key is involved and nothing is sent.
// Fixtures stand in for the explorer and the node at the fetch boundary, so the real URL builder, pager, normaliser,
// decoder and EXP function all run. It does not cover: the leaderboard route's caching and headers (proved with curl
// against a running server), the page that will show this, or a real redirect from the real explorer.

// read-all.ts refuses to load outside a Next server build. This script is the one other place allowed to run it.
registerHooks({
  resolve: (specifier, context, next) =>
    specifier === "server-only" ? { url: "data:text/javascript,", shortCircuit: true } : next(specifier, context),
});
const { leaderboardRows, readAllProgress } = await import("../src/lib/quests/read-all");

let failures = 0;
const check = (ok: boolean, text: string) => {
  if (!ok) failures += 1;
  console.log(`  ${ok ? "ok" : "FAIL"}: ${text}`);
};
const section = (title: string) => console.log(`\n== ${title}`);

const here = dirname(fileURLToPath(import.meta.url));
const ALICE = getAddress("0xa11ce00000000000000000000000000000000001");
const BOB = getAddress("0xb0b0000000000000000000000000000000000002");
const CAROL = getAddress("0xca401000000000000000000000000000000000c3");
const LOOKALIKE = getAddress("0x10071a11ce000000000000000000000000000000");
const POOL = getAddress("0x0e6bd7e52e4491320012f8c9e6161cd915bb0d19");
const BASE = FROM_BLOCK + 100;
/** Alice's checksummed address with one letter's case flipped, which keeps it mixed-case and breaks the checksum. */
const badChecksum = ALICE.replace(/[a-fA-F]/, (letter) => (letter === letter.toLowerCase() ? letter.toUpperCase() : letter.toLowerCase())) as Address;

type Raw = Record<string, unknown>;
type Place = { emitter?: Address; block?: number; index?: number; hash?: Hex; removed?: boolean };

let serial = 0;
const blockTimeOf = (block: number) => 1_800_000_000 + block;

/** A log as the explorer returns it. Any field not named defaults to 1, or an unrelated address. */
function raw(name: EventName, args: Record<string, unknown>, place: Place = {}): Raw {
  serial += 1;
  const event = EVENTS[name];
  const value = (input: { name?: string; type: string }) =>
    args[input.name as string] ?? (input.type === "address" ? POOL : 1n);
  const indexed = Object.fromEntries(event.abi.inputs.filter((input) => input.indexed).map((input) => [input.name, value(input)]));
  const plain = event.abi.inputs.filter((input) => !input.indexed);
  const block = place.block ?? BASE + serial;
  return {
    address: (place.emitter ?? CONTRACTS[event.contract]).toLowerCase(),
    topics: encodeEventTopics({ abi: [event.abi], eventName: name, args: indexed } as never),
    data: plain.length === 0 ? "0x" : encodeAbiParameters(plain, plain.map(value) as never),
    blockNumber: toHex(block),
    logIndex: toHex(place.index ?? 0),
    timeStamp: toHex(blockTimeOf(block)),
    transactionHash: place.hash ?? toHex(serial, { size: 32 }),
    ...(place.removed === undefined ? {} : { removed: place.removed }),
  };
}

const normal = (log: Raw) => normalizeLog(log) as NormalizedLog;
const progressOf = (raws: readonly Raw[], wallet: Address = ALICE, bonus: readonly BonusEntry[] = []) =>
  computeProgress(wallet, { logs: raws.map(normal), complete: true }, bonus);
const done = (progress: WalletProgress) => progress.quests.filter((quest) => quest.done).map((quest) => quest.id);
const earned = (progress: WalletProgress, id: string) => done(progress).includes(id as never);

type Reply = Response | "continue";
type World = {
  logs: readonly Raw[];
  /** The explorer has not indexed logs above this block, and its height call says so. Left out, it is level with the head. */
  indexedUpTo?: number;
  latest?: number;
  /** Takes over one request, by its explorer page number for a topic0 or by host. */
  override?: (url: URL, init: RequestInit | undefined) => Promise<Reply> | Reply;
};

const realFetch = globalThis.fetch;

const blockOf = (log: Raw) => Number(log.blockNumber);
const headOf = (world: World) => world.latest ?? Math.max(BASE, ...world.logs.map(blockOf)) + 5;
const sorted = (logs: readonly Raw[]) => [...logs].sort((a, b) => blockOf(a) - blockOf(b) || Number(a.logIndex) - Number(b.logIndex));

function explorerReply(world: World, url: URL): Response {
  const from = Number(url.searchParams.get("fromBlock"));
  const to = url.searchParams.get("toBlock");
  const address = url.searchParams.get("address")?.toLowerCase();
  const wanted = [0, 1, 2, 3].map((topic) => url.searchParams.get(`topic${topic}`));
  const rows = sorted(world.logs)
    .filter((log) => log.address === address && blockOf(log) >= from && (to === "latest" || blockOf(log) <= Number(to)))
    .filter((log) => blockOf(log) <= (world.indexedUpTo ?? Number.MAX_SAFE_INTEGER))
    .filter((log) => wanted.every((topic, at) => topic === null || (log.topics as Hex[])[at]?.toLowerCase() === topic.toLowerCase()))
    .slice(0, 1_000);
  return Response.json(rows.length === 0 ? { message: "No logs found", result: [], status: "0" } : { message: "OK", result: rows, status: "1" });
}

function nodeReply(world: World, body: { method: string; params: unknown[] }): Response {
  const result = (value: unknown) => Response.json({ jsonrpc: "2.0", id: 1, result: value });
  const { method, params } = body;
  if (method === "eth_blockNumber") return result(toHex(headOf(world)));
  if (method === "eth_getBlockByNumber") return result({ timestamp: toHex(blockTimeOf(Number(params[0]))) });
  if (method === "eth_getTransactionReceipt") {
    const logs = world.logs.filter((log) => log.transactionHash === params[0]);
    const foreign = { ...(logs[0] ?? {}), address: "0x118917a40faf1cd7a13db0ef56c86de7973ac503" };
    return result({ transactionHash: params[0], logs: [foreign, ...logs] });
  }
  if (method === "eth_getLogs") {
    const filter = params[0] as { address: string[]; topics: string[][]; fromBlock: string };
    const emitters = filter.address.map((address) => address.toLowerCase());
    const topics = filter.topics[0] as string[];
    const rows = sorted(world.logs).filter(
      (log) => emitters.includes(log.address as string) && topics.includes((log.topics as Hex[])[0] as string) && blockOf(log) >= Number(filter.fromBlock),
    );
    // The node leaves the explorer's time out and sends a blockTimestamp of 0x0, as Mezo's does.
    return result(rows.map(({ timeStamp: _time, ...log }) => ({ ...log, blockTimestamp: "0x0", removed: log.removed ?? false })));
  }
  return Response.json({ jsonrpc: "2.0", id: 1, error: { code: -32601, message: "unknown method" } });
}

type Traffic = { hosts: Set<string>; calls: number; peak: number; everyCallGuarded: boolean };

const isHeightCall = (url: URL) => url.host === "api.explorer.test.mezo.org" && url.pathname === "/api/v2/blocks";

function stand(world: World): Traffic {
  const traffic: Traffic = { hosts: new Set(), calls: 0, peak: 0, everyCallGuarded: true };
  let inFlight = 0;
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    traffic.hosts.add(url.host);
    traffic.calls += 1;
    inFlight += 1;
    traffic.peak = Math.max(traffic.peak, inFlight);
    if (init?.redirect !== "error" || !(init.signal instanceof AbortSignal)) traffic.everyCallGuarded = false;
    try {
      await new Promise((settle) => setTimeout(settle, 1));
      const taken = (await world.override?.(url, init)) ?? "continue";
      if (taken !== "continue") return taken;
      if (isHeightCall(url)) return Response.json({ items: [{ height: world.indexedUpTo ?? headOf(world) }] });
      if (url.host === "api.explorer.test.mezo.org") return explorerReply(world, url);
      if (url.host === "rpc.test.mezo.org") return nodeReply(world, JSON.parse(String(init?.body)));
      throw new Error(`a request went to ${url.host}`);
    } finally {
      inFlight -= 1;
    }
  }) as typeof fetch;
  return traffic;
}

const borrowedQuery: ExplorerQuery = { event: EVENTS.Borrowed, match: { field: "borrower", wallet: ALICE } };
const fullPage = (first: number, patch: (at: number) => Raw = () => ({})) => {
  const template = raw("Borrowed", { borrower: ALICE, tokenId: 1n }, { block: first });
  return Array.from({ length: 1_000 }, (_, at) => ({
    ...template,
    blockNumber: toHex(first + at),
    logIndex: toHex(0),
    transactionHash: toHex(first + at, { size: 32 }),
    ...patch(at),
  }));
};
const explorerOnly = (url: URL) => url.host === "api.explorer.test.mezo.org" && url.searchParams.get("topic0") === EVENTS.Borrowed.topic0;

section("C67: only Doji's contracts can earn EXP");
{
  const borrowed = (place: Place = {}) => raw("Borrowed", { borrower: ALICE }, place);
  check(progressOf([borrowed()]).exp === 200, "control: a Wave 2 Borrowed earns 200");
  check(progressOf([borrowed({ emitter: LOOKALIKE })]).exp === 0, "a look-alike contract with the same event earns 0");
  check(progressOf([borrowed({ emitter: addressBook[31611].legacyLoanManager })]).exp === 0, "an old-pair log earns 0");
  check(progressOf([borrowed({ block: FROM_BLOCK - 1 })]).exp === 0, "a Wave 2 log before the deploy block earns 0");
  check(progressOf([borrowed({ block: FROM_BLOCK })]).exp === 200, "a log in the deploy block itself counts");
  check(normalizeLog(borrowed({ removed: true })) === null, "a removed log is dropped by the normaliser");

  const removedWorld = { logs: [borrowed({ removed: true })] };
  stand(removedWorld);
  const recent = await readRecentLogs();
  check(recent.logs.length === 0 && !recent.complete, "a removed log from the node earns 0 and marks the read incomplete");

  const lying = { ...borrowed({ emitter: LOOKALIKE }), address: LOOKALIKE.toLowerCase() };
  stand({ logs: [], override: (url) => (explorerOnly(url) ? Response.json({ message: "OK", result: [lying] }) : "continue") });
  const answered = await readWalletProgress(ALICE);
  check(answered.exp === 0 && !answered.complete, "an explorer reply holding a look-alike log earns 0 and marks the read incomplete");

  const closed = encodeEventTopics({ abi: parseAbi(["event LoanClosed(uint256 indexed tokenId, uint64 indexed maturity)"]), eventName: "LoanClosed" });
  const notInTable = { ...borrowed(), topics: [closed[0], toHex(1n, { size: 32 }), toHex(1n, { size: 32 })] };
  check(decodeQuestLog(normal(notInTable)) === null, "an event from a table contract that is not in the table earns nothing");

  const tampered = { ...borrowed(), data: "0x00" };
  check(progressOf([tampered]).exp === 0, "a log whose data does not decode earns 0");
}

section("C66: one wallet in any spelling is one row");
{
  const lower = ALICE.toLowerCase() as Address;
  const upper = `0x${ALICE.slice(2).toUpperCase()}` as Address;
  const wordOf = (spelling: string) => `0x${"0".repeat(24)}${spelling.slice(2)}`;
  const spelled = (name: EventName, args: Record<string, unknown>, field: 1 | 2, spelling: string) => {
    const log = raw(name, args);
    const topics = [...(log.topics as string[])];
    topics[field] = wordOf(spelling);
    return { ...log, topics };
  };
  const logs = [
    spelled("Borrowed", { borrower: ALICE }, 2, lower),
    spelled("Listed", { seller: ALICE }, 2, upper),
    spelled("UnitsClaimed", { account: ALICE }, 1, ALICE),
  ];
  const read = { logs: logs.map(normal), complete: true };
  check(walletsIn(read).length === 1, "three topic spellings group as one wallet");
  const forms = [lower, upper, ALICE].map((form) => computeProgress(form, read, []));
  check(forms.every((form) => form.exp === 450 && form.address === ALICE), "lower, upper and checksum spellings give one total, 450");
  const bonus = [{ address: lower, exp: 70, reason: "a bug", link: "https://example.com" }];
  const rows = leaderboardRows(walletsIn(read).map((wallet) => computeProgress(wallet, read, bonus)));
  check(rows.length === 1 && rows[0]?.exp === 520, "a bonus entry in another spelling lands on the same row");
  let refused = false;
  try {
    computeProgress(badChecksum, read, []);
  } catch {
    refused = true;
  }
  check(refused && parseAddress(badChecksum) === null, "a bad mixed-case checksum is refused");
}

section("C68: conditions on the table's rows");
{
  const shared = toHex(9_001, { size: 32 });
  const filled = raw("Filled", { maker: ALICE }, { hash: shared });
  check(!earned(progressOf([filled, raw("Borrowed", { borrower: ALICE }, { hash: shared })]), "stranger"), "a Filled whose Borrowed is by the same wallet earns no stranger");
  check(earned(progressOf([filled, raw("Borrowed", { borrower: BOB }, { hash: shared })]), "stranger"), "control: a Filled whose Borrowed is by another wallet earns stranger");
  check(!earned(progressOf([filled, raw("Borrowed", { borrower: BOB })]), "stranger"), "a Borrowed in another transaction earns no stranger");

  const ownList = raw("Listed", { listingId: 5n, seller: ALICE });
  const bought = raw("Bought", { listingId: 5n, buyer: ALICE });
  check(!earned(progressOf([ownList, bought]), "buy"), "a Bought from your own listing earns no buy");
  check(earned(progressOf([raw("Listed", { listingId: 5n, seller: BOB }), bought]), "buy"), "control: a Bought from another seller earns buy");
  check(!earned(progressOf([bought]), "buy"), "a Bought with no Listed earns no buy");

  check(!earned(progressOf([raw("Harvested", { caller: ALICE, musdRepaid: 0n })]), "harvest"), "a Harvested with musdRepaid 0 earns no harvest (F45)");
  check(earned(progressOf([raw("Harvested", { caller: ALICE, musdRepaid: 1n })]), "harvest"), "control: a Harvested that repaid earns harvest, on any loan");

  const deposited = raw("Deposited", { tokenId: 7n, borrower: ALICE }, { block: BASE + 10 });
  const voted = (block: number, voter: Address = CONTRACTS.loanManager) => raw("Voted", { voter, pool: POOL, tokenId: 7n }, { block });
  const lost = (name: "Withdrawn" | "Purchased" | "Settled", block: number) => raw(name, { tokenId: 7n, borrower: ALICE, buyer: BOB }, { block });
  check(earned(progressOf([deposited, voted(BASE + 20)]), "vote"), "control: a vote while holding earns vote");
  check(!earned(progressOf([deposited, lost("Withdrawn", BASE + 15), voted(BASE + 20)]), "vote"), "a position after Withdrawn earns no vote for w");
  check(!earned(progressOf([deposited, lost("Purchased", BASE + 15), voted(BASE + 20)]), "vote"), "a position after Purchased earns no vote for w");
  check(!earned(progressOf([deposited, lost("Settled", BASE + 15), voted(BASE + 20)]), "vote"), "a position after Settled earns no vote for w");
  check(!earned(progressOf([deposited, voted(BASE + 5)]), "vote"), "a vote before the deposit earns no vote");
  check(earned(progressOf([deposited, voted(BASE + 10)]), "vote"), "a vote in the deposit's own block counts");
  check(earned(progressOf([deposited, lost("Withdrawn", BASE + 20), voted(BASE + 20)]), "vote"), "a vote in the block it left counts, it was not lost before that block");
  const backAgain = raw("Deposited", { tokenId: 7n, borrower: ALICE }, { block: BASE + 18 });
  check(earned(progressOf([deposited, lost("Withdrawn", BASE + 15), backAgain, voted(BASE + 20)]), "vote"), "a position that came back counts");
  check(!earned(progressOf([deposited, voted(BASE + 20, BOB)]), "vote"), "a vote by anyone but LoanManager earns no vote");
  check(!earned(progressOf([voted(BASE + 20)]), "vote"), "another wallet's position earns no vote");

  const operator = (who: Address) => raw("RewardOperatorSet", { tokenId: 7n, operator: who }, { block: BASE + 12 });
  check(earned(progressOf([deposited, operator(CONTRACTS.payDown)]), "paydown"), "control: naming PayDown earns paydown");
  check(!earned(progressOf([deposited, operator(BOB)]), "paydown"), "naming anyone else earns no paydown");
  check(!earned(progressOf([deposited, raw("Repaid", { tokenId: 8n, payer: ALICE })]), "repay"), "repaying someone else's position earns no repay");
  check(earned(progressOf([deposited, raw("Repaid", { tokenId: 7n, payer: ALICE }, { block: BASE + 12 })]), "repay"), "control: repaying your own earns repay");

  const posted = raw("OfferPosted", { offerId: 3n, maker: ALICE });
  check(!earned(progressOf([posted]), "parked"), "a plain offer earns no parked");
  check(!earned(progressOf([posted, raw("OfferParked", { offerId: 4n })]), "parked"), "another offer's parking earns no parked");
  check(earned(progressOf([posted, raw("OfferParked", { offerId: 3n })]), "parked"), "control: the same offer parked earns parked");

  check(!earned(progressOf([raw("Purchased", { buyer: ALICE, borrower: ALICE })]), "auction"), "buying your own position earns no auction");
  check(earned(progressOf([raw("Purchased", { buyer: ALICE, borrower: BOB })]), "auction"), "control: buying another's position earns auction");

  const amountRows: readonly [string, EventName, (amount: bigint) => Raw[]][] = [
    ["kit", "Claimed", (amount) => [raw("Claimed", { to: ALICE, btc: amount, musd: amount })]],
    ["borrow", "Borrowed", (amount) => [raw("Borrowed", { borrower: ALICE, principal: amount })]],
    ["repay", "Repaid", (amount) => [deposited, raw("Repaid", { tokenId: 7n, payer: ALICE, amount }, { block: BASE + 12 })]],
    ["parked", "OfferPosted", (amount) => [raw("OfferPosted", { offerId: 3n, maker: ALICE, amount }), raw("OfferParked", { offerId: 3n })]],
    ["stranger", "Filled", (amount) => [raw("Filled", { maker: ALICE, principal: amount }, { hash: shared }), raw("Borrowed", { borrower: BOB }, { hash: shared })]],
    ["units", "UnitsClaimed", (amount) => [raw("UnitsClaimed", { account: ALICE, units: amount })]],
    ["sell", "Listed", (amount) => [raw("Listed", { seller: ALICE, units: amount })]],
    ["buy", "Bought", (amount) => [raw("Listed", { listingId: 6n, seller: BOB }), raw("Bought", { listingId: 6n, buyer: ALICE, cost: amount })]],
    ["payout", "Redeemed", (amount) => [raw("Redeemed", { account: ALICE, musdOut: amount, btcOut: amount })]],
    ["payout", "CollectedWithdrawn", (amount) => [raw("CollectedWithdrawn", { account: ALICE, unitsAdded: 0n, musdOut: amount, btcOut: amount })]],
    ["auction", "Purchased", (amount) => [raw("Purchased", { buyer: ALICE, borrower: BOB, price: amount })]],
  ];
  for (const [id, name, logs] of amountRows) {
    check(!earned(progressOf(logs(0n)), id), `a ${name} that moved nothing earns no ${id} (F45)`);
    check(earned(progressOf(logs(1n)), id), `control: a ${name} that moved something earns ${id}`);
  }
  check(earned(progressOf([raw("CollectedWithdrawn", { account: ALICE, musdOut: 0n, btcOut: 1n })]), "payout"), "a CollectedWithdrawn that paid only BTC earns payout");
  check(earned(progressOf([raw("Redeemed", { account: ALICE, musdOut: 0n, btcOut: 1n })]), "payout"), "a Redeemed that paid only BTC earns payout");
  check(earned(progressOf([raw("Claimed", { to: ALICE, btc: 0n, musd: 1n })]), "kit"), "a kit of MUSD alone earns kit");

  const twice = progressOf([raw("Borrowed", { borrower: ALICE }, { block: BASE + 40 }), raw("Borrowed", { borrower: ALICE }, { block: BASE + 30 })]);
  check(twice.exp === 200 && twice.quests.find((quest) => quest.id === "borrow")?.at === blockTimeOf(BASE + 30), "a quest counts once, and shows its earliest log's block time");
}

// One world where Alice finishes every quest a log can prove, and Bob and Carol do a little.
const shared = toHex(9_100, { size: 32 });
const world = [
  raw("Claimed", { to: ALICE }),
  raw("Deposited", { tokenId: 7n, borrower: ALICE }),
  raw("Borrowed", { tokenId: 7n, borrower: ALICE }),
  raw("Voted", { voter: CONTRACTS.loanManager, pool: POOL, tokenId: 7n }),
  raw("RewardOperatorSet", { tokenId: 7n, operator: CONTRACTS.payDown }),
  raw("Repaid", { tokenId: 7n, payer: ALICE }),
  raw("Rolled", { tokenId: 7n }),
  raw("Harvested", { tokenId: 7n, caller: ALICE, musdRepaid: 5n }),
  raw("Withdrawn", { tokenId: 7n, borrower: ALICE }),
  raw("OfferPosted", { offerId: 1n, maker: ALICE }),
  raw("OfferParked", { offerId: 1n }),
  raw("Filled", { offerId: 1n, maker: ALICE }, { hash: shared, block: BASE + 500, index: 1 }),
  raw("Deposited", { tokenId: 8n, borrower: BOB }, { hash: shared, block: BASE + 500, index: 2 }),
  raw("Borrowed", { tokenId: 8n, borrower: BOB }, { hash: shared, block: BASE + 500, index: 3 }),
  raw("UnitsClaimed", { account: ALICE }),
  raw("Listed", { listingId: 1n, seller: ALICE }),
  raw("Listed", { listingId: 2n, seller: BOB }),
  raw("Bought", { listingId: 2n, buyer: ALICE }),
  raw("Bought", { listingId: 1n, buyer: CAROL }),
  raw("Redeemed", { account: ALICE }),
  raw("Purchased", { tokenId: 8n, buyer: ALICE, borrower: BOB }),
  raw("Voted", { voter: BOB, pool: POOL, tokenId: 8n }),
];

section("C69: one EXP function, ranks by EXP alone");
{
  const alice = progressOf(world);
  check(alice.exp === 2_500 && alice.rank.id === "sobashi" && alice.next === null, `every log-proved quest gives 2,500 and the top rank (got ${alice.exp}, ${alice.rank.id})`);
  check(!earned(alice, "bug") && alice.quests.length === QUESTS.length, "the bug quest needs a bonus entry, and every row is reported");
  const edges = RANKS.flatMap((rank) => [rank.exp, Math.max(rank.exp - 1, 0)]);
  const rankRight = edges.every((exp) => {
    const reached = RANKS.filter((rank) => rank.exp <= exp).at(-1);
    return rankOf(exp).id === reached?.id && nextRank(exp)?.exp === RANKS.find((rank) => rank.exp > exp)?.exp;
  });
  check(rankRight, "each rank starts exactly at its threshold");
  const withBonus = progressOf([], BOB, [{ address: BOB, exp: 300, reason: "found a bug", link: "https://example.com/1" }]);
  check(withBonus.exp === 300 && earned(withBonus, "bug") && withBonus.rank.id === "tedai" && withBonus.reachedBlock === null, "a bonus entry alone earns its EXP, the bug quest and the rank");

  for (const [contract, abi] of [["loanManager", loanManagerAbi], ["creditMarkets", creditMarketsAbi], ["payDown", payDownAbi], ["unitMarket", unitMarketAbi]] as const) {
    const built = new Set((abi as Abi).filter((item): item is AbiEvent => item.type === "event").map((item) => toEventSelector(item)));
    const rows = QUEST_EVENTS.filter((event) => event.contract === contract);
    check(rows.length > 0 && rows.every((event) => built.has(event.topic0)), `${rows.length} table events match the ${contract} ABI`);
  }

  stand({ logs: world });
  const server = await readAllProgress();
  const wallets = await Promise.all([ALICE, BOB, CAROL].map((wallet) => readWalletProgress(wallet)));
  const sameEverywhere = wallets.every((browser) => {
    const twin = server.wallets.find((wallet) => wallet.address === browser.address);
    return JSON.stringify(browser) === JSON.stringify(twin);
  });
  check(server.complete && wallets.every((wallet) => wallet.complete), "both paths read the fixture to the end");
  check(sameEverywhere, `the same logs through the browser and server paths give the same progress (${wallets.map((wallet) => wallet.exp).join(", ")})`);
  check(wallets[0]?.exp === 2_500, "the browser path finds every quest, including those reached by id and by receipt");

  stand({ logs: world, latest: BASE + 50_000 });
  const pastTheWindow = await readWalletProgress(ALICE);
  check(pastTheWindow.exp === 2_500 && pastTheWindow.complete, "the explorer alone is enough when the logs are older than the node window");

  const traffic = stand({ logs: world, indexedUpTo: BASE });
  const unindexed = await readWalletProgress(ALICE);
  const borrow = unindexed.quests.find((quest) => quest.id === "borrow");
  check(unindexed.exp === 2_500 && unindexed.complete, "the node window finds logs the explorer has not indexed (C70)");
  check(borrow?.at !== undefined && borrow.at > blockTimeOf(BASE), "a log from the node shows its block's real time, not the node's 0x0");
  check(traffic.peak <= 4, `at most 4 reads ran at once (peak ${traffic.peak})`);
  const allServer = await readAllProgress();
  check(allServer.wallets.find((wallet) => wallet.address === ALICE)?.exp === 2_500 && allServer.complete, "the server path takes the same unindexed logs");
}

section("C70: an incomplete read is never a final number");
{
  const pagesOf = (page: number) => [fullPage(BASE), fullPage(BASE + 999), raw("Borrowed", { borrower: ALICE }, { block: BASE + 2_000 })][page];
  let served = 0;
  const pager = (failThird: boolean) => (url: URL) => {
    if (!explorerOnly(url) || url.searchParams.get("topic2") === null) return "continue" as const;
    served += 1;
    if (failThird && served === 3) return new Response("bad gateway", { status: 502 });
    const rows = pagesOf(served - 1);
    return Response.json({ message: "OK", result: Array.isArray(rows) ? rows : [rows] });
  };
  stand({ logs: [], override: pager(false) });
  const whole = await readExplorerLogs(borrowedQuery);
  check(whole.complete && whole.logs.length === 2_000, `control: three good pages read to the end, one log kept once (${whole.logs.length})`);

  served = 0;
  stand({ logs: [], override: pager(true) });
  const broken = await readExplorerLogs(borrowedQuery);
  check(!broken.complete && broken.logs.length > 0, "a mock explorer failing on page 3 gives complete: false");
  served = 0;
  const brokenProgress = await readWalletProgress(ALICE);
  check(!brokenProgress.complete, "the same failure carries through to the wallet's progress");
  stand({ logs: world, override: (url) => (explorerOnly(url) ? new Response("bad gateway", { status: 502 }) : "continue") });
  const failedServer = await readAllProgress();
  check(!failedServer.complete, "the server path is incomplete on the same failure");

  stand({ logs: [raw("Borrowed", { borrower: ALICE })], override: (url) => (url.host === "rpc.test.mezo.org" ? new Response("down", { status: 503 }) : "continue") });
  const nodeDown = await readWalletProgress(ALICE);
  check(nodeDown.exp === 200 && !nodeDown.complete, "the node being down marks the read incomplete, with what was read kept");

  const nullReceipts = (url: URL, init: RequestInit | undefined) =>
    url.host === "rpc.test.mezo.org" && String(init?.body).includes("eth_getTransactionReceipt")
      ? Response.json({ jsonrpc: "2.0", id: 1, result: null })
      : ("continue" as const);
  stand({ logs: world, latest: BASE + 50_000, override: nullReceipts });
  const noReceipts = await readWalletProgress(ALICE);
  check(noReceipts.complete && earned(noReceipts, "stranger"), "a node that answers null for a receipt falls back to the explorer's logs for the block");
  stand({
    logs: world,
    latest: BASE + 50_000,
    override: (url, init) => {
      if (url.searchParams.get("toBlock") !== "latest" && url.searchParams.has("toBlock")) return new Response("down", { status: 503 });
      return nullReceipts(url, init);
    },
  });
  const neither = await readWalletProgress(ALICE);
  check(!neither.complete && !earned(neither, "stranger"), "with neither source, stranger stays undecided and the read is incomplete");

  const pastBudget = stand({ logs: world });
  const outOfTime = await readAllProgress(Date.now() - 1);
  check(!outOfTime.complete && !pastBudget.hosts.has("api.explorer.test.mezo.org"), "a scan past its deadline stops asking the explorer and is incomplete");

  let page = 0;
  stand({ logs: [], override: (url) => (explorerOnly(url) ? Response.json({ message: "OK", result: fullPage(BASE + 1_000 * page++) }) : "continue") });
  const capped = await readExplorerLogs(borrowedQuery);
  check(!capped.complete && page === 20, `the 20 page cap ends the read as incomplete (${page} pages)`);

  stand({ logs: [], override: (url) => (explorerOnly(url) ? Response.json({ message: "OK", result: fullPage(BASE, () => ({ blockNumber: toHex(BASE) })) }) : "continue") });
  check(!(await readExplorerLogs(borrowedQuery)).complete, "a full page inside one block cannot be passed, so it ends incomplete");

  stand({ logs: [], override: (url) => (explorerOnly(url) ? Response.json({ message: "NOTOK", result: "Max rate limit reached" }) : "continue") });
  check(!(await readExplorerLogs(borrowedQuery)).complete, "an explorer refusal ends the read as incomplete");

  stand({ logs: [], override: (url) => (explorerOnly(url) ? new Response("slow down", { status: 429 }) : "continue") });
  check(!(await readExplorerLogs(borrowedQuery)).complete, "a 429 ends the read as incomplete");

  const selfFills = Array.from({ length: 21 }, (_, at) => {
    const hash = toHex(20_000 + at, { size: 32 });
    return [raw("Filled", { maker: ALICE }, { hash, index: 1 }), raw("Borrowed", { borrower: ALICE }, { hash, index: 2 })];
  }).flat();
  stand({ logs: selfFills });
  check(!(await readWalletProgress(ALICE)).complete, "21 fills with no stranger in the newest 20 stay undecided, so incomplete");
  const strangerHash = toHex(30_000, { size: 32 });
  stand({ logs: [...selfFills, raw("Filled", { maker: ALICE }, { hash: strangerHash, index: 1 }), raw("Borrowed", { borrower: BOB }, { hash: strangerHash, index: 2 })] });
  const decided = await readWalletProgress(ALICE);
  check(decided.complete && earned(decided, "stranger"), "a stranger inside the newest 20 decides it, so complete");
}

section("C70: the node window meets the scan and the explorer");
{
  const wait = (ms: number) => new Promise((settle) => setTimeout(settle, ms));
  const NODE_WINDOW = 9_999;
  const head = BASE + 20_000;
  const lastSeen = head - NODE_WINDOW;

  const strangers = Array.from({ length: 65 }, (_, at) => raw("Voted", { voter: BOB, pool: POOL, tokenId: 8n }, { block: BASE + at }));
  stand({ logs: strangers });
  const flooded = await readAllProgress();
  check(flooded.complete, "65 strangers' votes in the node window leave the scan complete");
  check((flooded.wallets.find((wallet) => wallet.address === BOB)?.exp ?? 0) === 0, "and the stranger earns nothing");

  const lost = raw("Borrowed", { borrower: ALICE }, { block: BASE + 10 });
  const bothReads = async () => ({ wallet: await readWalletProgress(ALICE), whole: await readAllProgress() });

  stand({ logs: [lost], latest: head, indexedUpTo: BASE });
  const stalled = await bothReads();
  check(!stalled.wallet.complete && stalled.wallet.exp === 0, "an explorer behind the node window leaves a gap, so the wallet read is incomplete");
  check(!stalled.whole.complete, "and so is the whole read");

  stand({ logs: [lost], latest: head, indexedUpTo: lastSeen - 1 });
  const oneShort = await bothReads();
  check(!oneShort.wallet.complete && !oneShort.whole.complete, "a height one block below the window's bottom is incomplete");

  stand({ logs: [lost], latest: head, indexedUpTo: lastSeen });
  const atTheEdge = await bothReads();
  check(atTheEdge.wallet.complete && atTheEdge.whole.complete && atTheEdge.wallet.exp === 200, "a height at the window's bottom is complete, and the log is found");

  stand({ logs: [raw("Borrowed", { borrower: ALICE }, { block: head - 5 })], latest: head, indexedUpTo: BASE });
  const kept = await readRecentLogs();
  check(!kept.complete && kept.logs.length === 1, "a stalled read keeps the logs it found");

  const heights: readonly [string, () => Response][] = [
    ["a 503", () => new Response("down", { status: 503 })],
    ["not JSON", () => new Response("<html>")],
    ["no items", () => Response.json({ items: [] })],
    ["text", () => Response.json({ items: [{ height: "16607995" }] })],
    ["a fraction", () => Response.json({ items: [{ height: 1.5 }] })],
    ["a negative", () => Response.json({ items: [{ height: -1 }] })],
    ["too large to be exact", () => Response.json({ items: [{ height: 2 ** 60 }] })],
  ];
  for (const [name, reply] of heights) {
    stand({ logs: world, override: (url) => (isHeightCall(url) ? reply() : "continue") });
    const reads = await bothReads();
    check(!reads.wallet.complete && !reads.whole.complete, `a height reply of ${name} is unreadable, so both reads are incomplete`);
  }

  const asked = stand({ logs: world });
  const beforeRecent = await readRecentLogs(Date.now() - 1);
  const beforeStamps = await stampLogs([normal(raw("Borrowed", { borrower: ALICE }))], Date.now() - 1);
  check(asked.calls === 0, `a passed deadline makes no upstream call (${asked.calls})`);
  check(!beforeRecent.complete && beforeRecent.logs.length === 0, "readRecentLogs past its deadline is incomplete and empty");
  check(!beforeStamps.complete && beforeStamps.logs.length === 0, "stampLogs past its deadline is incomplete and empty");

  const slowOn = (method: string) => async (_url: URL, init: RequestInit | undefined): Promise<Reply> => {
    if (String(init?.body).includes(method)) await wait(60);
    return "continue";
  };
  const midRecent = stand({ logs: world, override: slowOn("eth_blockNumber") });
  const stoppedRecent = await readRecentLogs(Date.now() + 20);
  check(!stoppedRecent.complete && midRecent.calls === 1, `a deadline that passes after the head read stops the rest (${midRecent.calls} call)`);

  const eight = Array.from({ length: 8 }, (_, at) => normal(raw("Borrowed", { borrower: ALICE }, { block: BASE + 1_000 + at })));
  const midStamps = stand({ logs: [], override: slowOn("eth_getBlockByNumber") });
  const partStamped = await stampLogs(eight, Date.now() + 20);
  check(!partStamped.complete && partStamped.logs.length === 4 && midStamps.calls === 4, `blocks not read when the deadline passes count as unread (${partStamped.logs.length} of 8 stamped, ${midStamps.calls} calls)`);
}

section("C72: outbound calls have a fixed shape");
{
  const traffic = stand({ logs: world });
  await readWalletProgress(ALICE);
  await readAllProgress();
  check([...traffic.hosts].sort().join() === "api.explorer.test.mezo.org,rpc.test.mezo.org", `only the two constant hosts were called (${[...traffic.hosts].join(", ")})`);
  check(traffic.everyCallGuarded, `all ${traffic.calls} calls refuse redirects and carry a timeout`);

  stand({ logs: [], override: (url) => { if (explorerOnly(url)) throw new TypeError("fetch failed: unexpected redirect"); return "continue"; } });
  check(!(await readExplorerLogs(borrowedQuery)).complete, "a redirect ends the read as incomplete");

  const evil = "https://evil.example/api?page=2";
  const cursorTraffic = stand({ logs: [], override: (url) => (explorerOnly(url) ? Response.json({ message: "OK", result: fullPage(BASE, (at) => (at === 999 ? { blockNumber: evil } : {})), next_page_path: evil }) : "continue") });
  const cursor = await readExplorerLogs(borrowedQuery);
  check(!cursor.complete && !cursorTraffic.hosts.has("evil.example"), "a page value that is a URL ends the read as incomplete, and it is never fetched");

  stand({ logs: [], override: (url) => (explorerOnly(url) ? new Response("x".repeat(4_100_000)) : "continue") });
  check(!(await readExplorerLogs(borrowedQuery)).complete, "a reply over the size cap ends the read as incomplete");

  stand({
    logs: [],
    override: (url, init) =>
      explorerOnly(url) ? new Promise((_, reject) => init?.signal?.addEventListener("abort", () => reject(init.signal?.reason))) : "continue",
  });
  // AbortSignal's timer does not hold the process open, so this one does until the read has given up.
  const holdOpen = setTimeout(() => undefined, 15_000);
  const started = Date.now();
  const timedOut = await readExplorerLogs(borrowedQuery);
  clearTimeout(holdOpen);
  check(!timedOut.complete && Date.now() - started < 12_000, `a reply that never comes ends the read after the timeout (${Date.now() - started} ms)`);

  const noCall = stand({ logs: [] });
  const refused = await readExplorerLogs({ event: EVENTS.Borrowed, match: { field: "borrower", wallet: "0x123" as Address } });
  check(!refused.complete && noCall.calls === 0, "a value that is not an address never builds a URL, and nothing is sent");
  globalThis.fetch = realFetch;
}

section("C74: a bad bonus file fails the build");
{
  const folder = mkdtempSync(join(tmpdir(), "doji-bonus-"));
  const file = join(folder, "bonus.json");
  const validate = (text: string) => {
    writeFileSync(file, text);
    const run = spawnSync(process.execPath, ["--import", "tsx", join(here, "validate-bonus.mjs"), file], { cwd: resolve(here, ".."), encoding: "utf8" });
    return run.status;
  };
  const entry = (fields: string) => `{"address":"${ALICE}","exp":100,"reason":"found a bug","link":"https://example.com/report",${fields}"note":1}`;
  check(validate("[]") === 0, "control: an empty list passes");
  check(validate(`[${entry("")}]`) === 0, "control: a good entry passes");
  for (const [label, text] of [
    ['exp: "100"', `[{"address":"${ALICE}","exp":"100","reason":"r","link":"https://example.com"}]`],
    ["exp: 1e309", `[{"address":"${ALICE}","exp":1e309,"reason":"r","link":"https://example.com"}]`],
    ["exp: -5", `[{"address":"${ALICE}","exp":-5,"reason":"r","link":"https://example.com"}]`],
    ["exp: 0", `[{"address":"${ALICE}","exp":0,"reason":"r","link":"https://example.com"}]`],
    ["exp: 1.5", `[{"address":"${ALICE}","exp":1.5,"reason":"r","link":"https://example.com"}]`],
    ["exp: 1001", `[{"address":"${ALICE}","exp":1001,"reason":"r","link":"https://example.com"}]`],
    ['link: "javascript:alert(1)"', `[{"address":"${ALICE}","exp":5,"reason":"r","link":"javascript:alert(1)"}]`],
    ["an http link", `[{"address":"${ALICE}","exp":5,"reason":"r","link":"http://example.com"}]`],
    ["a 200 character reason", `[{"address":"${ALICE}","exp":5,"reason":"${"r".repeat(200)}","link":"https://example.com"}]`],
    ["a bad checksum", `[{"address":"${badChecksum}","exp":5,"reason":"r","link":"https://example.com"}]`],
    [
      "a duplicate in another casing",
      `[{"address":"${ALICE}","exp":5,"reason":"r","link":"https://example.com"},{"address":"${ALICE.toLowerCase()}","exp":5,"reason":"r","link":"https://example.com"}]`,
    ],
    ["not a list", `{"address":"${ALICE}"}`],
    ["not JSON", "[{"],
  ] as const) {
    check(validate(text) === 1, `${label} fails validation`);
  }
  rmSync(folder, { recursive: true, force: true });
  check(existsSync(join(here, "../content/quests/bonus-exp.json")), "the real file exists");
}

section("C69 and C75: the board's order and Doji's wallets");
{
  const deployer = [...dojiWallets][0] as Address;
  const mixedDeployer = `0x${deployer.slice(2).toLowerCase()}` as Address;
  const everything = world.map((log) => {
    const topics = (log.topics as string[]).map((topic) => topic.replace(ALICE.slice(2).toLowerCase(), mixedDeployer.slice(2)));
    return { ...log, topics };
  });
  const read = { logs: everything.map(normal), complete: true };
  const rows = leaderboardRows(walletsIn(read).map((wallet) => computeProgress(wallet, read, [])));
  check(!isDojiWallet(BOB) && isDojiWallet(mixedDeployer) && isDojiWallet(deployer.toUpperCase().replace("0X", "0x")), "the list matches in every spelling");
  check(computeProgress(mixedDeployer, read, []).exp === 2_500 && !rows.some((row) => row.address === deployer), "a listed wallet in lowercase with the top EXP does not appear");
  check(rows[0]?.place === 1 && rows[0]?.address === BOB, "the next wallet moves up to place 1");

  const at = (wallet: Address, block: number) => progressOf([raw("Borrowed", { borrower: wallet }, { block })], wallet);
  const [late, early, sameBlockHigh, sameBlockLow] = [at(ALICE, BASE + 9), at(BOB, BASE + 8), at(CAROL, BASE + 7), at(LOOKALIKE, BASE + 7)] as [WalletProgress, WalletProgress, WalletProgress, WalletProgress];
  const order = leaderboardRows([late, early, sameBlockHigh, sameBlockLow]).map((row) => row.address);
  const sameBlock = [CAROL, LOOKALIKE].sort();
  check(order.join() === [...sameBlock, BOB, ALICE].join(), "ties go to the earliest block, then the address");
  check(compareProgress(early, late) < 0, "the same order from the one compare function");

  const crowd = Array.from({ length: 60 }, (_, offset) => {
    const wallet = getAddress(toHex(1_000_000 + offset, { size: 20 }));
    return progressOf([raw("Borrowed", { borrower: wallet }, { block: BASE + offset })], wallet);
  });
  const nobody = progressOf([raw("Deposited", { tokenId: 77n, borrower: ALICE })]);
  const top = leaderboardRows([...crowd, nobody]);
  check(top.length === 50 && top.at(-1)?.place === 50 && nobody.exp === 0 && !top.some((row) => row.address === ALICE), "50 rows at most, and no wallet with 0 EXP");
}

section("C75: the list covers every record, and the chain's roles");
{
  const records = ["31611-wave2.json", "31611-faucet.json", "31611.json"].map((name) => JSON.parse(readFileSync(resolve(here, "../../contracts/deployments", name), "utf8")) as Record<string, unknown>);
  const fromRecords = records.flatMap((record) => ["deployer", "keeper", "relayer", "owner"].map((field) => record[field]).filter((value) => value !== undefined));
  check(fromRecords.length > 0 && fromRecords.every(isDojiWallet), `all ${fromRecords.length} wallets named in the deployment records are on the list`);
  const envFile = resolve(here, "../../contracts/.env");
  if (existsSync(envFile)) {
    const named = [...readFileSync(envFile, "utf8").matchAll(/^[A-Z0-9_]+_ADDRESS=(0x[0-9a-fA-F]{40})/gm)].map((line) => line[1]);
    check(named.length > 0 && named.every(isDojiWallet), `all ${named.length} wallets named in packages/contracts/.env are on the list`);
  }
}

section("Live Mezo testnet, read-only");
{
  const proofDoc = readFileSync(resolve(here, "../../../docs/proof/wave2-live-2026-11-04.md"), "utf8");
  const proveItDoc = readFileSync(resolve(here, "../../../docs/proof/prove-it-2026-11-04.md"), "utf8");
  const whereRecorded = (hash: string | undefined) => {
    if (hash !== undefined && proofDoc.includes(hash)) return "in wave2-live-2026-11-04.md";
    return hash !== undefined && proveItDoc.includes(hash) ? "NOT in wave2-live-2026-11-04.md, it is in prove-it-2026-11-04.md" : "in no proof doc";
  };
  const whole = await readAllProgress();
  check(whole.complete, `the whole-chain read finished, ${whole.wallets.length} wallets`);

  const client = createPublicClient({ chain: mezoTestnetChain, transport: http() });
  const roles = parseAbi(["function owner() view returns (address)", "function guardian() view returns (address)", "function treasury() view returns (address)", "function relayer() view returns (address)"]);
  const asked = [
    ...[CONTRACTS.loanManager, CONTRACTS.creditMarkets, CONTRACTS.payDown, CONTRACTS.unitMarket].flatMap((address) => [
      { address, abi: roles, functionName: "owner" as const },
      { address, abi: roles, functionName: "guardian" as const },
    ]),
    { address: CONTRACTS.creditMarkets, abi: roles, functionName: "treasury" as const },
    { address: CONTRACTS.unitMarket, abi: roles, functionName: "treasury" as const },
    { address: CONTRACTS.faucet, abi: roles, functionName: "owner" as const },
    { address: CONTRACTS.faucet, abi: roles, functionName: "relayer" as const },
  ];
  const holders = await client.multicall({ allowFailure: false, contracts: asked });
  check(holders.every(isDojiWallet), `all ${holders.length} owner, guardian, treasury and relayer roles on chain are on the list`);

  // Each pair is a quest and the transaction docs/proof/wave2-live-2026-11-04.md gives for it.
  const expected: { label: string; wallet: Address; quests: Record<string, string> }[] = [
    {
      label: "BORROWER",
      wallet: "0x92DcCb70C33300848Da555eDe8597d3F7037AE2b",
      quests: { borrow: "0xbec0ffd1", vote: "0x35514ac4", paydown: "0x314b4d90", harvest: "0xd17b64b0" },
    },
    { label: "BUYER", wallet: "0x56B9c9418BaEfDEDef6da0aB2af450842b776B79", quests: { buy: "0xd6c5abb1" } },
    {
      label: "deployer",
      wallet: "0xd338Ad588D6c3aE127FD5eEC6843A468d3a7aa6e",
      quests: { parked: "0x626c46cc", stranger: "0xbec0ffd1", units: "0x34c79826", sell: "0xdd1881b9" },
    },
  ];
  for (const { label, wallet, quests } of expected) {
    const progress = await readWalletProgress(wallet);
    console.log(`\n  ${label} ${progress.address}: ${progress.exp} EXP, ${progress.rank.id} ${progress.rank.kanji}, next ${progress.next?.id ?? "none"}, complete ${progress.complete}`);
    for (const quest of progress.quests.filter((state) => state.done)) {
      const row = QUESTS.find((entry) => entry.id === quest.id);
      const when = quest.at === undefined ? "no date" : new Date(quest.at * 1000).toISOString();
      console.log(`    ${row?.kanji} ${quest.id} +${row?.exp} ${when} ${quest.hash} (${whereRecorded(quest.hash)})`);
    }
    check(progress.complete, `${label}: the read finished`);
    for (const [id, prefix] of Object.entries(quests)) {
      const quest = progress.quests.find((state) => state.id === id);
      check(quest?.done === true && quest.hash?.startsWith(prefix) === true, `${label}: ${id} is done, by ${prefix}`);
    }
    check(progress.quests.every((quest) => !quest.done || (quest.hash !== undefined && (proofDoc.includes(quest.hash) || proveItDoc.includes(quest.hash)))), `${label}: every finished quest's transaction is in a proof page`);
    const twin = whole.wallets.find((entry) => entry.address === progress.address);
    check(JSON.stringify(twin) === JSON.stringify(progress), `${label}: the browser and server paths agree on live data`);
  }
}

console.log(failures === 0 ? "\nall quest checks passed" : `\n${failures} quest check(s) FAILED`);
process.exit(failures === 0 ? 0 : 1);

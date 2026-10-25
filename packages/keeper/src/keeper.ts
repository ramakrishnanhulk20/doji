import { formatEther, getAddress, isAddressEqual, type Address, type Hash } from "viem";
import { loadDeployment, MEZO_TESTNET_CHAIN_ID, type Config, type DeploymentRecord } from "./config.js";
import {
  creditMarketsAbi,
  describeError,
  fetchExplorerHeight,
  fetchLoanEventsFromExplorer,
  fetchLoanLogs,
  loanManagerAbi,
  LOG_PAGE_BLOCKS,
  makeClients,
  MAX_MATURITIES_PER_RUN,
  MAX_POSITIONS_PER_RUN,
  MAX_RPC_FALLBACK_PAGES,
  plainText,
  veBtcAbi,
  type Clients,
  type LoanLog,
  type Reader,
} from "./chain.js";

const WEEK = 604_800n;
// PoolsVoter refuses a reset in the first hour of every epoch, so prepareSettle waits it out.
const EPOCH_LOCKOUT = 3_600n;
const RECEIPT_TIMEOUT_MS = 180_000;
// A node that has not caught up can estimate a call as if no code ran (21,204 gas for settle(387) on 2026-10-25), and
// the network then refuses the transaction. Every keeper call costs over 70,000, so a lower estimate is asked again.
const MIN_PLAUSIBLE_GAS = 30_000n;
const ESTIMATE_TRIES = 5;

async function plausibleGas(estimate: () => Promise<bigint>): Promise<bigint> {
  for (let tries = 0; tries < ESTIMATE_TRIES; tries++) {
    const gas = await estimate();
    if (gas >= MIN_PLAUSIBLE_GAS) return (gas * 125n) / 100n;
    await new Promise((resolve) => setTimeout(resolve, 3_000));
  }
  throw new Error(`gas estimates stayed below ${MIN_PLAUSIBLE_GAS}, so nothing was sent; the next pass tries again`);
}

// ILoanManager.LoanState. Closed is never stored: a closed loan is deleted and reads back as None.
const STATE_NONE = 0;
const STATE_ACTIVE = 1;
const STATE_AUCTION = 2;

type LoanAction = "startAuction" | "cancelAuction" | "prepareSettle" | "settle";

interface Decision<A extends string> {
  action: A | "none";
  reason: string;
}

export interface PassSummary {
  tokenIds: number;
  openLoans: number;
  maturities: number;
  actions: number;
  failedSimulations: number;
  failedSends: number;
}

interface Pass {
  config: Config;
  clients: Clients;
  record: DeploymentRecord;
  now: bigint;
  summary: PassSummary;
}

function utc(seconds: bigint): string {
  const ms = Number(seconds) * 1000;
  if (!Number.isSafeInteger(ms) || ms > 8.64e15) return `t=${seconds}`;
  return `${new Date(ms).toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

function line(subject: string, action: string, reason: string, outcome: string): void {
  console.log(`${subject.padEnd(22)} ${action.padEnd(14)} ${reason} | ${outcome}`);
}

// The pure decision for one open loan, in the order the work is allowed to happen. At most one action.
function decideLoan(input: {
  state: number;
  maturity: bigint;
  overdue: boolean;
  unsafe: boolean;
  auctionStart: bigint;
  floorTime: bigint;
  now: bigint;
  lock?: { end: bigint; isPermanent: boolean; voted: boolean };
}): Decision<LoanAction> {
  const { state, maturity, overdue, unsafe, now } = input;
  const due = overdue || unsafe;
  const why = overdue && unsafe ? "overdue and unsafe" : overdue ? `overdue since ${utc(maturity)}` : "unsafe at the live price";
  if (state === STATE_ACTIVE) {
    if (due) return { action: "startAuction", reason: why };
    return { action: "none", reason: `active, due ${utc(maturity)}, safe at the live price` };
  }
  if (input.auctionStart <= maturity && !unsafe) {
    return { action: "cancelAuction", reason: "auction began on or before the due date and the loan is safe again" };
  }
  if (now < input.floorTime) return { action: "none", reason: `in auction, floor price from ${utc(input.floorTime)}` };
  if (!due) return { action: "none", reason: "unsold past floor time, neither overdue nor unsafe" };
  const lock = input.lock;
  if (lock === undefined) return { action: "none", reason: "lock not read" };
  if (lock.voted || lock.isPermanent) {
    const what = lock.voted ? "clears its standing vote" : "unlocks its permanent lock";
    if (now % WEEK < EPOCH_LOCKOUT) {
      return { action: "none", reason: `unsold, ${what} once this epoch's first hour has passed` };
    }
    return { action: "prepareSettle", reason: `unsold past floor time (${why}), ${what}` };
  }
  if (lock.end <= now) return { action: "settle", reason: `unsold past floor time (${why}), lock ended ${utc(lock.end)}` };
  return { action: "none", reason: `unsold, settles after the lock ends ${utc(lock.end)}` };
}

function decideMarket(m: { faceTotal: bigint; openLoans: bigint; isFinal: boolean }, maturity: bigint, now: bigint): Decision<"finalize"> {
  if (m.isFinal) return { action: "none", reason: "already final" };
  if (m.faceTotal === 0n) return { action: "none", reason: "no loans were ever opened here" };
  if (now <= maturity) return { action: "none", reason: `matures ${utc(maturity)}` };
  if (m.openLoans !== 0n) return { action: "none", reason: `${m.openLoans} loan(s) still open` };
  return { action: "finalize", reason: "matured and every loan closed" };
}

// Simulates first (C20) and sends only what the simulation accepted, then waits for the receipt.
async function execute(
  pass: Pass,
  subject: string,
  decision: Decision<string>,
  call:
    | { kind: "loan"; functionName: LoanAction; tokenId: bigint }
    | { kind: "market"; maturity: bigint },
): Promise<void> {
  const { reader, writer, account } = pass.clients;
  let send: () => Promise<Hash>;
  try {
    if (call.kind === "loan") {
      const { request } = await reader.simulateContract({
        address: pass.record.loanManager,
        abi: loanManagerAbi,
        functionName: call.functionName,
        args: [call.tokenId],
        account,
      });
      const estimate = () =>
        reader.estimateContractGas({
          address: pass.record.loanManager,
          abi: loanManagerAbi,
          functionName: call.functionName,
          args: [call.tokenId],
          account: account!,
        });
      send = async () => writer!.writeContract({ ...request, gas: await plausibleGas(estimate) });
    } else {
      const { request } = await reader.simulateContract({
        address: pass.record.creditMarkets,
        abi: creditMarketsAbi,
        functionName: "finalize",
        args: [call.maturity],
        account,
      });
      const estimate = () =>
        reader.estimateContractGas({
          address: pass.record.creditMarkets,
          abi: creditMarketsAbi,
          functionName: "finalize",
          args: [call.maturity],
          account: account!,
        });
      send = async () => writer!.writeContract({ ...request, gas: await plausibleGas(estimate) });
    }
  } catch (err) {
    pass.summary.failedSimulations += 1;
    line(subject, decision.action, decision.reason, `simulation failed, skipped: ${describeError(err)}`);
    return;
  }

  pass.summary.actions += 1;
  if (pass.config.dry || writer === undefined) {
    line(subject, decision.action, decision.reason, "simulated");
    return;
  }
  let hash: Hash;
  try {
    hash = await send();
  } catch (err) {
    pass.summary.failedSends += 1;
    line(subject, decision.action, decision.reason, `send failed: ${describeError(err)}`);
    return;
  }
  try {
    const receipt = await reader.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
    if (receipt.status !== "success") pass.summary.failedSends += 1;
    const status = receipt.status === "success" ? "" : " REVERTED";
    line(subject, decision.action, decision.reason, `${hash}${status} https://explorer.test.mezo.org/tx/${hash}`);
  } catch {
    // Nodes behind rpc.test.mezo.org trailed by up to 494 s on 2026-10-20, so a missing receipt is not a failure: the
    // next pass reads the chain again and acts only if the call is still due.
    line(subject, decision.action, decision.reason, `${hash} sent, no receipt within ${RECEIPT_TIMEOUT_MS / 1000} s yet https://explorer.test.mezo.org/tx/${hash}`);
  }
}

function limitReached(pass: Pass): boolean {
  if (pass.summary.actions < pass.config.maxActions) return false;
  console.log(`stopped after MAX_ACTIONS=${pass.config.maxActions} writes; the next run carries on`);
  return true;
}

async function handleLoan(pass: Pass, tokenId: bigint): Promise<void> {
  const { reader } = pass.clients;
  const lm = pass.record.loanManager;
  const subject = `loan ${tokenId}`;
  const loan = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "loanOf", args: [tokenId] });
  if (loan.state === STATE_NONE) return;
  pass.summary.openLoans += 1;
  if (loan.state !== STATE_ACTIVE && loan.state !== STATE_AUCTION) {
    line(subject, "none", `unknown loan state ${loan.state}`, "skipped");
    return;
  }

  const overdue = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "isOverdue", args: [tokenId] });
  let unsafe: boolean;
  try {
    unsafe = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "isUnsafe", args: [tokenId] });
  } catch (err) {
    line(subject, "none", `price unavailable (isUnsafe: ${describeError(err)})`, "skipped");
    return;
  }

  let auctionStart = 0n;
  let floorTime = 0n;
  let lock: { end: bigint; isPermanent: boolean; voted: boolean } | undefined;
  if (loan.state === STATE_AUCTION) {
    const auction = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "auctionOf", args: [tokenId] });
    auctionStart = auction.startTime;
    floorTime = auction.startTime + BigInt(auction.duration);
    if (pass.now >= floorTime && (overdue || unsafe)) {
      const [, end, isPermanent] = await reader.readContract({
        address: lm,
        abi: loanManagerAbi,
        functionName: "lockOf",
        args: [tokenId],
      });
      const voted = await reader.readContract({
        address: pass.record.veBTC,
        abi: veBtcAbi,
        functionName: "voted",
        args: [tokenId],
      });
      lock = { end, isPermanent, voted };
    }
  }

  const decision = decideLoan({
    state: loan.state,
    maturity: loan.maturity,
    overdue,
    unsafe,
    auctionStart,
    floorTime,
    now: pass.now,
    ...(lock === undefined ? {} : { lock }),
  });
  if (decision.action === "none") {
    line(subject, "none", decision.reason, "-");
    return;
  }
  await execute(pass, subject, decision, { kind: "loan", functionName: decision.action, tokenId });
}

async function handleMarket(pass: Pass, maturity: bigint): Promise<void> {
  const subject = `market ${utc(maturity).slice(0, 10)}`;
  const market = await pass.clients.reader.readContract({
    address: pass.record.creditMarkets,
    abi: creditMarketsAbi,
    functionName: "marketOf",
    args: [maturity],
  });
  const decision = decideMarket(market, maturity, pass.now);
  if (decision.action === "none") {
    line(subject, "none", decision.reason, "-");
    return;
  }
  await execute(pass, subject, decision, { kind: "market", maturity });
}

// The deployment record is a hint like any other input: the pass refuses to run unless the chain and the two
// contracts agree with it and with each other.
async function checkDeployment(clients: Clients, record: DeploymentRecord): Promise<void> {
  const { reader } = clients;
  const chainId = await reader.getChainId();
  if (chainId !== MEZO_TESTNET_CHAIN_ID) throw new Error(`RPC is on chain ${chainId}, expected ${MEZO_TESTNET_CHAIN_ID}`);
  for (const [name, address] of [
    ["LoanManager", record.loanManager],
    ["CreditMarkets", record.creditMarkets],
  ] as const) {
    const code = await reader.getCode({ address });
    if (code === undefined || code === "0x") throw new Error(`${name} ${address} has no code on this chain`);
  }
  const [cm, ve, lm] = await Promise.all([
    reader.readContract({ address: record.loanManager, abi: loanManagerAbi, functionName: "creditMarkets" }),
    reader.readContract({ address: record.loanManager, abi: loanManagerAbi, functionName: "veBTC" }),
    reader.readContract({ address: record.creditMarkets, abi: creditMarketsAbi, functionName: "loanManager" }),
  ]);
  const same = (a: Address, b: Address) => isAddressEqual(getAddress(a), getAddress(b));
  if (!same(cm, record.creditMarkets) || !same(lm, record.loanManager) || !same(ve, record.veBTC)) {
    throw new Error("LoanManager, CreditMarkets and veBTC on chain do not match the deployment record");
  }
}

// C20 says the keeper key holds no role, and the deployer's key sits in the same .env, so this is checked on
// chain rather than trusted. A live pass refuses to start; a dry run sends nothing, so it only warns.
async function checkKeeperHasNoRole(reader: Reader, record: DeploymentRecord, keeper: Address, dry: boolean): Promise<void> {
  const lm = record.loanManager;
  const cm = record.creditMarkets;
  const [lmOwner, lmPendingOwner, lmGuardian, cmOwner, cmPendingOwner, cmGuardian, cmTreasury] = await Promise.all([
    reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "owner" }),
    reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "pendingOwner" }),
    reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "guardian" }),
    reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "owner" }),
    reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "pendingOwner" }),
    reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "guardian" }),
    reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "treasury" }),
  ]);
  const roles: [role: string, contract: string, holder: Address][] = [
    ["owner", "LoanManager", lmOwner],
    ["pending owner", "LoanManager", lmPendingOwner],
    ["guardian", "LoanManager", lmGuardian],
    ["owner", "CreditMarkets", cmOwner],
    ["pending owner", "CreditMarkets", cmPendingOwner],
    ["guardian", "CreditMarkets", cmGuardian],
    ["treasury", "CreditMarkets", cmTreasury],
  ];
  const held = roles.find(([, , holder]) => isAddressEqual(holder, keeper));
  if (held === undefined) return;
  const message = `the keeper key is the ${held[0]} of ${held[1]}; use a key with no role (threat model C20)`;
  if (!dry) throw new Error(message);
  console.log(`warning: ${message}`);
}

const byValue = (a: bigint, b: bigint): number => (a < b ? -1 : a > b ? 1 : 0);
const later = (a: LoanLog, b: LoanLog): boolean =>
  a.blockNumber > b.blockNumber || (a.blockNumber === b.blockNumber && a.logIndex > b.logIndex);
const pagesFor = (from: bigint, to: bigint): bigint => (to >= from ? (to - from + LOG_PAGE_BLOCKS) / LOG_PAGE_BLOCKS : 0n);

// The loans open now, from the Borrowed and LoanClosed events seen: a position is open when its latest Borrowed
// comes after its latest LoanClosed, and that Borrowed carries its due date. Of those, the MAX_POSITIONS_PER_RUN
// due first are read this pass.
export function selectOpenLoans(logs: LoanLog[]): {
  open: LoanLog[];
  tokenIds: bigint[];
  skipped: number;
  positions: number;
} {
  const lastBorrowed = new Map<bigint, LoanLog>();
  const lastClosed = new Map<bigint, LoanLog>();
  for (const log of logs) {
    const latest = log.event === "Borrowed" ? lastBorrowed : lastClosed;
    const seen = latest.get(log.tokenId);
    if (seen === undefined || later(log, seen)) latest.set(log.tokenId, log);
  }
  const open = [...lastBorrowed.values()].filter((borrowed) => {
    const closed = lastClosed.get(borrowed.tokenId);
    return closed === undefined || later(borrowed, closed);
  });
  const read = [...open]
    .sort((a, b) => byValue(a.maturity, b.maturity) || byValue(a.tokenId, b.tokenId))
    .slice(0, MAX_POSITIONS_PER_RUN);
  return {
    open,
    tokenIds: read.map((l) => l.tokenId).sort(byValue),
    skipped: open.length - read.length,
    positions: lastBorrowed.size,
  };
}

// Every loan event from deployment to head. The explorer's indexed height is read before its listings, so every
// event at or below it is in them, and the RPC reads from the block after it (at least the newest page) to head.
// If the explorer fails, or the RPC would need more than MAX_RPC_FALLBACK_PAGES pages to catch it up, the RPC
// alone reads that many pages back from head.
async function collectLoanLogs(pass: Pass, head: bigint): Promise<{ logs: LoanLog[]; text: string }> {
  const { config, clients, record } = pass;
  const lm = record.loanManager;
  const newestPage = head >= LOG_PAGE_BLOCKS - 1n ? head - (LOG_PAGE_BLOCKS - 1n) : 0n;
  const rpcFromAfter = (coveredTo: bigint): bigint => {
    const from = coveredTo + 1n < newestPage ? coveredTo + 1n : newestPage;
    return from > record.block ? from : record.block;
  };
  const fits = (from: bigint): boolean => pagesFor(from, head) <= MAX_RPC_FALLBACK_PAGES;

  let explorer: { borrowed: LoanLog[]; closed: LoanLog[]; height: bigint; rpcFrom: bigint } | undefined;
  const height = await fetchExplorerHeight(config.explorerApi);
  if (height !== null && !fits(rpcFromAfter(height))) {
    console.log(`explorer is indexed only to block ${height}, ${head - height} blocks behind head`);
  } else if (height !== null) {
    const borrowed = await fetchLoanEventsFromExplorer(config.explorerApi, lm, "Borrowed", record.block);
    const closed = borrowed === null ? null : await fetchLoanEventsFromExplorer(config.explorerApi, lm, "LoanClosed", record.block);
    if (borrowed !== null && closed !== null) {
      let coveredTo = height;
      for (const { cappedAt } of [borrowed, closed]) {
        if (cappedAt !== undefined && cappedAt - 1n < coveredTo) coveredTo = cappedAt - 1n;
      }
      const rpcFrom = rpcFromAfter(coveredTo);
      // Events past the scanned head are left out so the counts below compare like with like.
      const upToHead = (l: LoanLog) => l.blockNumber <= head;
      if (fits(rpcFrom)) {
        explorer = { borrowed: borrowed.logs.filter(upToHead), closed: closed.logs.filter(upToHead), height, rpcFrom };
      } else {
        console.log(`explorer listings are complete only to block ${coveredTo}, too far behind head for the RPC`);
      }
    }
  }

  const span = MAX_RPC_FALLBACK_PAGES * LOG_PAGE_BLOCKS;
  const fallbackFrom = head >= span - 1n ? head - (span - 1n) : 0n;
  const rpcFrom = explorer?.rpcFrom ?? (fallbackFrom > record.block ? fallbackFrom : record.block);
  const rpc = await fetchLoanLogs(clients.reader, lm, rpcFrom, head);
  if (explorer === undefined) {
    console.log(
      `warning: explorer unavailable; scanned the last ${pagesFor(rpcFrom, head)} pages by RPC, ` +
        "loans whose latest Borrowed event is older than that are not seen this run",
    );
  }
  const source =
    explorer === undefined
      ? "unavailable"
      : `${explorer.borrowed.length} Borrowed, ${explorer.closed.length} LoanClosed (indexed to block ${explorer.height})`;
  return {
    logs: [...(explorer?.borrowed ?? []), ...(explorer?.closed ?? []), ...rpc],
    text: `explorer ${source}; rpc ${rpc.length} logs from block ${rpcFrom}`,
  };
}

// Every weekly loan date a loan can be open at: week multiples (Thursdays 00:00 UTC, as 1970-01-01 was a Thursday)
// from the first at or after deployment up to the furthest date a new loan can pick now, the most recent
// MAX_MATURITIES_PER_RUN of them.
async function loanDates(pass: Pass): Promise<bigint[]> {
  const { reader } = pass.clients;
  const deployed = await reader.getBlock({ blockNumber: pass.record.block });
  const maxTerm = await reader.readContract({
    address: pass.record.creditMarkets,
    abi: creditMarketsAbi,
    functionName: "maxTermSeconds",
  });
  const first = ((deployed.timestamp + WEEK - 1n) / WEEK) * WEEK;
  const dates: bigint[] = [];
  for (let m = ((pass.now + BigInt(maxTerm)) / WEEK) * WEEK; m >= first && dates.length < MAX_MATURITIES_PER_RUN; m -= WEEK) {
    dates.push(m);
  }
  return dates.reverse();
}

// The chain's own count of open loans at each date is the check on the scan. Counts are read at the scanned head
// block, so loans opened or closed while the pass runs, by this pass or anyone else, cannot hide a missed one. A
// date with more open loans on chain than the scan found, or one that cannot be read, sets exit code 2; the pass
// still acts on what it found.
export async function checkCompleteness(
  reader: Reader,
  creditMarkets: Address,
  open: LoanLog[],
  dates: bigint[],
  atBlock: bigint,
): Promise<number> {
  const found = new Map<bigint, number>();
  for (const loan of open) found.set(loan.maturity, (found.get(loan.maturity) ?? 0) + 1);
  let short = 0;
  for (const m of dates) {
    const date = utc(m).slice(0, 10);
    const k = found.get(m) ?? 0;
    try {
      const market = await reader.readContract({
        address: creditMarkets,
        abi: creditMarketsAbi,
        functionName: "marketOf",
        args: [m],
        blockNumber: atBlock,
      });
      if (market.openLoans <= BigInt(k)) continue;
      console.log(`warning: ${date} has ${market.openLoans} open loans on chain but the scan found ${k}; loans are being missed`);
    } catch (err) {
      console.log(`warning: ${date} could not be checked: ${describeError(err)}`);
    }
    short += 1;
  }
  if (short === 0) console.log("completeness: no checked date has more open loans on chain than the scan found");
  else process.exitCode = 2;
  return short;
}

export async function runPass(config: Config): Promise<PassSummary> {
  const record = loadDeployment(config.deploymentFile);
  const clients = makeClients(config);
  await checkDeployment(clients, record);
  if (clients.account === undefined) console.log("role check skipped: no keeper key loaded");
  else await checkKeeperHasNoRole(clients.reader, record, clients.account.address, config.dry);

  const head = await clients.reader.getBlock({ blockTag: "latest" });
  const pass: Pass = {
    config,
    clients,
    record,
    now: head.timestamp,
    summary: { tokenIds: 0, openLoans: 0, maturities: 0, actions: 0, failedSimulations: 0, failedSends: 0 },
  };

  console.log(`Doji keeper, ${config.dry ? "dry run: simulates only, sends nothing" : "live run"}`);
  console.log(`rpc ${new URL(config.rpcUrl).host}, chain ${MEZO_TESTNET_CHAIN_ID}, block ${head.number}, ${utc(head.timestamp)}`);
  console.log(`LoanManager ${record.loanManager}, CreditMarkets ${record.creditMarkets}, max ${config.maxActions} writes`);
  if (clients.account !== undefined) {
    const gas = await clients.reader.getBalance({ address: clients.account.address });
    console.log(`keeper wallet ${clients.account.address} holds ${formatEther(gas)} BTC for gas`);
  }

  const scan = await collectLoanLogs(pass, head.number);
  const { open, tokenIds, skipped, positions } = selectOpenLoans(scan.logs);
  const maturities = await loanDates(pass);
  pass.summary.tokenIds = tokenIds.length;
  pass.summary.maturities = maturities.length;
  console.log(`scan: ${scan.text}; ${open.length} open loans of ${positions} positions; ${maturities.length} dates checked`);
  if (skipped > 0) {
    console.log(`warning: ${skipped} open loans wait for a later pass; this pass reads the ${MAX_POSITIONS_PER_RUN} due first`);
  }
  await checkCompleteness(clients.reader, record.creditMarkets, open, maturities, head.number);

  for (const tokenId of tokenIds) {
    if (limitReached(pass)) return pass.summary;
    try {
      await handleLoan(pass, tokenId);
    } catch (err) {
      line(`loan ${tokenId}`, "none", `read failed: ${describeError(err)}`, "skipped");
    }
  }
  for (const maturity of maturities) {
    if (limitReached(pass)) return pass.summary;
    try {
      await handleMarket(pass, maturity);
    } catch (err) {
      line(`market ${maturity}`, "none", `read failed: ${describeError(err)}`, "skipped");
    }
  }

  const s = pass.summary;
  console.log(
    plainText(
      `done: ${s.openLoans} open of ${s.tokenIds} positions, ${s.maturities} maturities, ` +
        `${s.actions} ${config.dry ? "simulated" : "sent"}, ${s.failedSimulations} refused in simulation, ${s.failedSends} failed sends`,
    ),
  );
  return s;
}

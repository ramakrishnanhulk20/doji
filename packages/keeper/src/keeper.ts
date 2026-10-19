import { formatEther, getAddress, isAddressEqual, type Address, type Hash } from "viem";
import { loadDeployment, MEZO_TESTNET_CHAIN_ID, type Config, type DeploymentRecord } from "./config.js";
import {
  creditMarketsAbi,
  describeError,
  fetchBorrowedLogs,
  loanManagerAbi,
  makeClients,
  plainText,
  veBtcAbi,
  type Clients,
} from "./chain.js";

const WEEK = 604_800n;
// PoolsVoter refuses a reset in the first hour of every epoch, so prepareSettle waits it out.
const EPOCH_LOCKOUT = 3_600n;
const RECEIPT_TIMEOUT_MS = 180_000;

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
      send = () => writer!.writeContract(request);
    } else {
      const { request } = await reader.simulateContract({
        address: pass.record.creditMarkets,
        abi: creditMarketsAbi,
        functionName: "finalize",
        args: [call.maturity],
        account,
      });
      send = () => writer!.writeContract(request);
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
  try {
    const hash = await send();
    const receipt = await reader.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
    if (receipt.status !== "success") pass.summary.failedSends += 1;
    const status = receipt.status === "success" ? "" : " REVERTED";
    line(subject, decision.action, decision.reason, `${hash}${status} https://explorer.test.mezo.org/tx/${hash}`);
  } catch (err) {
    pass.summary.failedSends += 1;
    line(subject, decision.action, decision.reason, `send failed: ${describeError(err)}`);
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

export async function runPass(config: Config): Promise<PassSummary> {
  const record = loadDeployment(config.deploymentFile);
  const clients = makeClients(config);
  await checkDeployment(clients, record);

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

  const logs = await fetchBorrowedLogs(clients.reader, record.loanManager, record.block, head.number);
  const tokenIds = [...new Set(logs.map((l) => l.tokenId))].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  const maturities = [...new Set(logs.map((l) => l.maturity))].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  pass.summary.tokenIds = tokenIds.length;
  pass.summary.maturities = maturities.length;
  console.log(`${logs.length} Borrowed events since block ${record.block}: ${tokenIds.length} positions, ${maturities.length} maturities`);

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

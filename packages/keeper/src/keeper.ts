import {
  BaseError,
  ContractFunctionRevertedError,
  formatEther,
  getAddress,
  isAddressEqual,
  parseAbi,
  zeroAddress,
  type Address,
  type Hash,
} from "viem";
import { loadDeployments, MEZO_TESTNET_CHAIN_ID, type Config, type DeploymentRecord } from "./config.js";
import {
  creditMarketsAbi,
  describeError,
  fetchExplorerHeight,
  fetchLoanEventsFromExplorer,
  fetchLoanLogs,
  fetchOperatorEventsFromExplorer,
  fetchOperatorLogs,
  isRevert,
  loanManagerAbi,
  LOG_PAGE_BLOCKS,
  makeClients,
  MAX_MATURITIES_PER_RUN,
  MAX_POSITIONS_PER_RUN,
  MAX_RPC_FALLBACK_PAGES,
  payDownAbi,
  plainText,
  poolsVoterAbi,
  priceFeedAbi,
  savingsVaultAbi,
  unitMarketAbi,
  veBtcAbi,
  votingRewardAbi,
  withOneRetry,
  type Clients,
  type ExplorerListing,
  type LoanLog,
  type OperatorLog,
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
// LoanManager's MAX_VOTES_CEILING: no position it holds can vote for more pools than this.
const MAX_VOTED_POOLS = 30n;
// LoanManager and PayDown both refuse a claim that lists more than 16 tokens in total (MAX_REWARD_TOKENS), counting
// a token once per gauge side it is listed on, and every listed gauge must list at least one.
const MAX_HARVEST_TOKENS = 16;
// The keeper keeps no state between runs, so the window of positions a run reads, when there are more than
// HARVEST_MAX_POSITIONS, moves with the clock: one window per 30-minute slot.
const HARVEST_ROTATION_SECONDS = 1_800n;
const PRICE_SCALE = 10n ** 18n;
// Mezo's Router refuses a sale below its minimum with its own error, before PayDown's floor check runs, and PayDown's
// ABI names neither that nor LoanManager's claim error. Both are added so a refused harvest always decodes to a name.
const harvestAbi = [
  ...payDownAbi,
  ...parseAbi(["error InsufficientOutputAmount()", "error NothingToClaim(address account)"]),
] as const;
// A harvest refused with one of these failed on its BTC sale, so the same claim without BTC can still repay (C39,
// C48). They are matched by decoded error name, because a node's message text is not something to decide on.
const BTC_REFUSALS: ReadonlyMap<string, string> = new Map([
  ["InsufficientOutputAmount", "Mezo's pool pays below the oracle floor"],
  ["BelowFloor", "Mezo's pool pays below the oracle floor"],
  ["PriceUnavailable", "Mezo's BTC price is unavailable"],
]);
// Refusals a healthy system produces. Any other revert means the keeper and the contracts disagree, so it fails the
// run. NotBorrower is the operator changing mid-run, HarvestsPaused a pause landing mid-run.
const EXPECTED_REFUSALS: ReadonlySet<string> = new Set([...BTC_REFUSALS.keys(), "NotBorrower", "HarvestsPaused", "NothingToClaim"]);

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
  harvestPositions: number;
  harvests: number;
  harvestSkips: number;
  failedSimulations: number;
  failedSends: number;
  vaultAlerts: number;
  pairFailures: number;
  unexpectedRefusals: number;
}

// What every pair in one run shares: one key, one gas wallet, one write budget.
interface Shared {
  capped: boolean;
  vaultAlerts: string[];
}

// One pair's view of the run. Every object it touches is read from and written to this record's own contracts
// (C49); the summary and the budget are the run's, shared by every pair.
interface Pass {
  config: Config;
  clients: Clients;
  record: DeploymentRecord;
  // The record's name, padded, printed at the start of every line so each loan, market and harvest reads with the
  // pair whose contracts the header lists.
  tag: string;
  // CreditMarkets' savings vault as the chain reports it; undefined for a pair that cannot park.
  vault: Address | undefined;
  now: bigint;
  summary: PassSummary;
  shared: Shared;
}

function utc(seconds: bigint): string {
  const ms = Number(seconds) * 1000;
  if (!Number.isSafeInteger(ms) || ms > 8.64e15) return `t=${seconds}`;
  return `${new Date(ms).toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

function line(pass: Pass, subject: string, action: string, reason: string, outcome: string): void {
  console.log(`${pass.tag} ${subject.padEnd(22)} ${action.padEnd(14)} ${reason} | ${outcome}`);
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

// Sends what a simulation accepted and waits for the receipt. `say` prints how it ended.
async function deliver(pass: Pass, say: (outcome: string) => void, send: () => Promise<Hash>): Promise<void> {
  const { reader, writer } = pass.clients;
  if (pass.config.dry || writer === undefined) {
    say("simulated");
    return;
  }
  let hash: Hash;
  try {
    hash = await send();
  } catch (err) {
    pass.summary.failedSends += 1;
    say(`send failed: ${describeError(err)}`);
    return;
  }
  try {
    const receipt = await reader.waitForTransactionReceipt({ hash, timeout: RECEIPT_TIMEOUT_MS });
    if (receipt.status !== "success") pass.summary.failedSends += 1;
    const status = receipt.status === "success" ? "" : " REVERTED";
    say(`${hash}${status} https://explorer.test.mezo.org/tx/${hash}`);
  } catch {
    // Nodes behind rpc.test.mezo.org trailed by up to 494 s on 2026-10-20, so a missing receipt is not a failure: the
    // next pass reads the chain again and acts only if the call is still due.
    say(`${hash} sent, no receipt within ${RECEIPT_TIMEOUT_MS / 1000} s yet https://explorer.test.mezo.org/tx/${hash}`);
  }
}

// Simulates first (C20) and sends only what the simulation accepted. Harvests go through handleHarvest instead.
async function execute(
  pass: Pass,
  subject: string,
  decision: Decision<string>,
  call: { kind: "loan"; functionName: LoanAction; tokenId: bigint } | { kind: "market"; maturity: bigint },
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
    line(pass, subject, decision.action, decision.reason, `simulation failed, skipped: ${describeError(err)}`);
    return;
  }

  pass.summary.actions += 1;
  await deliver(pass, (outcome) => line(pass, subject, decision.action, decision.reason, outcome), send);
}

// MAX_ACTIONS is the resolution budget of the whole run, shared by every pair because they share one gas wallet.
function limitReached(pass: Pass): boolean {
  if (pass.summary.actions < pass.config.maxActions) return false;
  if (!pass.shared.capped) {
    console.log(`stopped resolution after MAX_ACTIONS=${pass.config.maxActions} writes; the next run carries on`);
  }
  pass.shared.capped = true;
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
    line(pass, subject, "none", `unknown loan state ${loan.state}`, "skipped");
    return;
  }

  const overdue = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "isOverdue", args: [tokenId] });
  let unsafe: boolean;
  try {
    unsafe = await reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "isUnsafe", args: [tokenId] });
  } catch (err) {
    line(pass, subject, "none", `price unavailable (isUnsafe: ${describeError(err)})`, "skipped");
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
    line(pass, subject, "none", decision.reason, "-");
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
    line(pass, subject, "none", decision.reason, "-");
    return;
  }
  await execute(pass, subject, decision, { kind: "market", maturity });
}

const same = (a: Address, b: Address): boolean => isAddressEqual(getAddress(a), getAddress(b));

// Each deployment record is a hint like any other input: the run refuses to start unless every pair's contracts
// agree on chain with its record and with each other, so no pair can act on another pair's contracts (C49).
// Returns the savings vault CreditMarkets reports.
async function checkDeployment(clients: Clients, record: DeploymentRecord): Promise<Address | undefined> {
  const { reader } = clients;
  const contracts: [string, Address | undefined][] = [
    ["LoanManager", record.loanManager],
    ["CreditMarkets", record.creditMarkets],
    ["PayDown", record.payDown],
    ["UnitMarket", record.unitMarket],
  ];
  for (const [name, address] of contracts) {
    if (address === undefined) continue;
    const code = await reader.getCode({ address });
    if (code === undefined || code === "0x") throw new Error(`${record.name}: ${name} ${address} has no code on this chain`);
  }
  const [cm, ve, lm] = await Promise.all([
    reader.readContract({ address: record.loanManager, abi: loanManagerAbi, functionName: "creditMarkets" }),
    reader.readContract({ address: record.loanManager, abi: loanManagerAbi, functionName: "veBTC" }),
    reader.readContract({ address: record.creditMarkets, abi: creditMarketsAbi, functionName: "loanManager" }),
  ]);
  if (!same(cm, record.creditMarkets) || !same(lm, record.loanManager) || !same(ve, record.veBTC)) {
    throw new Error(`${record.name}: LoanManager, CreditMarkets and veBTC on chain do not match the deployment record`);
  }
  if (record.payDown !== undefined) {
    const served = await reader.readContract({ address: record.payDown, abi: payDownAbi, functionName: "loanManager" });
    if (!same(served, record.loanManager)) {
      throw new Error(`${record.name}: PayDown ${record.payDown} serves LoanManager ${served}, not ${record.loanManager}`);
    }
  }
  if (record.unitMarket !== undefined) {
    const units = await reader.readContract({ address: record.unitMarket, abi: unitMarketAbi, functionName: "creditMarkets" });
    if (!same(units, record.creditMarkets)) {
      throw new Error(`${record.name}: UnitMarket ${record.unitMarket} lists units of ${units}, not ${record.creditMarkets}`);
    }
  }
  // The chain decides which vault is checked; a record that names a different one, or one the chain lacks, stops
  // the run, so the check can never look at a vault the money is not in.
  const vault = await readVault(reader, record.creditMarkets);
  if (record.savingsVault !== undefined && (vault === undefined || !same(vault, record.savingsVault))) {
    throw new Error(`${record.name}: CreditMarkets reports savings vault ${vault ?? "none"}, the record says ${record.savingsVault}`);
  }
  return vault;
}

async function readVault(reader: Reader, creditMarkets: Address): Promise<Address | undefined> {
  try {
    const vault = await reader.readContract({ address: creditMarkets, abi: creditMarketsAbi, functionName: "savingsVault" });
    return isAddressEqual(vault, zeroAddress) ? undefined : getAddress(vault);
  } catch (err) {
    // The 20 October CreditMarkets has no savingsVault function, so the call reverts: that pair never parks. A
    // request that failed for any other reason stops the run instead of skipping the check.
    if (isRevert(err)) return undefined;
    throw err;
  }
}

function vaultAlert(pass: Pass, message: string): void {
  const alert = plainText(`VAULT ALERT: ${pass.record.name} ${message}`);
  pass.summary.vaultAlerts += 1;
  pass.shared.vaultAlerts.push(alert);
  console.log(alert);
}

// C35: the parked principal is the one thing a vault fault can trap, so every run asks the vault, as CreditMarkets
// itself, to give all of it back, and changes nothing. A refusal, or a check that cannot be made, is an alert; the
// run finishes its other jobs and then exits 3 so the workflow run fails and GitHub emails the repository owner.
// VAULT_CHECK_OVERRIDE swaps in another contract to prove the alert fires; it changes nothing else.
async function checkVault(pass: Pass): Promise<void> {
  const { reader } = pass.clients;
  const cm = pass.record.creditMarkets;
  if (pass.vault === undefined) {
    line(pass, "vault check", "none", `CreditMarkets ${cm} has no savings vault, so nothing is parked`, "-");
    return;
  }
  const vault = pass.vault;
  let parked: bigint;
  try {
    parked = await withOneRetry("parked principal", () =>
      reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "parkedPrincipal" }),
    );
  } catch (err) {
    vaultAlert(pass, `parked principal of CreditMarkets ${cm} could not be read, so vault ${vault} was not checked: ${describeError(err)}`);
    return;
  }
  if (parked === 0n) {
    line(pass, "vault check", "none", `CreditMarkets ${cm} has nothing parked in vault ${vault}`, "-");
    return;
  }
  const target = pass.config.vaultCheckOverride ?? vault;
  const what = `withdraw of ${formatEther(parked)} MUSD parked principal by CreditMarkets ${cm} from vault ${target}`;
  try {
    await withOneRetry("vault check", () =>
      reader.simulateContract({ address: target, abi: savingsVaultAbi, functionName: "withdraw", args: [parked], account: cm }),
    );
  } catch (err) {
    const outcome = isRevert(err) ? `simulated ${what} would fail` : `${what} could not be simulated`;
    vaultAlert(pass, `${outcome}: ${describeError(err)}`);
    return;
  }
  line(pass, "vault check", "simulate", `simulated ${what}`, "succeeds");
}

// C20 says the keeper key holds no role, and the deployer's key sits in the same .env, so this is checked on
// chain rather than trusted, for every Doji contract of every pair: LoanManager, CreditMarkets, and where the
// record has them PayDown and UnitMarket. Mezo's own contracts in a record (veBTC, PoolsVoter, the vault, the
// Router) give the keeper nothing, so they are not read. A live pass refuses to start; a dry run sends nothing,
// so it only warns.
async function checkKeeperHasNoRole(reader: Reader, passes: Pass[], keeper: Address, dry: boolean): Promise<void> {
  const jobs: Promise<{ role: string; contract: string; holder: Address }>[] = [];
  const role = (name: string, contract: string, read: () => Promise<Address>) =>
    jobs.push(read().then((holder) => ({ role: name, contract, holder })));
  let contracts = 0;
  for (const { record } of passes) {
    const at = (name: string, address: Address) => `${name} ${address} (${record.name})`;
    const lm = record.loanManager;
    const cm = record.creditMarkets;
    contracts += 2;
    role("owner", at("LoanManager", lm), () => reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "owner" }));
    role("pending owner", at("LoanManager", lm), () => reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "pendingOwner" }));
    role("guardian", at("LoanManager", lm), () => reader.readContract({ address: lm, abi: loanManagerAbi, functionName: "guardian" }));
    role("owner", at("CreditMarkets", cm), () => reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "owner" }));
    role("pending owner", at("CreditMarkets", cm), () => reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "pendingOwner" }));
    role("guardian", at("CreditMarkets", cm), () => reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "guardian" }));
    role("treasury", at("CreditMarkets", cm), () => reader.readContract({ address: cm, abi: creditMarketsAbi, functionName: "treasury" }));
    const pd = record.payDown;
    if (pd !== undefined) {
      contracts += 1;
      role("owner", at("PayDown", pd), () => reader.readContract({ address: pd, abi: payDownAbi, functionName: "owner" }));
      role("pending owner", at("PayDown", pd), () => reader.readContract({ address: pd, abi: payDownAbi, functionName: "pendingOwner" }));
      role("guardian", at("PayDown", pd), () => reader.readContract({ address: pd, abi: payDownAbi, functionName: "guardian" }));
    }
    const um = record.unitMarket;
    if (um !== undefined) {
      contracts += 1;
      role("owner", at("UnitMarket", um), () => reader.readContract({ address: um, abi: unitMarketAbi, functionName: "owner" }));
      role("pending owner", at("UnitMarket", um), () => reader.readContract({ address: um, abi: unitMarketAbi, functionName: "pendingOwner" }));
      role("guardian", at("UnitMarket", um), () => reader.readContract({ address: um, abi: unitMarketAbi, functionName: "guardian" }));
      role("treasury", at("UnitMarket", um), () => reader.readContract({ address: um, abi: unitMarketAbi, functionName: "treasury" }));
    }
  }
  const roles = await Promise.all(jobs);
  const held = roles.filter(({ holder }) => isAddressEqual(holder, keeper));
  if (held.length === 0) {
    console.log(`role check: the keeper key holds none of ${roles.length} roles across ${contracts} contracts in ${passes.length} record(s)`);
    return;
  }
  const list = held.map(({ role: name, contract }) => `the ${name} of ${contract}`).join(", ");
  const message = `the keeper key is ${list}; use a key with no role (threat model C20)`;
  if (!dry) throw new Error(message);
  console.log(`warning: ${message}`);
}

const byValue = (a: bigint, b: bigint): number => (a < b ? -1 : a > b ? 1 : 0);
type Ordered = { blockNumber: bigint; logIndex: number };
const later = (a: Ordered, b: Ordered): boolean =>
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

interface Listing<T> {
  label: string;
  fetch: (fromBlock: bigint) => Promise<ExplorerListing<T> | null>;
}

// Every event of the listed kinds from the pair's deployment block to head. The explorer's indexed height is read
// before its listings, so every event at or below it is in them, and the RPC reads from the block after it (at
// least the newest page) to head. If the explorer fails, or the RPC would need more than MAX_RPC_FALLBACK_PAGES
// pages to catch it up, the RPC alone reads that many pages back from head and the run says what it cannot see.
async function collectEvents<T extends Ordered>(
  pass: Pass,
  head: bigint,
  listings: Listing<T>[],
  rpc: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>,
  unseen: string,
): Promise<{ logs: T[]; text: string }> {
  const { config, record } = pass;
  const newestPage = head >= LOG_PAGE_BLOCKS - 1n ? head - (LOG_PAGE_BLOCKS - 1n) : 0n;
  const rpcFromAfter = (coveredTo: bigint): bigint => {
    const from = coveredTo + 1n < newestPage ? coveredTo + 1n : newestPage;
    return from > record.block ? from : record.block;
  };
  const fits = (from: bigint): boolean => pagesFor(from, head) <= MAX_RPC_FALLBACK_PAGES;

  let explorer: { lists: { label: string; logs: T[] }[]; height: bigint; rpcFrom: bigint } | undefined;
  const height = await fetchExplorerHeight(config.explorerApi);
  if (height !== null && !fits(rpcFromAfter(height))) {
    console.log(`explorer is indexed only to block ${height}, ${head - height} blocks behind head`);
  } else if (height !== null) {
    const found: { label: string; listing: ExplorerListing<T> }[] = [];
    for (const { label, fetch } of listings) {
      const listing = await fetch(record.block);
      if (listing === null) break;
      found.push({ label, listing });
    }
    if (found.length === listings.length) {
      let coveredTo = height;
      for (const { listing } of found) {
        if (listing.cappedAt !== undefined && listing.cappedAt - 1n < coveredTo) coveredTo = listing.cappedAt - 1n;
      }
      const rpcFrom = rpcFromAfter(coveredTo);
      // Events past the scanned head are left out so the counts below compare like with like.
      const upToHead = (l: T) => l.blockNumber <= head;
      if (fits(rpcFrom)) {
        explorer = { lists: found.map(({ label, listing }) => ({ label, logs: listing.logs.filter(upToHead) })), height, rpcFrom };
      } else {
        console.log(`explorer listings are complete only to block ${coveredTo}, too far behind head for the RPC`);
      }
    }
  }

  const span = MAX_RPC_FALLBACK_PAGES * LOG_PAGE_BLOCKS;
  const fallbackFrom = head >= span - 1n ? head - (span - 1n) : 0n;
  const rpcFrom = explorer?.rpcFrom ?? (fallbackFrom > record.block ? fallbackFrom : record.block);
  const fromRpc = await rpc(rpcFrom, head);
  if (explorer === undefined) {
    console.log(
      `warning: explorer unavailable; scanned the last ${pagesFor(rpcFrom, head)} pages by RPC, ` +
        `${unseen} older than that are not seen this run`,
    );
  }
  const source =
    explorer === undefined
      ? "unavailable"
      : `${explorer.lists.map((l) => `${l.logs.length} ${l.label}`).join(", ")} (indexed to block ${explorer.height})`;
  return {
    logs: [...(explorer?.lists.flatMap((l) => l.logs) ?? []), ...fromRpc],
    text: `explorer ${source}; rpc ${fromRpc.length} logs from block ${rpcFrom}`,
  };
}

function collectLoanLogs(pass: Pass, head: bigint): Promise<{ logs: LoanLog[]; text: string }> {
  const { config, clients, record } = pass;
  const lm = record.loanManager;
  const listing = (event: LoanLog["event"]): Listing<LoanLog> => ({
    label: event,
    fetch: (from) => fetchLoanEventsFromExplorer(config.explorerApi, lm, event, from),
  });
  return collectEvents(
    pass,
    head,
    [listing("Borrowed"), listing("LoanClosed")],
    (from, to) => fetchLoanLogs(clients.reader, lm, from, to),
    "loans whose latest Borrowed event is",
  );
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
  tag: string,
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
      console.log(`${tag} warning: ${date} has ${market.openLoans} open loans on chain but the scan found ${k}; loans are being missed`);
    } catch (err) {
      console.log(`${tag} warning: ${date} could not be checked: ${describeError(err)}`);
    }
    short += 1;
  }
  if (short === 0) console.log(`${tag} completeness: no checked date has more open loans on chain than the scan found`);
  else process.exitCode = 2;
  return short;
}

// The existing loan and market jobs for one pair, against that pair's contracts only.
async function resolvePair(pass: Pass, head: bigint): Promise<void> {
  const { clients, record } = pass;
  const scan = await collectLoanLogs(pass, head);
  const { open, tokenIds, skipped, positions } = selectOpenLoans(scan.logs);
  const maturities = await loanDates(pass);
  pass.summary.tokenIds += tokenIds.length;
  pass.summary.maturities += maturities.length;
  console.log(`${pass.tag} scan: ${scan.text}; ${open.length} open loans of ${positions} positions; ${maturities.length} dates checked`);
  if (skipped > 0) {
    console.log(`${pass.tag} warning: ${skipped} open loans wait for a later pass; this pass reads the ${MAX_POSITIONS_PER_RUN} due first`);
  }
  await checkCompleteness(clients.reader, record.creditMarkets, open, maturities, head, pass.tag);

  for (const tokenId of tokenIds) {
    if (limitReached(pass)) return;
    try {
      await handleLoan(pass, tokenId);
    } catch (err) {
      line(pass, `loan ${tokenId}`, "none", `read failed: ${describeError(err)}`, "skipped");
    }
  }
  for (const maturity of maturities) {
    if (limitReached(pass)) return;
    try {
      await handleMarket(pass, maturity);
    } catch (err) {
      line(pass, `market ${maturity}`, "none", `read failed: ${describeError(err)}`, "skipped");
    }
  }
}

function collectOperatorLogs(pass: Pass, head: bigint): Promise<{ logs: OperatorLog[]; text: string }> {
  const { config, clients, record } = pass;
  const lm = record.loanManager;
  return collectEvents(
    pass,
    head,
    [{ label: "RewardOperatorSet", fetch: (from) => fetchOperatorEventsFromExplorer(config.explorerApi, lm, from) }],
    (from, to) => fetchOperatorLogs(clients.reader, lm, from, to),
    "positions whose latest RewardOperatorSet event is",
  );
}

// The positions whose latest RewardOperatorSet named this pair's PayDown, in id order. Events are hints: each one
// is read again with positionOf before anything is decided.
export function selectHarvestCandidates(logs: OperatorLog[], payDown: Address): bigint[] {
  const latest = new Map<bigint, OperatorLog>();
  for (const log of logs) {
    const seen = latest.get(log.tokenId);
    if (seen === undefined || later(log, seen)) latest.set(log.tokenId, log);
  }
  return [...latest.values()]
    .filter((log) => isAddressEqual(log.operator, payDown))
    .map((log) => log.tokenId)
    .sort(byValue);
}

// `count` ids starting at a point that moves every HARVEST_ROTATION_SECONDS, wrapping, so over successive runs
// every candidate is read even when there are more than one run's budget.
export function harvestWindow(ids: bigint[], count: number, now: bigint): bigint[] {
  if (ids.length <= count) return ids;
  const start = Number(((now / HARVEST_ROTATION_SECONDS) * BigInt(count)) % BigInt(ids.length));
  return Array.from({ length: count }, (_, i) => ids[(start + i) % ids.length]!);
}

// One side (fee or incentive) of a gauge and the tokens, of MUSD and BTC, it records as rewards. A token it does
// not record would make LoanManager revert TokenNotReward, so it is never listed.
interface RewardSide {
  reward: Address;
  tokens: Address[];
}

interface Harvester {
  pass: Pass;
  payDown: Address;
  voter: Address;
  musd: Address;
  btc: Address;
  // Undefined when the feed gave no usable price this run, and noPrice then says why.
  price: bigint | undefined;
  noPrice: string;
  gauges: Map<Address, { gauge: Address; sides: [RewardSide, RewardSide] } | null>;
}

interface HarvestPlan {
  gauges: Address[];
  feeTokens: Address[][];
  bribeTokens: Address[][];
}

// What a plan without BTC claims and leaves behind, and why BTC was left out, for its log lines.
interface BtcLeftOut {
  musd: bigint;
  btc: bigint;
  why: string;
  rest: string;
}

// The pools a position votes for, read one index at a time until PoolsVoter's array ends.
async function votedPools(h: Harvester, tokenId: bigint): Promise<Address[]> {
  const { reader } = h.pass.clients;
  const pools: Address[] = [];
  for (let i = 0n; i < MAX_VOTED_POOLS; i++) {
    try {
      pools.push(getAddress(await reader.readContract({ address: h.voter, abi: poolsVoterAbi, functionName: "poolVote", args: [tokenId, i] })));
    } catch (err) {
      if (isRevert(err)) break;
      throw err;
    }
  }
  return pools;
}

// A pool's gauge and both of its reward contracts, as PoolsVoter registered them, read once per pair per run. Null
// for a pool with no gauge, or a gauge missing either contract, which LoanManager would refuse as UnknownGauge.
async function gaugeOf(h: Harvester, pool: Address): Promise<{ gauge: Address; sides: [RewardSide, RewardSide] } | null> {
  const cached = h.gauges.get(pool);
  if (cached !== undefined) return cached;
  const { reader } = h.pass.clients;
  const gauge = await reader.readContract({ address: h.voter, abi: poolsVoterAbi, functionName: "gauges", args: [pool] });
  let found: { gauge: Address; sides: [RewardSide, RewardSide] } | null = null;
  if (!isAddressEqual(gauge, zeroAddress)) {
    const [fees, bribe] = await Promise.all([
      reader.readContract({ address: h.voter, abi: poolsVoterAbi, functionName: "gaugeToFees", args: [gauge] }),
      reader.readContract({ address: h.voter, abi: poolsVoterAbi, functionName: "gaugeToBribe", args: [gauge] }),
    ]);
    if (!isAddressEqual(fees, zeroAddress) && !isAddressEqual(bribe, zeroAddress)) {
      const side = async (reward: Address): Promise<RewardSide> => {
        const listed = await Promise.all(
          [h.musd, h.btc].map((token) => reader.readContract({ address: reward, abi: votingRewardAbi, functionName: "isReward", args: [token] })),
        );
        return { reward, tokens: [h.musd, h.btc].filter((_, i) => listed[i]) };
      };
      found = { gauge: getAddress(gauge), sides: [await side(fees), await side(bribe)] };
    }
  }
  h.gauges.set(pool, found);
  return found;
}

// What one side would pay this position now, keeping only the tokens with something earned so the claim spends
// no gas on empty lists.
async function earnedOn(h: Harvester, side: RewardSide, tokenId: bigint): Promise<{ tokens: Address[]; musd: bigint; btc: bigint }> {
  const { reader } = h.pass.clients;
  const amounts = await Promise.all(
    side.tokens.map((token) => reader.readContract({ address: side.reward, abi: votingRewardAbi, functionName: "earned", args: [token, tokenId] })),
  );
  const out = { tokens: [] as Address[], musd: 0n, btc: 0n };
  side.tokens.forEach((token, i) => {
    const amount = amounts[i]!;
    if (amount === 0n) return;
    out.tokens.push(token);
    if (isAddressEqual(token, h.musd)) out.musd += amount;
    else out.btc += amount;
  });
  return out;
}

// The decoded name of a revert, or undefined for anything else.
function revertName(err: unknown): string | undefined {
  if (!(err instanceof BaseError)) return undefined;
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
  return reverted instanceof ContractFunctionRevertedError ? reverted.data?.errorName : undefined;
}

// Throws the refusal, decoded with harvestAbi. Harvests count against their own budget, never against MAX_ACTIONS.
async function simulateHarvest(
  h: Harvester,
  tokenId: bigint,
  plan: HarvestPlan,
): Promise<{ repaid: bigint; send: () => Promise<Hash> }> {
  const { reader, writer, account } = h.pass.clients;
  const address = h.payDown;
  const args = [tokenId, plan.gauges, plan.feeTokens, plan.bribeTokens] as const;
  const { request, result } = await reader.simulateContract({ address, abi: harvestAbi, functionName: "harvest", args, account });
  const estimate = () => reader.estimateContractGas({ address, abi: harvestAbi, functionName: "harvest", args, account: account! });
  return { repaid: result, send: async () => writer!.writeContract({ ...request, gas: await plausibleGas(estimate) }) };
}

// A request that failed is not a refusal, so only a revert outside EXPECTED_REFUSALS fails the run (exit code 4).
function reportRefusal(h: Harvester, subject: string, decision: Decision<string>, err: unknown): void {
  const { pass } = h;
  pass.summary.failedSimulations += 1;
  if (isRevert(err) && !EXPECTED_REFUSALS.has(revertName(err) ?? "")) pass.summary.unexpectedRefusals += 1;
  line(pass, subject, decision.action, decision.reason, `simulation failed, skipped: ${describeError(err)}`);
}

// The same plan with BTC on no list and no gauge left with nothing to claim.
function dropBtc(h: Harvester, plan: HarvestPlan): HarvestPlan {
  const kept: HarvestPlan = { gauges: [], feeTokens: [], bribeTokens: [] };
  const keep = (tokens: Address[]) => tokens.filter((token) => !isAddressEqual(token, h.btc));
  plan.gauges.forEach((gauge, i) => {
    const fee = keep(plan.feeTokens[i]!);
    const bribe = keep(plan.bribeTokens[i]!);
    if (fee.length + bribe.length === 0) return;
    kept.gauges.push(gauge);
    kept.feeTokens.push(fee);
    kept.bribeTokens.push(bribe);
  });
  return kept;
}

// C39, C48: a harvest is one transaction, so a BTC sale that cannot happen would hold back the MUSD too. BTC left off
// the lists is never claimed, so it stays in Mezo's reward contract and the next run tries the full plan first. Only
// BTC is dropped and no floor changes, and the plan is judged on what it will claim: MUSD alone.
async function harvestWithoutBtc(h: Harvester, tokenId: bigint, plan: HarvestPlan, left: BtcLeftOut): Promise<void> {
  const { pass } = h;
  const { musd, btc, why, rest } = left;
  const subject = `harvest ${tokenId}`;
  const skip = (reason: string): void => {
    pass.summary.harvestSkips += 1;
    line(pass, subject, "skip", `${why}; ${reason}`, "-");
  };
  const smaller = dropBtc(h, plan);
  if (smaller.gauges.length === 0) return skip(`its ${formatEther(btc)} BTC is all it earned, so that waits for a later harvest`);
  if (musd < pass.config.harvestMinMusd) {
    return skip(`without BTC it claims ${formatEther(musd)} MUSD, below HARVEST_MIN_MUSD ${formatEther(pass.config.harvestMinMusd)}`);
  }
  let simulated: Awaited<ReturnType<typeof simulateHarvest>>;
  try {
    simulated = await simulateHarvest(h, tokenId, smaller);
  } catch (err) {
    return reportRefusal(h, subject, { action: "harvest", reason: `without BTC: ${why}` }, err);
  }
  if (simulated.repaid === 0n) return skip("without BTC it would repay nothing");
  pass.summary.harvests += 1;
  const verb = pass.config.dry ? "would be sent" : "sent";
  const told = `${subject} ${verb} without BTC: ${why}; repays ${formatEther(simulated.repaid)} MUSD, ${formatEther(btc)} BTC waits for a later harvest${rest}`;
  await deliver(pass, (outcome) => console.log(`${pass.tag} ${told} | ${outcome}`), simulated.send);
}

// C48: one position's harvest. Every condition is read from the chain this run; the simulation and the contract
// floors (C39) decide the rest.
async function handleHarvest(h: Harvester, tokenId: bigint): Promise<void> {
  const { pass, payDown, price } = h;
  const { reader } = pass.clients;
  const subject = `harvest ${tokenId}`;
  const skip = (reason: string): void => {
    pass.summary.harvestSkips += 1;
    line(pass, subject, "skip", reason, "-");
  };
  const position = await reader.readContract({
    address: pass.record.loanManager,
    abi: loanManagerAbi,
    functionName: "positionOf",
    args: [tokenId],
  });
  if (isAddressEqual(position.borrower, zeroAddress)) return skip("LoanManager no longer holds this position");
  if (!isAddressEqual(position.rewardOperator, payDown)) {
    const now = isAddressEqual(position.rewardOperator, zeroAddress) ? "none" : position.rewardOperator;
    return skip(`reward operator is now ${now}, not PayDown`);
  }
  const pools = await votedPools(h, tokenId);
  if (pools.length === 0) return skip("no standing pool vote, so no gauge to claim from");

  const gauges: Address[] = [];
  const feeTokens: Address[][] = [];
  const bribeTokens: Address[][] = [];
  let listed = 0;
  let waiting = 0;
  let musd = 0n;
  let btc = 0n;
  for (const pool of pools) {
    const found = await gaugeOf(h, pool);
    if (found === null || gauges.some((g) => isAddressEqual(g, found.gauge))) continue;
    const [fee, bribe] = await Promise.all(found.sides.map((side) => earnedOn(h, side, tokenId)));
    const n = fee!.tokens.length + bribe!.tokens.length;
    if (n === 0) continue;
    if (listed + n > MAX_HARVEST_TOKENS) {
      waiting += 1;
      continue;
    }
    listed += n;
    gauges.push(found.gauge);
    feeTokens.push(fee!.tokens);
    bribeTokens.push(bribe!.tokens);
    musd += fee!.musd + bribe!.musd;
    btc += fee!.btc + bribe!.btc;
  }
  if (gauges.length === 0) return skip(`nothing earned in MUSD or BTC on the ${pools.length} pool(s) it votes for`);

  const plan: HarvestPlan = { gauges, feeTokens, bribeTokens };
  const rest = waiting > 0 ? `; ${waiting} more gauge(s) wait for the next harvest` : "";
  if (btc > 0n && price === undefined) return harvestWithoutBtc(h, tokenId, plan, { musd, btc, why: h.noPrice, rest });

  const worth = price === undefined ? musd : musd + (btc * price) / PRICE_SCALE;
  const earned = `${formatEther(musd)} MUSD and ${formatEther(btc)} BTC earned, worth ${formatEther(worth)} MUSD`;
  if (worth < pass.config.harvestMinMusd) {
    return skip(`${earned}, below HARVEST_MIN_MUSD ${formatEther(pass.config.harvestMinMusd)}`);
  }
  const decision = { action: "harvest", reason: `${earned}, ${listed} token(s) from ${gauges.length} gauge(s)${rest}` };
  let simulated: Awaited<ReturnType<typeof simulateHarvest>>;
  try {
    simulated = await simulateHarvest(h, tokenId, plan);
  } catch (err) {
    const why = BTC_REFUSALS.get(revertName(err) ?? "");
    if (btc === 0n || why === undefined) return reportRefusal(h, subject, decision, err);
    return harvestWithoutBtc(h, tokenId, plan, { musd, btc, why: `${why} (${describeError(err)})`, rest });
  }
  pass.summary.harvests += 1;
  await deliver(pass, (outcome) => line(pass, subject, decision.action, decision.reason, outcome), simulated.send);
}

// The harvest job for one pair that has a PayDown, spending what is left of the run's HARVEST_MAX_POSITIONS.
async function harvestPair(pass: Pass, payDown: Address, head: bigint): Promise<void> {
  const { reader } = pass.clients;
  const left = pass.config.harvestMaxPositions - pass.summary.harvestPositions;
  if (left <= 0) {
    line(pass, "harvest", "none", `harvest skipped: HARVEST_MAX_POSITIONS=${pass.config.harvestMaxPositions} already read this run`, "-");
    return;
  }
  const [paused, musd, btc, feed, voter] = await Promise.all([
    reader.readContract({ address: payDown, abi: payDownAbi, functionName: "paused" }),
    reader.readContract({ address: payDown, abi: payDownAbi, functionName: "musd" }),
    reader.readContract({ address: payDown, abi: payDownAbi, functionName: "btc" }),
    reader.readContract({ address: payDown, abi: payDownAbi, functionName: "priceFeed" }),
    reader.readContract({ address: pass.record.loanManager, abi: loanManagerAbi, functionName: "poolsVoter" }),
  ]);
  if (paused) {
    line(pass, "harvest", "none", `harvest skipped: PayDown ${payDown} is paused`, "-");
    return;
  }
  // PayDown reads the price only when a harvest sells BTC (C7), so an outage must not stop the harvests that repay
  // with MUSD alone. With no price, BTC cannot be valued or sold, so every plan this run leaves it out.
  let price: bigint | undefined;
  let noPrice = "";
  try {
    const read = await reader.readContract({ address: feed, abi: priceFeedAbi, functionName: "fetchPrice" });
    if (read === 0n) noPrice = "the BTC price feed returned zero";
    else price = read;
  } catch (err) {
    noPrice = `the BTC price could not be read (${describeError(err)})`;
  }
  if (price === undefined) line(pass, "harvest", "none", `${noPrice}: BTC rewards wait this run`, "-");

  const scan = await collectOperatorLogs(pass, head);
  const candidates = selectHarvestCandidates(scan.logs, payDown);
  console.log(`${pass.tag} harvest scan: ${scan.text}; ${candidates.length} position(s) name PayDown ${payDown}`);
  const chosen = harvestWindow(candidates, left, pass.now);
  if (chosen.length < candidates.length) {
    console.log(`${pass.tag} harvest: reading ${chosen.length} of ${candidates.length} positions from ${chosen[0]}; the rest wait for later runs`);
  }
  const h: Harvester = {
    pass,
    payDown,
    voter: getAddress(voter),
    musd: getAddress(musd),
    btc: getAddress(btc),
    price,
    noPrice,
    gauges: new Map(),
  };
  for (const tokenId of chosen) {
    pass.summary.harvestPositions += 1;
    try {
      await handleHarvest(h, tokenId);
    } catch (err) {
      pass.summary.harvestSkips += 1;
      line(pass, `harvest ${tokenId}`, "skip", `read failed: ${describeError(err)}`, "-");
    }
  }
}

// C48: harvests start only once every resolution job has run and none was left undone, and every run says why it
// skipped any.
async function runHarvests(passes: Pass[], head: bigint): Promise<void> {
  const first = passes[0];
  if (first === undefined) return;
  const { config, summary, shared } = first;
  const blocked =
    config.harvestMaxPositions === 0
      ? "HARVEST_MAX_POSITIONS is 0"
      : shared.capped
        ? `resolution used all MAX_ACTIONS=${config.maxActions} writes, so it comes first next run`
        : summary.pairFailures > 0
          ? `${summary.pairFailures} pair(s) stopped before resolution finished`
          : undefined;
  for (const pass of passes) {
    const payDown = pass.record.payDown;
    if (payDown === undefined) {
      line(pass, "harvest", "none", "harvest skipped: no PayDown in this record", "-");
      continue;
    }
    if (blocked !== undefined) {
      line(pass, "harvest", "none", `harvest skipped: ${blocked}`, "-");
      continue;
    }
    try {
      await harvestPair(pass, payDown, head);
    } catch (err) {
      line(pass, "harvest", "none", `harvest stopped: ${describeError(err)}`, "-");
    }
  }
}

export async function runPass(config: Config): Promise<PassSummary> {
  const records = loadDeployments(config.deploymentFiles);
  const clients = makeClients(config);
  const chainId = await clients.reader.getChainId();
  if (chainId !== MEZO_TESTNET_CHAIN_ID) throw new Error(`RPC is on chain ${chainId}, expected ${MEZO_TESTNET_CHAIN_ID}`);
  const vaults: (Address | undefined)[] = [];
  for (const record of records) vaults.push(await checkDeployment(clients, record));

  const head = await clients.reader.getBlock({ blockTag: "latest" });
  const width = Math.max(...records.map((r) => r.name.length));
  const summary: PassSummary = {
    tokenIds: 0,
    openLoans: 0,
    maturities: 0,
    actions: 0,
    harvestPositions: 0,
    harvests: 0,
    harvestSkips: 0,
    failedSimulations: 0,
    failedSends: 0,
    vaultAlerts: 0,
    pairFailures: 0,
    unexpectedRefusals: 0,
  };
  const shared: Shared = { capped: false, vaultAlerts: [] };
  const passes: Pass[] = records.map((record, i) => ({
    config,
    clients,
    record,
    tag: record.name.padEnd(width),
    vault: vaults[i],
    now: head.timestamp,
    summary,
    shared,
  }));
  if (clients.account === undefined) console.log("role check skipped: no keeper key loaded");
  else await checkKeeperHasNoRole(clients.reader, passes, clients.account.address, config.dry);

  console.log(`Doji keeper, ${config.dry ? "dry run: simulates only, sends nothing" : "live run"}`);
  console.log(`rpc ${new URL(config.rpcUrl).host}, chain ${MEZO_TESTNET_CHAIN_ID}, block ${head.number}, ${utc(head.timestamp)}`);
  console.log(
    `${passes.length} pair(s); max ${config.maxActions} resolution writes; harvests read at most ` +
      `${config.harvestMaxPositions} positions worth at least ${formatEther(config.harvestMinMusd)} MUSD`,
  );
  const named = (address: Address | undefined) => address ?? "none";
  for (const pass of passes) {
    const r = pass.record;
    console.log(
      `${pass.tag} pair: chain ${r.chainId}, LoanManager ${r.loanManager}, CreditMarkets ${r.creditMarkets}, ` +
        `PayDown ${named(r.payDown)}, UnitMarket ${named(r.unitMarket)}, vault ${named(pass.vault)}, from block ${r.block}`,
    );
  }
  if (clients.account !== undefined) {
    const gas = await clients.reader.getBalance({ address: clients.account.address });
    console.log(`keeper wallet ${clients.account.address} holds ${formatEther(gas)} BTC for gas`);
  }
  if (config.vaultCheckOverride !== undefined) {
    console.log(
      `warning: VAULT_CHECK_OVERRIDE is set, so the vault check calls ${config.vaultCheckOverride} instead of each ` +
        "pair's vault; it is a test hook for proving the alert and must never be set on GitHub",
    );
  }

  // C35 runs first, before anything that could stop the run, so every run that gets this far checks the vault.
  for (const pass of passes) await checkVault(pass);

  // C48: every resolution job of every pair runs before any harvest. A pair whose jobs stop (a log page that
  // failed twice) does not stop the others, and the run still ends red.
  for (const pass of passes) {
    try {
      await resolvePair(pass, head.number);
    } catch (err) {
      summary.pairFailures += 1;
      console.log(`${pass.tag} resolution stopped: ${describeError(err)}; the run exits 1`);
    }
  }
  await runHarvests(passes, head.number);

  const s = summary;
  const mode = config.dry ? "simulated" : "sent";
  console.log(
    plainText(
      `done: ${s.openLoans} open of ${s.tokenIds} positions, ${s.maturities} maturities, ${s.actions} ${mode}; ` +
        `${s.harvests} harvests ${mode}, ${s.harvestSkips} positions skipped of ${s.harvestPositions} read; ` +
        `${s.failedSimulations} refused in simulation, ${s.unexpectedRefusals} of them unexpected, ` +
        `${s.failedSends} failed sends, ${s.vaultAlerts} vault alerts`,
    ),
  );
  // Repeated last so the alert is the final thing on the run's page, where the emailed link lands.
  for (const alert of shared.vaultAlerts) console.log(alert);
  return s;
}

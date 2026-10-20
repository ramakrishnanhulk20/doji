import { createPublicClient, formatUnits, http, isAddress, parseUnits, type Address } from "viem";
import { erc20Abi, veBtcAbi } from "../src/abi/external";
import { addressBook } from "../src/lib/addresses";
import {
  CENT,
  groupOffersByDate,
  lockDurationFor,
  maxPrincipal,
  roundDownToCent,
  selectOffers,
  type DateGroup,
} from "../src/lib/borrow";
import { confirmMaxPrincipal, readBorrowSettings, readPositions, readPrice } from "../src/lib/borrow-reads";
import { mezoTestnetChain } from "../src/lib/chains";
import { formatApr, formatDate, formatMusd, scanOpenOffers } from "../src/lib/stats";

// Read-only: every call below is a view or an eth_call, and no key is involved.
const owner = process.env.CHECK_ADDRESS;
if (!owner || !isAddress(owner)) {
  console.error("Set CHECK_ADDRESS to the wallet address to check, for example CHECK_ADDRESS=0x92Dc... npm run check:borrow");
  process.exit(1);
}
const address: Address = owner;

const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) });
const book = addressBook[31611];
const units = (value: bigint) => formatMusd(Number(formatUnits(value, 18)));

const now = Math.floor(Date.now() / 1000);
const [settings, price, offers] = await Promise.all([readBorrowSettings(client), readPrice(client), scanOpenOffers()]);
const groups = groupOffersByDate(offers);

console.log(`price ${units(price)} MUSD per BTC, limit ${settings.maxLtvBps / 100}%, auction line ${settings.liqLtvBps / 100}%, minimum loan ${units(settings.minLoan)} MUSD, borrows ${settings.borrowsPaused ? "paused" : "open"}`);
for (const group of groups) {
  console.log(`${formatDate(group.maturity)}: ${group.offers.length} offers, ${units(group.available)} MUSD, best ${formatApr(group.bestAprBps / 100)}`);
}

// What a given collateral value can borrow on one date, confirmed with the contract's own quotes.
async function borrowable(group: DateGroup, valueWei: bigint) {
  const secondsToMaturity = group.maturity - now;
  const maxFace = (valueWei * BigInt(settings.maxLtvBps)) / 10_000n;
  const local = roundDownToCent(maxPrincipal({ offers: group.offers, maxFace, secondsToMaturity }));
  const confirmed = await confirmMaxPrincipal(client, {
    maturity: group.maturity,
    start: local,
    maxFace,
    pick: (principal) => selectOffers(principal, group.offers),
    step: CENT,
  });
  return { ...confirmed, selection: selectOffers(confirmed.principal, group.offers), maxFace };
}

const earliest = groups[0];
if (!earliest) {
  console.log("no open offers, so there is nothing to borrow against");
  process.exit(0);
}

const lockWei = parseUnits("0.001", 18);
const lockValue = (lockWei * price) / 10n ** 18n;
const lockResult = await borrowable(earliest, lockValue);
console.log(
  `lock 0.001 BTC (worth ${units(lockValue)} MUSD) to ${formatDate(earliest.maturity)}: max principal ${units(lockResult.principal)} MUSD, quoted face ${units(lockResult.face)} MUSD`,
);
console.log(
  `selected offers: ${lockResult.selection.offerIds.map((id, index) => `#${id} ${units(lockResult.selection.amounts[index] ?? 0n)} MUSD at ${formatApr((lockResult.selection.aprs[index] ?? 0) / 100)}`).join(", ") || "none"}; maxAprBps ${lockResult.selection.maxAprBps}`,
);
console.log(`lockDuration ${lockDurationFor(earliest.maturity, now)} seconds (lock ends ${formatDate(earliest.maturity)})`);

async function simulateApprove(label: string, run: () => Promise<unknown>) {
  try {
    await run();
    console.log(`${label}: simulation ok`);
  } catch (error) {
    console.log(`${label}: simulation failed, ${(error as Error).message.split("\n")[0]}`);
  }
}

await simulateApprove("approve 0.001 BTC to LoanManager on the BTC ERC-20", () =>
  client.simulateContract({
    account: address,
    address: book.btc,
    abi: erc20Abi,
    functionName: "approve",
    args: [book.loanManager, lockWei],
  }),
);

const positions = await readPositions(client, address, price);
console.log(`veBTC positions owned: ${positions.length} (${positions.map((p) => `#${p.id}${p.accepted ? "" : " not accepted"}`).join(", ") || "none"})`);

const position = positions.find((candidate) => candidate.accepted);
if (position) {
  const group = groups.find((candidate) => position.isPermanent || candidate.maturity <= position.end);
  if (group) {
    const result = await borrowable(group, position.value);
    console.log(
      `veBTC #${position.id} (${formatUnits(position.amount, 18)} BTC, worth ${units(position.value)} MUSD) to ${formatDate(group.maturity)}: max principal ${units(result.principal)} MUSD, quoted face ${units(result.face)} MUSD`,
    );
  } else {
    console.log(`veBTC #${position.id}: no open date falls before its lock ends`);
  }
  await simulateApprove(`approve(LoanManager, ${position.id}) on veBTC`, () =>
    client.simulateContract({
      account: address,
      address: book.veBTC,
      abi: veBtcAbi,
      functionName: "approve",
      args: [book.loanManager, position.id],
    }),
  );
} else {
  console.log("no accepted veBTC position in this wallet");
}

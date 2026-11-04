import { createPublicClient, formatUnits, http, type PublicClient } from "viem";
import { mezoTestnetChain } from "../src/lib/chains";
import { readParking } from "../src/lib/lend";
import { formatApr, formatDate, formatMusd, scanPairOffers, usableOffers, type OpenOffer } from "../src/lib/stats";

// Read-only. It runs the C52 rule Borrow and Roll use, usableOffers, on the live Wave 2 and 20 October offers with the
// vault forced down, so an outage is tested without one. It does not cover the hooks, the strips or a real outage.
// Lines marked "note" depend on live state that may move; "FAIL" lines fail the run.
const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) }) as PublicClient;

let failures = 0;
const check = (ok: boolean, text: string) => {
  if (!ok) failures += 1;
  console.log(`  ${ok ? "ok" : "FAIL"}: ${text}`);
};
const note = (ok: boolean, text: string) => console.log(`  ${ok ? "note, as expected" : "note, differs"}: ${text}`);
const idsOf = (offers: readonly OpenOffer[]) => offers.map((offer) => offer.id).join(", ") || "none";
const print = (offers: readonly OpenOffer[]) => {
  for (const offer of offers) {
    const left = formatMusd(Number(formatUnits(offer.remaining, 18)));
    console.log(
      `  #${offer.id} [${offer.pair}] ${formatDate(offer.maturity)} at ${formatApr(offer.aprBps / 100)}, ${left} MUSD left, ${offer.parked ? "parked" : "plain"}`,
    );
  }
};

console.log("== Mezo's sMUSD vault, as the keeper checks it (readParking)");
const parking = await readParking(client);
console.log(`  parking on: ${parking.on}, vault: ${parking.vault}`);
note(parking.vault === "ok", `the vault answers ${parking.vault} (expected ok)`);

const wave2 = await scanPairOffers("wave2");
console.log(`\n== Wave 2 open offers: ${wave2.length}`);
print(wave2);
const parked = wave2.filter((offer) => offer.parked);
const plain = wave2.filter((offer) => !offer.parked);
note(idsOf(parked) === "1, 2", `parked offers are ${idsOf(parked)} (expected 1, 2)`);
note(idsOf(plain) === "3", `plain offers are ${idsOf(plain)} (expected 3)`);

console.log("\n== The rule with the vault up");
const whenUp = usableOffers(wave2, false);
print(whenUp);
check(idsOf(whenUp) === idsOf(wave2), `every open offer is usable (${idsOf(whenUp)})`);

console.log("\n== The rule with the vault forced down");
const whenDown = usableOffers(wave2, true);
print(whenDown);
check(whenDown.every((offer) => !offer.parked), "no parked offer is left");
check(idsOf(whenDown) === idsOf(plain), `every plain offer is kept (${idsOf(whenDown)})`);
note(idsOf(whenDown) === "3", `Borrow and a Wave 2 roll would use offers ${idsOf(whenDown)} (expected only 3)`);

const legacy = await scanPairOffers("legacy");
console.log(`\n== 20 October open offers with the vault forced down: ${legacy.length}`);
const legacyDown = usableOffers(legacy, true);
print(legacyDown);
check(legacy.every((offer) => !offer.parked), "no 20 October offer reads as parked");
check(idsOf(legacyDown) === idsOf(legacy), `a 20 October roll keeps every offer (${idsOf(legacyDown)})`);

console.log(`\n${failures === 0 ? "every outage check passed" : `${failures} outage checks failed`}`);
process.exit(failures === 0 ? 0 : 1);

import { createPublicClient, http, type PublicClient } from "viem";
import { STRANGER, buildAttacks, readAttackTargets, runAttack } from "../src/lib/attacks";
import { mezoTestnetChain } from "../src/lib/chains";

// Read-only: every attack is an eth_call from the stranger's address, so no key is involved and nothing is sent.
const client = createPublicClient({ chain: mezoTestnetChain, transport: http(undefined, { batch: true }) }) as PublicClient;
const caller = STRANGER;

const targets = await readAttackTargets(client, Math.floor(Date.now() / 1000));
console.log(
  `targets: demo loan #${targets.demoTokenId}, auction ${targets.auctionTokenId ?? "none open"}, offer ${targets.offerId ?? "none"}, earliest Thursday ${targets.earliestThursday}, next Thursday ${targets.nextThursday}, pool ${targets.pool ?? "none"}`,
);

let matched = 0;
let problems = 0;
const attacks = buildAttacks(targets, caller);

for (const [index, attack] of attacks.entries()) {
  const label = `${String(index + 1).padStart(2, " ")}. ${attack.call}`;
  if (attack.unavailable !== null) {
    problems += 1;
    console.log(`${label}\n    not run: ${attack.unavailable}`);
    continue;
  }
  const outcome = await runAttack(client, attack, caller);
  if (outcome.kind === "refused") {
    const verdict = outcome.matches ? "MATCHES" : `DIFFERS (expected ${attack.expected})`;
    if (outcome.matches) matched += 1;
    else problems += 1;
    console.log(`${label}\n    refused: ${outcome.errorName} | ${outcome.detail} | block ${outcome.block} | ${verdict}`);
  } else if (outcome.kind === "through") {
    problems += 1;
    console.log(`${label}\n    WOULD GO THROUGH at block ${outcome.block} | ${attack.goesThrough}`);
  } else {
    problems += 1;
    console.log(`${label}\n    could not run: ${outcome.detail}`);
  }
}

console.log(`\n${matched} of ${attacks.length} refused with the expected error, ${problems} need a look`);
process.exit(problems === 0 ? 0 : 1);

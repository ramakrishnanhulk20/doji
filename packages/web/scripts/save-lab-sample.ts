import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress } from "viem";
import { readWalletProgress } from "../src/lib/quests/read-wallet";

// Saves one real wallet's quest progress, read from the chain right now, so the ledger lab draws from a real response
// (long hashes, real dates, unfinished quests) and never from typed values. Run it again to refresh the sample.

const BORROWER = getAddress("0x92DcCb70C33300848Da555eDe8597d3F7037AE2b");
const ATTEMPTS = 5;
const WAIT_MS = 4_000;

const out = join(dirname(fileURLToPath(import.meta.url)), "../src/components/ledger/lab-sample.json");

for (let attempt = 1; attempt <= ATTEMPTS; attempt += 1) {
  const progress = await readWalletProgress(BORROWER);
  // A partial read can miss quests the wallet really finished, so it is never saved.
  if (progress.complete) {
    writeFileSync(out, `${JSON.stringify(progress, null, 2)}\n`);
    const done = progress.quests.filter((quest) => quest.done).length;
    console.log(`saved ${out}`);
    console.log(`${progress.address}: ${progress.exp} EXP, rank ${progress.rank.id}, ${done} of ${progress.quests.length} quests done`);
    process.exit(0);
  }
  console.log(`read ${attempt} of ${ATTEMPTS} was incomplete`);
  await new Promise((resolve) => setTimeout(resolve, WAIT_MS));
}

console.error("every read was incomplete, so nothing was saved");
process.exit(1);

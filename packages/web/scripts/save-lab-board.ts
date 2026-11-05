import { writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Saves the real leaderboard, Doji's own wallets included, for the banzuke lab page. No outside tester exists yet, so
// the public filter would leave the board empty and nothing could be judged. It runs the same two functions the
// /api/leaderboard route runs. Only the Doji wallet list is swapped for an empty one, and only inside read-all.ts.
// Run from packages/web: npx tsx scripts/save-lab-board.ts

const FILTER_OFF = `data:text/javascript,${encodeURIComponent("export const isDojiWallet = () => false;")}`;

// read-all.ts refuses to load outside a Next server build, and it asks the wallet list who to leave out.
registerHooks({
  resolve: (specifier, context, next) => {
    if (specifier === "server-only") return { url: "data:text/javascript,", shortCircuit: true };
    if (specifier === "../doji-wallets" && context.parentURL?.endsWith("/quests/read-all.ts")) {
      return { url: FILTER_OFF, shortCircuit: true };
    }
    return next(specifier, context);
  },
});
const { leaderboardRows, readAllProgress } = await import("../src/lib/quests/read-all");

const SCAN_BUDGET_MS = 45_000;

const asOf = Math.floor(Date.now() / 1000);
const { wallets, complete } = await readAllProgress(Date.now() + SCAN_BUDGET_MS);
if (!complete) {
  console.error("The scan was incomplete, so nothing was saved. Run it again.");
  process.exit(1);
}

const rows = leaderboardRows(wallets);
const target = join(dirname(fileURLToPath(import.meta.url)), "../src/components/ledger/lab-board.json");
writeFileSync(target, `${JSON.stringify({ asOf, rows }, null, 2)}\n`);
console.log(`saved ${rows.length} rows, as of ${asOf}`);

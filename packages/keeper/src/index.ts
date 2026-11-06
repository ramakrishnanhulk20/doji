import { ConfigError, loadConfig } from "./config.js";
import { describeError } from "./chain.js";
import { runPass } from "./keeper.js";

const args = process.argv.slice(2);
const unknown = args.filter((a) => a !== "--dry");

// Exit codes. Anything but 0 turns the scheduled run red, which is how a fault reaches the repository owner.
// 0: the pass finished, even if a harvest was refused for an expected reason (the chain moved on).
// 1: a setting is missing, a record or the chain does not check out, a pair's jobs stopped, or a sent transaction failed.
// 2: a checked date has more open loans on chain than the scan found, or could not be checked. checkCompleteness sets it.
// 3: a vault check raised a VAULT ALERT (C35).
// 4: a harvest was refused for a reason outside the known refusals, so the keeper and the contracts disagree.
// 5: more open loans or loan dates exist than one run reads, so some wait. Every due job within the bound still ran.
// When more than one applies, 1 wins over 3, 3 over 4, 4 over 2, and 2 over 5. A dry run exits 2, 3, 4 and 5 the same way.
if (unknown.length > 0) {
  console.error(`unknown argument ${unknown.join(" ")}; the only flag is --dry`);
  process.exitCode = 2;
} else {
  try {
    const summary = await runPass(loadConfig(args.includes("--dry")));
    if (summary.failedSends > 0 || summary.pairFailures > 0) process.exitCode = 1;
    else if (summary.vaultAlerts > 0) process.exitCode = 3;
    else if (summary.unexpectedRefusals > 0) process.exitCode = 4;
    // checkCompleteness may already have set 2, which outranks 5.
    if (!process.exitCode && (summary.loansNotRead > 0 || summary.datesNotRead > 0)) process.exitCode = 5;
  } catch (err) {
    const message = err instanceof ConfigError ? err.message : describeError(err);
    console.error(`keeper stopped: ${message}`);
    process.exitCode = 1;
  }
}

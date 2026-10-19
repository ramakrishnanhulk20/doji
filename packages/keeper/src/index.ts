import { ConfigError, loadConfig } from "./config.js";
import { describeError } from "./chain.js";
import { runPass } from "./keeper.js";

const args = process.argv.slice(2);
const unknown = args.filter((a) => a !== "--dry");

if (unknown.length > 0) {
  console.error(`unknown argument ${unknown.join(" ")}; the only flag is --dry`);
  process.exitCode = 2;
} else {
  try {
    const summary = await runPass(loadConfig(args.includes("--dry")));
    // A refused simulation is normal (the chain moved on); a transaction that was sent and failed is not.
    if (summary.failedSends > 0) process.exitCode = 1;
  } catch (err) {
    const message = err instanceof ConfigError ? err.message : describeError(err);
    console.error(`keeper stopped: ${message}`);
    process.exitCode = 1;
  }
}

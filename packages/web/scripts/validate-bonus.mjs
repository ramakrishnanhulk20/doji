import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseAddress } from "../src/lib/address.ts";
import { BONUS_EXP_CAP } from "../src/lib/quests/table.ts";

// Run through tsx at prebuild, so the wallet check here is the app's own parser and not a copy of it (C66). A bad file
// fails the build and is never partly applied (C74). An entry goes in only with the reporter's yes, because git history
// keeps the wallet-to-identity link for good (F46).

const REASON_LENGTH = 200;

const here = dirname(fileURLToPath(import.meta.url));
const source = process.argv[2] ? resolve(process.argv[2]) : resolve(here, "../content/quests/bonus-exp.json");

function isHttps(value) {
  if (typeof value !== "string") return false;
  try {
    return new URL(value).protocol === "https:";
  } catch {
    return false;
  }
}

function problemsWith(entry, seen) {
  if (typeof entry !== "object" || entry === null || Array.isArray(entry)) return ["is not an object"];
  const problems = [];
  const wallet = parseAddress(entry.address);
  if (wallet === null) problems.push("address is not a valid address");
  else if (seen.has(wallet)) problems.push(`${wallet} appears twice`);
  else seen.add(wallet);
  if (!Number.isSafeInteger(entry.exp) || entry.exp <= 0 || entry.exp > BONUS_EXP_CAP) {
    problems.push(`exp must be a whole number from 1 to ${BONUS_EXP_CAP}`);
  }
  if (typeof entry.reason !== "string" || entry.reason.trim() === "" || entry.reason.length >= REASON_LENGTH) {
    problems.push(`reason must be text under ${REASON_LENGTH} characters`);
  }
  if (!isHttps(entry.link)) problems.push("link must be an https URL");
  return problems;
}

function validate() {
  let entries;
  try {
    entries = JSON.parse(readFileSync(source, "utf8"));
  } catch (error) {
    return [`cannot read ${source}: ${error.message}`];
  }
  if (!Array.isArray(entries)) return [`${source} must be a list`];
  const seen = new Set();
  return entries.flatMap((entry, at) => problemsWith(entry, seen).map((problem) => `entry ${at}: ${problem}`));
}

const problems = validate();
if (problems.length > 0) {
  for (const problem of problems) console.error(`validate-bonus: ${problem}`);
  process.exit(1);
}

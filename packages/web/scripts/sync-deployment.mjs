import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, "../../contracts/deployments/31611.json");
const target = resolve(here, "../src/generated/deployment.ts");

const addressFields = ["loanManager", "creditMarkets", "passThrough", "musd", "btc", "veBTC", "priceFeed"];

const raw = JSON.parse(readFileSync(source, "utf8"));

if (raw.chainId !== 31611) {
  throw new Error(`sync-deployment: ${source} is for chain ${raw.chainId}, expected 31611`);
}

for (const field of addressFields) {
  if (typeof raw[field] !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(raw[field])) {
    throw new Error(`sync-deployment: field "${field}" is missing or not an address in ${source}`);
  }
}

if (!Number.isInteger(raw.block) || raw.block <= 0) {
  throw new Error(`sync-deployment: field "block" is missing or not a block number in ${source}`);
}

const lines = [
  "// Written by scripts/sync-deployment.mjs from packages/contracts/deployments/31611.json. Do not edit.",
  "export const deployment = {",
  "  chainId: 31611,",
  ...addressFields.map((field) => `  ${field}: "${raw[field]}" as \`0x\${string}\`,`),
  `  block: ${raw.block},`,
  "} as const;",
  "",
];

mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, lines.join("\n"), "utf8");
console.log(`sync-deployment: wrote ${target}`);

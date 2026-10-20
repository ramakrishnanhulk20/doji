import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, "../../contracts/deployments/31611.json");
const demoSource = resolve(here, "../../contracts/deployments/31611-demo.json");
const target = resolve(here, "../src/generated/deployment.ts");

const addressFields = [
  "loanManager",
  "creditMarkets",
  "passThrough",
  "musd",
  "btc",
  "veBTC",
  "priceFeed",
  "feeDistributor",
];

const isAddress = (value) => typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);

const raw = JSON.parse(readFileSync(source, "utf8"));

if (raw.chainId !== 31611) {
  throw new Error(`sync-deployment: ${source} is for chain ${raw.chainId}, expected 31611`);
}

for (const field of addressFields) {
  if (!isAddress(raw[field])) {
    throw new Error(`sync-deployment: field "${field}" is missing or not an address in ${source}`);
  }
}

if (!Number.isInteger(raw.block) || raw.block <= 0) {
  throw new Error(`sync-deployment: field "block" is missing or not a block number in ${source}`);
}

const demo = JSON.parse(readFileSync(demoSource, "utf8"));
const healthy = Object.values(demo.loans ?? {}).find((loan) => loan.role === "healthy");

if (!healthy) {
  throw new Error(`sync-deployment: no loan with role "healthy" in ${demoSource}`);
}
if (!Number.isInteger(healthy.tokenId) || healthy.tokenId <= 0) {
  throw new Error(`sync-deployment: the healthy loan has no tokenId in ${demoSource}`);
}
if (typeof healthy.hash !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(healthy.hash)) {
  throw new Error(`sync-deployment: the healthy loan has no transaction hash in ${demoSource}`);
}
if (!isAddress(healthy.borrower)) {
  throw new Error(`sync-deployment: the healthy loan has no borrower address in ${demoSource}`);
}

const hex = "`0x${string}`";

const lines = [
  "// Written by scripts/sync-deployment.mjs from packages/contracts/deployments/31611.json and 31611-demo.json. Do not edit.",
  "export const deployment = {",
  "  chainId: 31611,",
  ...addressFields.map((field) => `  ${field}: "${raw[field]}" as ${hex},`),
  `  block: ${raw.block},`,
  "  demoLoan: {",
  `    tokenId: ${healthy.tokenId}n,`,
  `    hash: "${healthy.hash}" as ${hex},`,
  `    borrower: "${healthy.borrower}" as ${hex},`,
  "  },",
  "} as const;",
  "",
];

mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, lines.join("\n"), "utf8");
console.log(`sync-deployment: wrote ${target}`);

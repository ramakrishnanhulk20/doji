import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const records = resolve(here, "../../contracts/deployments");
const wave2Source = resolve(records, "31611-wave2.json");
const demoSource = resolve(records, "31611-wave2-demo.json");
const legacySource = resolve(records, "31611.json");
const target = resolve(here, "../src/generated/deployment.ts");

const wave2Fields = [
  "loanManager",
  "creditMarkets",
  "passThrough",
  "payDown",
  "unitMarket",
  "savingsVault",
  "router",
  "poolsVoter",
  "musd",
  "btc",
  "veBTC",
  "priceFeed",
  "feeDistributor",
];
const legacyFields = ["loanManager", "creditMarkets", "passThrough"];
// Both pairs must sit on the same Mezo tokens and feeds, or a position or a balance could be read against the wrong one.
const sharedFields = ["musd", "btc", "veBTC", "priceFeed", "feeDistributor"];

const isAddress = (value) => typeof value === "string" && /^0x[0-9a-fA-F]{40}$/.test(value);
const sameAddress = (a, b) => a.toLowerCase() === b.toLowerCase();

function readRecord(source, fields) {
  const raw = JSON.parse(readFileSync(source, "utf8"));
  if (raw.chainId !== 31611) {
    throw new Error(`sync-deployment: ${source} is for chain ${raw.chainId}, expected 31611`);
  }
  for (const field of fields) {
    if (!isAddress(raw[field])) {
      throw new Error(`sync-deployment: field "${field}" is missing or not an address in ${source}`);
    }
  }
  if (!Number.isInteger(raw.block) || raw.block <= 0) {
    throw new Error(`sync-deployment: field "block" is missing or not a block number in ${source}`);
  }
  return raw;
}

const wave2 = readRecord(wave2Source, wave2Fields);
const legacy = readRecord(legacySource, [...legacyFields, ...sharedFields]);
const demo = readRecord(demoSource, ["loanManager", "creditMarkets"]);

for (const field of ["unitFeeBps", "payDownSlippageBps"]) {
  if (!Number.isInteger(wave2[field]) || wave2[field] < 0 || wave2[field] > 10_000) {
    throw new Error(`sync-deployment: field "${field}" is missing or not a basis-point number in ${wave2Source}`);
  }
}

for (const field of sharedFields) {
  if (!sameAddress(wave2[field], legacy[field])) {
    throw new Error(
      `sync-deployment: "${field}" is ${wave2[field]} in ${wave2Source} but ${legacy[field]} in ${legacySource}; both pairs must use the same Mezo contracts`,
    );
  }
}

for (const field of ["loanManager", "creditMarkets"]) {
  if (!sameAddress(demo[field], wave2[field])) {
    throw new Error(`sync-deployment: the demo record ${demoSource} names ${field} ${demo[field]}, not the Wave 2 ${wave2[field]}`);
  }
}

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
  "// Written by scripts/sync-deployment.mjs from packages/contracts/deployments/31611-wave2.json, 31611-wave2-demo.json and 31611.json. Do not edit.",
  "export const deployment = {",
  "  chainId: 31611,",
  ...wave2Fields.map((field) => `  ${field}: "${wave2[field]}" as ${hex},`),
  `  block: ${wave2.block},`,
  `  unitFeeBps: ${wave2.unitFeeBps},`,
  `  payDownSlippageBps: ${wave2.payDownSlippageBps},`,
  "  demoLoan: {",
  `    tokenId: ${healthy.tokenId}n,`,
  `    hash: "${healthy.hash}" as ${hex},`,
  `    borrower: "${healthy.borrower}" as ${hex},`,
  "  },",
  "} as const;",
  "",
  "export const legacyDeployment = {",
  ...legacyFields.map((field) => `  ${field}: "${legacy[field]}" as ${hex},`),
  `  block: ${legacy.block},`,
  "} as const;",
  "",
];

mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, lines.join("\n"), "utf8");
console.log(`sync-deployment: wrote ${target}`);

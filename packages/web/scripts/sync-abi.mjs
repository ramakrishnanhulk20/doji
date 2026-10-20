import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../contracts/out");
const targetDir = resolve(here, "../src/abi");

const contracts = [
  { name: "LoanManager", variable: "loanManagerAbi", file: "loanManager.ts" },
  { name: "CreditMarkets", variable: "creditMarketsAbi", file: "creditMarkets.ts" },
];

const keep = new Set(["function", "event", "error"]);

mkdirSync(targetDir, { recursive: true });

for (const contract of contracts) {
  const source = resolve(outDir, `${contract.name}.sol`, `${contract.name}.json`);
  let artifact;
  try {
    artifact = JSON.parse(readFileSync(source, "utf8"));
  } catch {
    throw new Error(`sync-abi: ${source} is missing. Run forge build in packages/contracts first.`);
  }
  if (!Array.isArray(artifact.abi)) {
    throw new Error(`sync-abi: ${source} has no abi array.`);
  }

  const abi = artifact.abi.filter((item) => keep.has(item.type));
  const lines = [
    `// Written by scripts/sync-abi.mjs from packages/contracts/out/${contract.name}.sol. Run npm run abi after the contracts change.`,
    `export const ${contract.variable} = ${JSON.stringify(abi, null, 2)} as const;`,
    "",
  ];
  const target = resolve(targetDir, contract.file);
  writeFileSync(target, lines.join("\n"), "utf8");
  console.log(`sync-abi: wrote ${target} (${abi.length} entries)`);
}

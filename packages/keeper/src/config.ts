import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";
import { getAddress, isAddress, isHex, parseEther, zeroAddress, type Address, type Hex } from "viem";

export const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const DEFAULT_RPC = "https://rpc.test.mezo.org";
const DEFAULT_EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const OLD_PAIR_FILE = "../contracts/deployments/31611.json";
const WAVE2_PAIR_FILE = "../contracts/deployments/31611-wave2.json";
// Every record is a full pass of reads, so the list is capped like every other loop in the keeper.
const MAX_DEPLOYMENT_FILES = 4;
const DEFAULT_MAX_ACTIONS = 10;
// A pass sends its writes one at a time and waits for each receipt, so even this ceiling finishes in minutes.
const MAX_ACTIONS_CEILING = 50;
const DEFAULT_HARVEST_MAX_POSITIONS = 10;
// Each position read is about five rounds of RPC reads and at most one harvest that waits for its receipt, so 20
// of them stay a few minutes on top of the resolution jobs, inside the 10-minute workflow.
const HARVEST_MAX_POSITIONS_CEILING = 20;
const DEFAULT_HARVEST_MIN_MUSD = "0.01";
export const MEZO_TESTNET_CHAIN_ID = 31_611;

// The keys the keeper reads. Nothing else from any env file reaches the process.
const KEEPER_KEYS = [
  "MEZO_TESTNET_RPC",
  "MEZO_TESTNET_EXPLORER_API",
  "KEEPER_PRIVATE_KEY",
  "DEPLOYMENT_FILES",
  "DEPLOYMENT_FILE",
  "MAX_ACTIONS",
  "HARVEST_MAX_POSITIONS",
  "HARVEST_MIN_MUSD",
] as const;
type KeeperKey = (typeof KEEPER_KEYS)[number];

export interface Config {
  dry: boolean;
  rpcUrl: string;
  explorerApi: string;
  privateKey: Hex | undefined;
  deploymentFiles: string[];
  maxActions: number;
  harvestMaxPositions: number;
  harvestMinMusd: bigint;
  vaultCheckOverride: Address | undefined;
}

// One pair of Doji contracts as its record names them. The new contracts are optional so the 20 October record,
// which has none of them, loads unchanged.
export interface DeploymentRecord {
  file: string;
  name: string;
  chainId: number;
  block: bigint;
  loanManager: Address;
  creditMarkets: Address;
  veBTC: Address;
  payDown: Address | undefined;
  unitMarket: Address | undefined;
  savingsVault: Address | undefined;
}

export class ConfigError extends Error {}

// Values already in the environment win; the contracts package's git-ignored .env fills only the keeper's own
// keys that are still missing, so a local run needs no exports and a CI run never looks for a file.
function readEnv(): Record<KeeperKey, string | undefined> {
  const envFile = resolve(PACKAGE_DIR, "../contracts/.env");
  const fromFile = existsSync(envFile) ? parseEnv(readFileSync(envFile, "utf8")) : {};
  const out = {} as Record<KeeperKey, string | undefined>;
  for (const key of KEEPER_KEYS) {
    const value = process.env[key] ?? fromFile[key];
    out[key] = value === undefined || value.trim() === "" ? undefined : value.trim();
  }
  return out;
}

function parseHttpUrl(key: KeeperKey, raw: string | undefined, fallback: string): string {
  const value = raw ?? fallback;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new ConfigError(`${key} is not a URL: ${JSON.stringify(value)}`);
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new ConfigError(`${key} must be http or https, got ${url.protocol}`);
  }
  return url.toString();
}

function parsePrivateKey(raw: string | undefined, dry: boolean): Hex | undefined {
  if (raw === undefined) {
    if (dry) return undefined;
    throw new ConfigError(
      "KEEPER_PRIVATE_KEY is missing. Set it in the environment or in packages/contracts/.env, or run npm run keeper:dry.",
    );
  }
  if (!isHex(raw, { strict: true }) || raw.length !== 66) {
    throw new ConfigError("KEEPER_PRIVATE_KEY must be 0x followed by 64 hex characters");
  }
  return raw;
}

function parseMaxActions(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_MAX_ACTIONS;
  if (!/^\d+$/.test(raw)) throw new ConfigError(`MAX_ACTIONS must be a whole number, got ${JSON.stringify(raw)}`);
  const n = Number(raw);
  if (n < 1 || n > MAX_ACTIONS_CEILING) {
    throw new ConfigError(`MAX_ACTIONS must be between 1 and ${MAX_ACTIONS_CEILING}, got ${n}`);
  }
  return n;
}

function parseHarvestMaxPositions(raw: string | undefined): number {
  if (raw === undefined) return DEFAULT_HARVEST_MAX_POSITIONS;
  if (!/^\d+$/.test(raw)) {
    throw new ConfigError(`HARVEST_MAX_POSITIONS must be a whole number, got ${JSON.stringify(raw)}`);
  }
  const n = Number(raw);
  if (n > HARVEST_MAX_POSITIONS_CEILING) {
    throw new ConfigError(`HARVEST_MAX_POSITIONS must be between 0 and ${HARVEST_MAX_POSITIONS_CEILING}, got ${n}`);
  }
  return n;
}

function parseHarvestMinMusd(raw: string | undefined): bigint {
  const value = raw ?? DEFAULT_HARVEST_MIN_MUSD;
  if (!/^\d{1,12}(\.\d{1,18})?$/.test(value)) {
    throw new ConfigError(`HARVEST_MIN_MUSD must be an MUSD amount such as 0.01, got ${JSON.stringify(value)}`);
  }
  return parseEther(value);
}

function resolvePath(file: string): string {
  return isAbsolute(file) ? file : resolve(PACKAGE_DIR, file);
}

// The 20 October record, plus the Wave 2 record once its deploy has written it.
function parseDeploymentFiles(raw: string | undefined, legacy: string | undefined): string[] {
  // A setting that silently stopped being read would point the keeper at a pair nobody chose.
  if (legacy !== undefined) {
    throw new ConfigError("DEPLOYMENT_FILE is now DEPLOYMENT_FILES, a comma-separated list of records; rename it");
  }
  const files =
    raw === undefined
      ? [OLD_PAIR_FILE, ...(existsSync(resolvePath(WAVE2_PAIR_FILE)) ? [WAVE2_PAIR_FILE] : [])]
      : raw.split(",").map((f) => f.trim());
  if (files.some((f) => f === "")) throw new ConfigError("DEPLOYMENT_FILES has an empty entry");
  if (files.length > MAX_DEPLOYMENT_FILES) {
    throw new ConfigError(`DEPLOYMENT_FILES names ${files.length} records; at most ${MAX_DEPLOYMENT_FILES}`);
  }
  const paths = files.map(resolvePath);
  if (new Set(paths).size !== paths.length) throw new ConfigError("DEPLOYMENT_FILES names the same record twice");
  return paths;
}

// Read from the process environment only, never from the .env file: it is a test hook that points the C35 vault
// check at another contract, and a forgotten line in a file must not quietly change what the check looks at.
function parseVaultCheckOverride(): Address | undefined {
  const raw = process.env.VAULT_CHECK_OVERRIDE?.trim();
  if (raw === undefined || raw === "") return undefined;
  if (!isAddress(raw, { strict: false })) throw new ConfigError(`VAULT_CHECK_OVERRIDE is not an address`);
  return getAddress(raw);
}

export function loadConfig(dry: boolean): Config {
  const env = readEnv();
  return {
    dry,
    rpcUrl: parseHttpUrl("MEZO_TESTNET_RPC", env.MEZO_TESTNET_RPC, DEFAULT_RPC),
    explorerApi: parseHttpUrl("MEZO_TESTNET_EXPLORER_API", env.MEZO_TESTNET_EXPLORER_API, DEFAULT_EXPLORER_API),
    privateKey: parsePrivateKey(env.KEEPER_PRIVATE_KEY, dry),
    deploymentFiles: parseDeploymentFiles(env.DEPLOYMENT_FILES, env.DEPLOYMENT_FILE),
    maxActions: parseMaxActions(env.MAX_ACTIONS),
    harvestMaxPositions: parseHarvestMaxPositions(env.HARVEST_MAX_POSITIONS),
    harvestMinMusd: parseHarvestMinMusd(env.HARVEST_MIN_MUSD),
    vaultCheckOverride: parseVaultCheckOverride(),
  };
}

function requireAddress(json: Record<string, unknown>, field: string): Address {
  const value = json[field];
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new ConfigError(`deployment record field ${field} is not an address`);
  }
  return getAddress(value);
}

// Absent or the zero address means the pair has no such contract. Anything else that is not an address stops the
// run rather than being read as absent.
function optionalAddress(json: Record<string, unknown>, field: string): Address | undefined {
  if (json[field] === undefined) return undefined;
  const value = requireAddress(json, field);
  return value === zeroAddress ? undefined : value;
}

// Every record the keeper acts on, each pair keyed by chain id and its own contract addresses. Two records that
// share any Doji contract would let one pair's objects be read as the other's (C49), so that stops the run.
export function loadDeployments(paths: string[]): DeploymentRecord[] {
  const records = paths.map(loadDeployment);
  const owner = new Map<string, string>();
  const names = new Set<string>();
  for (const record of records) {
    if (names.has(record.name)) throw new ConfigError(`two deployment records are both named ${record.name}`);
    names.add(record.name);
    for (const address of [record.loanManager, record.creditMarkets, record.payDown, record.unitMarket]) {
      if (address === undefined) continue;
      const key = `${record.chainId}:${address}`;
      const seen = owner.get(key);
      if (seen !== undefined) throw new ConfigError(`${record.name} and ${seen} both name contract ${address}`);
      owner.set(key, record.name);
    }
  }
  return records;
}

// Reads one deployment record a deploy script writes. Only a broadcast record for Mezo testnet is accepted: a dry
// run record names addresses that hold no code.
function loadDeployment(path: string): DeploymentRecord {
  if (!existsSync(path)) throw new ConfigError(`deployment record not found: ${path}`);
  let json: unknown;
  try {
    json = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new ConfigError(`deployment record is not valid JSON: ${path}: ${(err as Error).message}`);
  }
  if (typeof json !== "object" || json === null || Array.isArray(json)) {
    throw new ConfigError(`deployment record is not a JSON object: ${path}`);
  }
  const record = json as Record<string, unknown>;
  if (record.broadcast !== true) throw new ConfigError(`${path} is not a broadcast record`);
  if (record.chainId !== MEZO_TESTNET_CHAIN_ID) {
    throw new ConfigError(`${path} is for chain ${String(record.chainId)}, expected ${MEZO_TESTNET_CHAIN_ID}`);
  }
  const block = record.block;
  if (typeof block !== "number" || !Number.isSafeInteger(block) || block <= 0) {
    throw new ConfigError(`deployment record field block is not a positive block number`);
  }
  return {
    file: path,
    name: basename(path, ".json"),
    chainId: MEZO_TESTNET_CHAIN_ID,
    block: BigInt(block),
    loanManager: requireAddress(record, "loanManager"),
    creditMarkets: requireAddress(record, "creditMarkets"),
    veBTC: requireAddress(record, "veBTC"),
    payDown: optionalAddress(record, "payDown"),
    unitMarket: optionalAddress(record, "unitMarket"),
    savingsVault: optionalAddress(record, "savingsVault"),
  };
}

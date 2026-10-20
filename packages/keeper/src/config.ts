import { existsSync, readFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";
import { getAddress, isAddress, isHex, type Address, type Hex } from "viem";

export const PACKAGE_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const DEFAULT_RPC = "https://rpc.test.mezo.org";
const DEFAULT_EXPLORER_API = "https://api.explorer.test.mezo.org/api";
const DEFAULT_DEPLOYMENT_FILE = "../contracts/deployments/31611.json";
const DEFAULT_MAX_ACTIONS = 10;
// A pass sends its writes one at a time and waits for each receipt, so even this ceiling finishes in minutes.
const MAX_ACTIONS_CEILING = 50;
export const MEZO_TESTNET_CHAIN_ID = 31_611;

// The keys the keeper reads. Nothing else from any env file reaches the process.
const KEEPER_KEYS = [
  "MEZO_TESTNET_RPC",
  "MEZO_TESTNET_EXPLORER_API",
  "KEEPER_PRIVATE_KEY",
  "DEPLOYMENT_FILE",
  "MAX_ACTIONS",
] as const;
type KeeperKey = (typeof KEEPER_KEYS)[number];

export interface Config {
  dry: boolean;
  rpcUrl: string;
  explorerApi: string;
  privateKey: Hex | undefined;
  deploymentFile: string;
  maxActions: number;
}

export interface DeploymentRecord {
  chainId: number;
  block: bigint;
  loanManager: Address;
  creditMarkets: Address;
  veBTC: Address;
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

export function loadConfig(dry: boolean): Config {
  const env = readEnv();
  const file = env.DEPLOYMENT_FILE ?? DEFAULT_DEPLOYMENT_FILE;
  return {
    dry,
    rpcUrl: parseHttpUrl("MEZO_TESTNET_RPC", env.MEZO_TESTNET_RPC, DEFAULT_RPC),
    explorerApi: parseHttpUrl("MEZO_TESTNET_EXPLORER_API", env.MEZO_TESTNET_EXPLORER_API, DEFAULT_EXPLORER_API),
    privateKey: parsePrivateKey(env.KEEPER_PRIVATE_KEY, dry),
    deploymentFile: isAbsolute(file) ? file : resolve(PACKAGE_DIR, file),
    maxActions: parseMaxActions(env.MAX_ACTIONS),
  };
}

function requireAddress(json: Record<string, unknown>, field: string): Address {
  const value = json[field];
  if (typeof value !== "string" || !isAddress(value, { strict: false })) {
    throw new ConfigError(`deployment record field ${field} is not an address`);
  }
  return getAddress(value);
}

// Reads the deployment record DeployCore writes. Only a broadcast record for Mezo testnet is accepted: a dry
// run record names addresses that hold no code.
export function loadDeployment(path: string): DeploymentRecord {
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
    chainId: MEZO_TESTNET_CHAIN_ID,
    block: BigInt(block),
    loanManager: requireAddress(record, "loanManager"),
    creditMarkets: requireAddress(record, "creditMarkets"),
    veBTC: requireAddress(record, "veBTC"),
  };
}

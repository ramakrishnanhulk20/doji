import { formatUnits, parseUnits } from "viem";
import { formatMusd } from "../../lib/stats";

const WEI = 10n ** 18n;

/** "1,234.56" from a MUSD amount in wei. */
export const fmtMusd = (wei: bigint): string => formatMusd(Number(formatUnits(wei, 18)));

/** A BTC amount in wei with a fixed number of decimals, rounded down. */
export function fmtBtc(wei: bigint, decimals: number): string {
  const scale = 10n ** BigInt(18 - decimals);
  const rounded = wei / scale;
  const text = rounded.toString().padStart(decimals + 1, "0");
  return `${text.slice(0, text.length - decimals)}.${text.slice(text.length - decimals)}`;
}

/** An amount with all its digits and no trailing zeros, for the label on the confirm button. */
export function fmtExact(wei: bigint): string {
  return formatUnits(wei, 18);
}

/** Keeps digits and one dot, and cuts the decimals to what the field allows. */
export function sanitizeAmount(text: string, maxDecimals: number): string {
  const cleaned = text.replace(/,/g, ".").replace(/[^0-9.]/g, "");
  const [whole = "", ...rest] = cleaned.split(".");
  if (rest.length === 0) return whole;
  return `${whole}.${rest.join("").slice(0, maxDecimals)}`;
}

/** The amount typed, in wei. Zero for anything that is not a number yet. */
export function parseAmount(text: string): bigint {
  if (text === "" || text === ".") return 0n;
  try {
    return parseUnits(text.endsWith(".") ? text.slice(0, -1) : text, 18);
  } catch {
    return 0n;
  }
}

/** MUSD wei to the text of the amount field: two decimals, no grouping. */
export function musdFieldText(wei: bigint): string {
  if (wei <= 0n) return "";
  const cents = wei / 10n ** 16n;
  const text = cents.toString().padStart(3, "0");
  return `${text.slice(0, -2)}.${text.slice(-2)}`;
}

export const toNumber = (wei: bigint): number => Number(formatUnits(wei, 18));

export const mulDivWei = (a: bigint, b: bigint): bigint => (a * b) / WEI;

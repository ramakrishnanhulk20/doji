import { getAddress, type Address } from "viem";

const HEX_ADDRESS = /^0x[0-9a-fA-F]{40}$/;

/**
 * The one address parser (threat model C66). Every address from a request, a URL, the explorer, the RPC or a hand-edited
 * file comes through here before it is compared, used as a key or shown. Returns the checksummed form, or null for a
 * non-string, a wrong length, or mixed case that fails its checksum. All-lower and all-upper spellings carry no checksum
 * and are accepted, so one wallet always reaches one form.
 */
export function parseAddress(value: unknown): Address | null {
  if (typeof value !== "string" || !HEX_ADDRESS.test(value)) return null;
  const hex = value.slice(2);
  const canonical = getAddress(`0x${hex.toLowerCase()}`);
  const singleCase = hex === hex.toLowerCase() || hex === hex.toUpperCase();
  return singleCase || value === canonical ? canonical : null;
}

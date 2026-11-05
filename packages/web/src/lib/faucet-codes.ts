import type { Hash } from "viem";

/**
 * Every reason the claim route can refuse. This is the whole list: the browser turns each one into its own message, so
 * no upstream text, stack or address ever reaches a person.
 */
export const FAUCET_CODES = [
  "bad_request",
  "bot_check_failed",
  "already_claimed",
  "none_open",
  "faucet_empty",
  "paused",
  "busy",
  "unavailable",
] as const;

export type FaucetCode = (typeof FAUCET_CODES)[number];

/** `hash` is computed from the signed bytes. `nextOpenAt` is a unix second, sent only with `none_open`. */
export type ClaimReply = { ok: true; hash: Hash } | { ok: false; code: FaucetCode; nextOpenAt?: number };

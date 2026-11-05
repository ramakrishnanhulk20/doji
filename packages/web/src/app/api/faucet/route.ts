import { isIP } from "node:net";
import type { ClaimReply, FaucetCode } from "@/lib/faucet-codes";
import { MAX_BODY_BYTES, handleClaim, liveClaimDeps } from "@/server/faucet";

// handleClaim stops itself at 8 seconds, so the platform limit is never what ends a claim (C64).
export const maxDuration = 10;

const STATUS: Record<FaucetCode, number> = {
  bad_request: 400,
  bot_check_failed: 403,
  already_claimed: 409,
  none_open: 429,
  busy: 429,
  faucet_empty: 503,
  paused: 503,
  unavailable: 503,
};

/** Stops reading at the cap, and answers an empty string for anything over it, which handleClaim refuses. */
async function readBody(request: Request): Promise<string> {
  if (request.body === null) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) return Buffer.concat(chunks).toString("utf8");
      size += value.byteLength;
      if (size > MAX_BODY_BYTES) {
        await reader.cancel();
        return "";
      }
      chunks.push(value);
    }
  } catch {
    return "";
  }
}

// C61: Vercel overwrites this header, so there it cannot be forged. Anywhere else a caller could set it, so it is
// ignored, and the other forwarded-address headers are never read.
function platformIp(request: Request): string | null {
  if (!process.env.VERCEL) return null;
  const value = request.headers.get("x-vercel-forwarded-for");
  return value !== null && isIP(value) !== 0 ? value : null;
}

export async function POST(request: Request): Promise<Response> {
  const body = await readBody(request);
  const reply: ClaimReply = await handleClaim({ body, ip: platformIp(request) }, liveClaimDeps());
  return Response.json(reply, { status: reply.ok ? 200 : STATUS[reply.code] });
}

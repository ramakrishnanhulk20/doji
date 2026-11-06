"use client";

import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import { useQuery, useQueryClient, type Query } from "@tanstack/react-query";
import { decodeEventLog, formatUnits, isHash, parseAbi, type Address, type Hash, type Hex, type PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { parseAddress } from "../lib/address";
import { addressBook } from "../lib/addresses";
import { askExplorer, askRpc, type ConfirmedLog } from "../lib/confirm";
import { FAUCET_CODES, type FaucetCode } from "../lib/faucet-codes";
import { APP_CHAIN_ID } from "../lib/wagmi";

const FAUCET = addressBook[31611].faucet;
const FAUCET_ABI = parseAbi([
  "function claimed(address account) view returns (bool)",
  "function btcPerClaim() view returns (uint128)",
  "function musdPerClaim() view returns (uint128)",
  "event Claimed(address indexed to, uint256 btc, uint256 musd, uint256 indexed day)",
]);
const KIT_DECIMALS = 18;

const FAUCET_ROUTE = "/api/faucet";
const TURNSTILE_SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
const TURNSTILE_ACTION = "faucet";

const CHECK_TIMEOUT_MS = 60_000;
// The route stops itself at 8 seconds, so this only ends a call to a server that never answers.
const ROUTE_TIMEOUT_MS = 12_000;
const POLL_MS = 3_000;
const LATE_AFTER_MS = 60_000;
const LATE_POLL_MS = 10_000;

export type ClaimView =
  | { step: "idle" | "checking" | "sending" }
  | { step: "confirming" | "landed"; hash: Hash }
  /** `minutes` comes with `none_open` only. */
  | { step: "refused"; code: FaucetCode; minutes?: number };

/** Plain decimal strings, read from the faucet. */
export type KitAmounts = { btc: string; musd: string };

export type ClaimKitState = {
  view: ClaimView;
  /** True once a sent claim has gone 60 seconds with no proof it landed. */
  late: boolean;
  /** Undefined until the faucet has answered, and until a claim has landed. */
  kit: KitAmounts | undefined;
  /** The div the Turnstile widget draws in. */
  widgetHost: RefObject<HTMLDivElement | null>;
  /** Starts a claim, or a fresh one after a refusal. */
  claim: () => void;
};

type TurnstileOptions = {
  sitekey: string;
  action: string;
  theme: "light";
  appearance: "interaction-only";
  callback: (token: string) => void;
  "error-callback": () => boolean;
};

type Turnstile = {
  render: (host: HTMLElement, options: TurnstileOptions) => string | undefined;
  reset: (widgetId: string) => void;
  remove: (widgetId: string) => void;
};

declare global {
  interface Window {
    turnstile?: Turnstile;
  }
}

type TokenWaiter = { pass: (token: string) => void; fail: () => void };

const UNAVAILABLE: ClaimView = { step: "refused", code: "unavailable" };

let turnstileLoad: Promise<Turnstile> | null = null;

// Any script on this origin can ask a connected wallet to sign, so Cloudflare's only enters the page once a person
// has pressed Claim, and only ever once (C78).
function loadTurnstile(): Promise<Turnstile> {
  turnstileLoad ??= new Promise<Turnstile>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = TURNSTILE_SCRIPT;
    script.async = true;
    script.onload = () => (window.turnstile ? resolve(window.turnstile) : reject(new Error("the widget did not load")));
    script.onerror = () => {
      script.remove();
      reject(new Error("the widget did not load"));
    };
    document.head.append(script);
  }).catch((error: unknown) => {
    turnstileLoad = null;
    throw error;
  });
  return turnstileLoad;
}

/** The reply is a closed set, so anything outside it is `unavailable` (C64). A hash is checked here, before any link can use it (C78). */
function viewOfReply(reply: unknown): ClaimView {
  if (typeof reply !== "object" || reply === null) return UNAVAILABLE;
  const { ok, hash, code, nextOpenAt } = reply as Record<string, unknown>;
  if (ok === true) return typeof hash === "string" && isHash(hash) ? { step: "confirming", hash } : UNAVAILABLE;

  const known = FAUCET_CODES.find((candidate) => candidate === code);
  if (ok !== false || known === undefined) return UNAVAILABLE;
  if (known !== "none_open") return { step: "refused", code: known };
  if (typeof nextOpenAt !== "number" || !Number.isFinite(nextOpenAt)) return UNAVAILABLE;
  return { step: "refused", code: known, minutes: Math.max(1, Math.ceil((nextOpenAt - Date.now() / 1000) / 60)) };
}

async function postClaim(wallet: Address, token: string): Promise<ClaimView> {
  try {
    const reply = await fetch(FAUCET_ROUTE, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ address: wallet, turnstileToken: token }),
      cache: "no-store",
      signal: AbortSignal.timeout(ROUTE_TIMEOUT_MS),
    });
    return viewOfReply(await reply.json());
  } catch {
    return UNAVAILABLE;
  }
}

function isClaimFor(wallet: Address, log: ConfirmedLog): boolean {
  if (parseAddress(log.address) !== parseAddress(FAUCET)) return false;
  try {
    const seen = decodeEventLog({ abi: FAUCET_ABI, topics: log.topics as [Hex, ...Hex[]], data: log.data });
    return seen.eventName === "Claimed" && parseAddress(seen.args.to) === wallet;
  } catch {
    return false;
  }
}

async function receiptNames(wallet: Address, hash: Hash): Promise<boolean> {
  const verdict = await Promise.any([askRpc(hash), askExplorer(hash)]);
  return verdict.status === "success" && verdict.logs.some((log) => isClaimFor(wallet, log));
}

// The route's hash only says a transaction was signed, so it proves nothing here (C64). The two proofs back each other
// up because Mezo's nodes disagree: one can return no receipt for a mined transaction while another still has the old
// `claimed`.
async function kitLanded(client: PublicClient, wallet: Address, hash: Hash): Promise<boolean> {
  const [claimed, named] = await Promise.allSettled([
    client.readContract({ address: FAUCET, abi: FAUCET_ABI, functionName: "claimed", args: [wallet] }),
    receiptNames(wallet, hash),
  ]);
  return (claimed.status === "fulfilled" && claimed.value) || (named.status === "fulfilled" && named.value);
}

const isBalanceQuery = (query: Query) => query.queryKey[0] === "balance";

/**
 * One claim for one wallet, from the press to proof on the chain. The caller keys this on the wallet, so nothing from
 * one wallet's claim can reach another's (C76).
 *
 * @param wallet The connected wallet, parsed. Never a value from a URL.
 * @param open Whether the slip is showing. Polling past 60 seconds stops while it is closed.
 */
export function useClaimKit(wallet: Address, open: boolean): ClaimKitState {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const queryClient = useQueryClient();
  const [view, setView] = useState<ClaimView>({ step: "idle" });
  const [late, setLate] = useState(false);

  const widgetHost = useRef<HTMLDivElement>(null);
  const widget = useRef<string | null>(null);
  const waiter = useRef<TokenWaiter | null>(null);
  // Each press takes a number. A result for any number but the latest belongs to a claim nobody is waiting on.
  const latestRun = useRef(0);

  const dropWidget = useCallback(() => {
    if (widget.current !== null) window.turnstile?.remove(widget.current);
    widget.current = null;
  }, []);

  const askForToken = useCallback(
    () =>
      new Promise<string>((resolve, reject) => {
        const settle = (finish: () => void) => {
          window.clearTimeout(timer);
          if (waiter.current === own) waiter.current = null;
          finish();
        };
        const own: TokenWaiter = {
          pass: (token) => settle(() => resolve(token)),
          fail: () => settle(() => reject(new Error("the check did not finish"))),
        };
        const timer = window.setTimeout(own.fail, CHECK_TIMEOUT_MS);
        waiter.current = own;

        const sitekey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY;
        if (!sitekey) {
          own.fail();
          return;
        }
        loadTurnstile()
          .then((turnstile) => {
            // The script can arrive after this attempt has already given up.
            if (waiter.current !== own) return;
            // A token works once, so every attempt after the first needs the widget to solve again.
            if (widget.current !== null) {
              turnstile.reset(widget.current);
              return;
            }
            const host = widgetHost.current;
            widget.current = host
              ? (turnstile.render(host, {
                  sitekey,
                  action: TURNSTILE_ACTION,
                  theme: "light",
                  appearance: "interaction-only",
                  callback: (token) => waiter.current?.pass(token),
                  "error-callback": () => {
                    waiter.current?.fail();
                    return true;
                  },
                }) ?? null)
              : null;
            if (widget.current === null) own.fail();
          })
          .catch(own.fail);
      }),
    [],
  );

  const claim = useCallback(() => {
    latestRun.current += 1;
    const run = latestRun.current;
    setLate(false);
    setView({ step: "checking" });

    void (async () => {
      let token: string;
      try {
        token = await askForToken();
      } catch {
        if (run !== latestRun.current) return;
        dropWidget();
        setView(UNAVAILABLE);
        return;
      }
      if (run !== latestRun.current) return;
      setView({ step: "sending" });
      const next = await postClaim(wallet, token);
      if (run !== latestRun.current) return;
      if (next.step === "confirming") dropWidget();
      setView(next);
    })();
  }, [askForToken, dropWidget, wallet]);

  useEffect(
    () => () => {
      latestRun.current += 1;
      waiter.current?.fail();
      dropWidget();
    },
    [dropWidget],
  );

  const sent = view.step === "confirming" ? view.hash : null;

  useEffect(() => {
    if (sent === null) return;
    const timer = window.setTimeout(() => setLate(true), LATE_AFTER_MS);
    return () => window.clearTimeout(timer);
  }, [sent]);

  const polling = sent !== null && client !== undefined && (!late || open);

  useEffect(() => {
    if (!polling || sent === null || client === undefined) return;
    let stopped = false;
    let timer = 0;

    const round = async () => {
      const landed = await kitLanded(client, wallet, sent);
      if (stopped) return;
      if (!landed) {
        timer = window.setTimeout(() => void round(), late ? LATE_POLL_MS : POLL_MS);
        return;
      }
      setView({ step: "landed", hash: sent });
      void queryClient.invalidateQueries({ queryKey: ["quests", wallet] });
      void queryClient.invalidateQueries({ predicate: isBalanceQuery });
    };
    void round();

    return () => {
      stopped = true;
      window.clearTimeout(timer);
    };
  }, [polling, sent, late, client, wallet, queryClient]);

  const kit = useQuery({
    queryKey: ["faucet", "kit"],
    enabled: view.step === "landed" && client !== undefined,
    retry: 3,
    queryFn: async (): Promise<KitAmounts> => {
      const [btc, musd] = await Promise.all(
        (["btcPerClaim", "musdPerClaim"] as const).map((functionName) =>
          (client as PublicClient).readContract({ address: FAUCET, abi: FAUCET_ABI, functionName }),
        ),
      );
      if (btc === undefined || musd === undefined) throw new Error("the faucet did not answer");
      return { btc: formatUnits(btc, KIT_DECIMALS), musd: formatUnits(musd, KIT_DECIMALS) };
    },
  });

  return { view, late, kit: kit.data, widgetHost, claim };
}

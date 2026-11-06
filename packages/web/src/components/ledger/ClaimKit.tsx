"use client";

import { useContext, useEffect, useRef } from "react";
import type { Address } from "viem";
import { WagmiContext, useAccount } from "wagmi";
import { useClaimKit, type ClaimView } from "../../hooks/useClaimKit";
import { parseAddress } from "../../lib/address";
import type { FaucetCode } from "../../lib/faucet-codes";
import { openConnectModal } from "../app/connect-modal-store";
import { Button } from "../Button";
import { Seal } from "../Seal";
import { explorerTx } from "./chapters";
import "./ledger.css";

type ClaimKitProps = {
  /** Whether the slip around it is showing. */
  open: boolean;
};

const CLAIM_LABEL = "Claim";
const WORKING: Partial<Record<ClaimView["step"], string>> = {
  checking: "Checking you are a person.",
  sending: "Sending your kit.",
  confirming: "Waiting for Mezo to confirm.",
};
const LATE_LINE = "This is taking longer than usual. Your kit may still arrive, so check back in a minute.";
const NOT_ANSWERING = "The faucet is not answering right now. Try again soon.";

const REFUSALS: Record<Exclude<FaucetCode, "none_open">, string> = {
  already_claimed: "This wallet already claimed its kit.",
  faucet_empty: "The faucet is being refilled. Try again soon.",
  paused: "The faucet is paused for a moment. Try again soon.",
  busy: "Lots of claims at once. Try again in a few seconds.",
  bot_check_failed: "The check did not pass. Try again.",
  unavailable: NOT_ANSWERING,
  bad_request: NOT_ANSWERING,
};

function refusalLine(code: FaucetCode, minutes: number | undefined): string {
  if (code !== "none_open") return REFUSALS[code];
  return `The next kit opens in about ${minutes} ${minutes === 1 ? "minute" : "minutes"}.`;
}

function ClaimFlow({ wallet, open }: { wallet: Address; open: boolean }) {
  const { view, late, kit, widgetHost, claim } = useClaimKit(wallet, open);
  const rootRef = useRef<HTMLDivElement>(null);
  const working = WORKING[view.step];

  // The button that was pressed leaves the page, which would drop focus outside the slip's trap.
  useEffect(() => {
    if (!open || document.activeElement !== document.body) return;
    rootRef.current?.closest('[role="dialog"]')?.querySelector<HTMLElement>("button")?.focus({ preventScroll: true });
  }, [open, view.step]);

  return (
    <div ref={rootRef} className="ledger-claim">
      <div ref={widgetHost} className="ledger-claim-widget" />

      {view.step === "idle" && (
        <>
          <Button variant="primary" className="ledger-slip-button" onClick={claim}>
            {CLAIM_LABEL}
          </Button>
          <p className="ledger-claim-help">Free. Doji pays the fee.</p>
        </>
      )}

      <div role="status" className="ledger-claim-status">
        {working !== undefined && (
          <p className="ledger-claim-working">
            <Seal size={18} title="" busy />
            <span>{late ? LATE_LINE : working}</span>
          </p>
        )}

        {view.step === "landed" && (
          <>
            <p className="ledger-claim-line">Your kit has landed.</p>
            {kit !== undefined && (
              <p className="ledger-claim-line">
                {kit.btc} test BTC and {kit.musd} test MUSD are in your wallet.
              </p>
            )}
            <a className="link-draw" href={explorerTx(view.hash)} target="_blank" rel="noopener noreferrer">
              See the transaction
            </a>
          </>
        )}

        {view.step === "refused" && <p className="ledger-claim-line">{refusalLine(view.code, view.minutes)}</p>}
      </div>

      {(late || (view.step === "refused" && view.code !== "already_claimed")) && (
        <Button variant="secondary" className="ledger-claim-again" onClick={claim}>
          Try again
        </Button>
      )}
    </div>
  );
}

function ConnectedClaim({ open }: ClaimKitProps) {
  const { address } = useAccount();
  const wallet = parseAddress(address);

  if (wallet === null) {
    return (
      <Button variant="primary" className="ledger-slip-button" onClick={openConnectModal}>
        Connect wallet
      </Button>
    );
  }
  // Keyed so a wallet change drops the whole claim: the recipient is only ever the wallet connected now (C76).
  return <ClaimFlow key={wallet} wallet={wallet} open={open} />;
}

/** The claim step for the starter kit quest, for the connected wallet alone. It stays quiet until a person presses Claim. */
export function ClaimKit({ open }: ClaimKitProps) {
  // The lab page draws this slip with no wallet layer loaded, and asking for the account there would throw.
  if (useContext(WagmiContext) === undefined) {
    return (
      <Button variant="primary" className="ledger-slip-button">
        {CLAIM_LABEL}
      </Button>
    );
  }
  return <ConnectedClaim open={open} />;
}

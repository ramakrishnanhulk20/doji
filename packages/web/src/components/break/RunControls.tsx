"use client";

import { STRANGER } from "../../lib/attacks";
import { Button } from "../Button";
import { openConnectModal } from "../app/connect-modal-store";

export type RunMode = "stranger" | "wallet";

type RunControlsProps = {
  mode: RunMode;
  /** The connected wallet's address, or undefined when no wallet is connected. */
  wallet: string | undefined;
  /** True while a simulation is running, so the switch and Run all hold still. */
  busy: boolean;
  /** Set while Run all is working through the cards. */
  progress: { index: number; total: number } | null;
  ready: boolean;
  onMode: (mode: RunMode) => void;
  onRunAll: () => void;
};

export function RunControls({ mode, wallet, busy, progress, ready, onMode, onRunAll }: RunControlsProps) {
  const walletOff = wallet === undefined;

  return (
    <section className="break-controls" aria-label="Who runs the attacks">
      <div className="break-controls-row">
        <div className="break-switch" role="group" aria-label="Run the attacks as">
          <button
            type="button"
            className="break-switch-tab"
            aria-pressed={mode === "stranger"}
            disabled={busy}
            onClick={() => onMode("stranger")}
          >
            Run as a stranger
          </button>
          <button
            type="button"
            className="break-switch-tab"
            aria-pressed={mode === "wallet"}
            aria-disabled={walletOff || undefined}
            aria-describedby="break-account-note"
            disabled={busy}
            onClick={() => {
              if (!walletOff) onMode("wallet");
            }}
          >
            Run from my wallet
          </button>
        </div>

        <div className="break-runall">
          <Button className="break-runall-button" disabled={!ready} loading={progress !== null} onClick={onRunAll}>
            Run all
          </Button>
          <span className="break-progress" role="status">
            {progress ? `Running ${progress.index + 1} of ${progress.total}` : ""}
          </span>
        </div>
      </div>

      <p className="break-account" id="break-account-note">
        {mode === "wallet" && wallet ? (
          <>
            Simulating from <span className="break-account-address">{wallet}</span>, your wallet. Your wallet is never
            asked to sign.
          </>
        ) : (
          <>
            Simulating from <span className="break-account-address">{STRANGER}</span>, an address with no rights in
            Doji.
            {walletOff && (
              <>
                {" "}
                <button type="button" className="break-text-button" onClick={openConnectModal}>
                  Connect a wallet
                </button>{" "}
                to run these from your own address.
              </>
            )}
          </>
        )}
      </p>
    </section>
  );
}

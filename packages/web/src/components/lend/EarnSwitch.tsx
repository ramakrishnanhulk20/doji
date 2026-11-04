"use client";

import { motion } from "motion/react";
import type { Address } from "viem";

export type EarnSwitchState = "loading" | "paused" | "vaultDown" | "error" | "ready";

export type EarnSwitchProps = {
  /** The lender's choice. It only counts when `state` is "ready". */
  choice: boolean;
  onChange: (on: boolean) => void;
  state: EarnSwitchState;
  vault: Address;
  reduced: boolean;
};

const EXPLORER_ADDRESS = "https://explorer.test.mezo.org/address/";

const OFF_LINE: Record<Exclude<EarnSwitchState, "ready">, string> = {
  loading: "Checking the sMUSD vault.",
  paused: "Doji's guardian has paused earning in sMUSD. New offers wait in the contract, as before.",
  vaultDown:
    "Mezo's sMUSD vault is not paying out right now, so new offers wait in the contract. Offers already earning stay in the vault.",
  error: "The sMUSD vault could not be read. New offers wait in the contract for now.",
};

const shortAddress = (address: Address): string => `${address.slice(0, 6)}...${address.slice(-4)}`;

export function EarnSwitch({ choice, onChange, state, vault, reduced }: EarnSwitchProps) {
  const ready = state === "ready";
  const on = state === "loading" ? true : ready ? choice : false;
  const line = ready
    ? on
      ? "Your MUSD sits in Mezo's sMUSD savings vault and earns its rate until a borrower takes it. The borrower still receives plain MUSD."
      : "Your MUSD sits in the Doji contract until a borrower takes it. It earns nothing while it waits."
    : OFF_LINE[state];

  // A link may not sit inside a button, so the vault line is the button's sibling, laid over the space the button
  // leaves for it.
  return (
    <div className="earn-switch-card">
      <button
        type="button"
        role="switch"
        aria-checked={on}
        className="earn-switch"
        data-on={on}
        data-loading={state === "loading"}
        data-reduced={reduced}
        disabled={!ready}
        onClick={() => onChange(!choice)}
      >
        <span className="earn-switch-text">
          <span className="earn-switch-title">Earn in sMUSD while it waits</span>
          <span className="earn-switch-line">{line}</span>
        </span>
        <span className="earn-switch-track" aria-hidden="true">
          <span className="earn-switch-knob" />
        </span>
      </button>
      {on && (
        <motion.p
          className="earn-switch-vault"
          initial={reduced ? false : { opacity: 0, y: 4 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.2, ease: [0.22, 1, 0.36, 1] }}
        >
          sMUSD vault{" "}
          <a className="link-draw" href={`${EXPLORER_ADDRESS}${vault}`} target="_blank" rel="noreferrer">
            {shortAddress(vault)}
          </a>
        </motion.p>
      )}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useLoanGate } from "../../hooks/useLoanGate";
import { anyoneCallFor, anyoneSuccessLine, type AnyoneAction } from "../../lib/loans";
import { Button } from "../Button";
import type { SendCall } from "./RepaySheet";

type AnyoneActionsProps = {
  actions: readonly AnyoneAction[];
  tokenId: bigint;
  send: SendCall;
  busy: boolean;
};

/** The steps any wallet may run on a loan. The write hook simulates each one first and explains a refusal. */
export function AnyoneActions({ actions, tokenId, send, busy }: AnyoneActionsProps) {
  const gate = useLoanGate();
  const [acting, setActing] = useState<string | null>(null);

  if (actions.length === 0) return null;

  const run = async (action: AnyoneAction) => {
    setActing(action.id);
    try {
      await send(anyoneCallFor(action.id, tokenId), anyoneSuccessLine(action.id, tokenId));
    } finally {
      setActing(null);
    }
  };

  return (
    <section className="anyone" aria-label="Steps anyone can run">
      {actions.map((action) => (
        <div key={action.id} className="anyone-row">
          <p className="anyone-why">{action.why}</p>
          <Button
            className="loan-btn"
            variant="secondary"
            loading={acting === action.id}
            disabled={busy}
            onClick={() => {
              if (!gate.isConnected) gate.connect();
              else if (gate.wrongChain) gate.switchNetwork();
              else void run(action);
            }}
          >
            {!gate.isConnected
              ? `Connect wallet to ${action.label.charAt(0).toLowerCase()}${action.label.slice(1)}`
              : gate.wrongChain
                ? "Switch to Mezo testnet"
                : action.label}
          </Button>
        </div>
      ))}
    </section>
  );
}

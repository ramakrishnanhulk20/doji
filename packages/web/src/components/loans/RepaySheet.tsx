"use client";

import { useEffect, useState } from "react";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanSteps, type FlowStep } from "../../hooks/useLoanSteps";
import type { SuccessLine, WriteResult } from "../../hooks/useWrite";
import { CENT } from "../../lib/borrow";
import {
  approveMusdCall,
  approveText,
  musdText,
  repayCall,
  repaySteps,
  STATE_AUCTION,
  type LoanCall,
  type MusdWallet,
  type PositionView,
} from "../../lib/loans";
import { formatDate } from "../../lib/stats";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { musdFieldText, parseAmount } from "../borrow/format";
import { AmountField } from "../borrow/Steps";
import { Sheet } from "./Sheet";

export type SendCall = (call: LoanCall, successLine: SuccessLine) => Promise<WriteResult>;

type RepaySheetProps = {
  view: PositionView;
  wallet: MusdWallet | undefined;
  /** In auction or overdue: only a full repayment helps, so the amount is fixed. */
  fullOnly: boolean;
  send: SendCall;
  busy: boolean;
  onClose: () => void;
};

const roundUpToCent = (wei: bigint): bigint => ((wei + CENT - 1n) / CENT) * CENT;

export function RepaySheet({ view, wallet, fullOnly, send, busy, onClose }: RepaySheetProps) {
  const gate = useLoanGate();
  const flow = useLoanSteps();
  const { id, owed } = view;
  const fullText = musdFieldText(roundUpToCent(owed));
  const [text, setText] = useState(fullText);

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    if (!flow.running) flow.reset();
  }, [text]);

  // Typing at or above what is owed pays exactly what is owed: the contract takes the smaller of the two.
  const typed = fullOnly ? owed : parseAmount(text);
  const pay = typed < owed ? typed : owed;
  const isFull = pay === owed;

  const reason = (() => {
    if (wallet === undefined) return "Checking your wallet";
    if (pay === 0n) return "Enter an amount";
    if (wallet.balance < pay) return `You don't have that much MUSD. Your balance is ${musdText(wallet.balance)} MUSD.`;
    return null;
  })();

  const plan = wallet !== undefined && pay > 0n ? repaySteps(pay, wallet.allowance) : [];

  const run = async () => {
    if (wallet === undefined) return;
    const steps: FlowStep[] = repaySteps(pay, wallet.allowance).map((step) => ({
      ...step,
      run: () =>
        step.id === "approve"
          ? send(approveMusdCall(pay), `Approved ${approveText(pay)} MUSD for Doji.`)
          : send(
              repayCall(id, pay),
              isFull
                ? `Repaid in full. veBTC #${id} has no loan and is ready to withdraw.`
                : `Paid ${musdText(pay)} MUSD towards veBTC #${id}.`,
            ),
    }));
    if (await flow.start(steps)) onClose();
  };

  const running = flow.running || busy;
  const confirm = (() => {
    if (!gate.isConnected) return { label: "Connect wallet to repay", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (reason) return { label: reason, disabled: true, loading: false, onClick: () => undefined };
    if (flow.confirming) return { label: "Waiting for confirmation", disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow.failedAt !== null) {
      return { label: `Try again from step ${flow.failedAt + 1}`, disabled: false, loading: false, onClick: () => void flow.retry().then((done) => done && onClose()) };
    }
    return {
      label: isFull ? `Repay in full: ${musdText(pay)} MUSD` : `Repay ${musdText(pay)} MUSD`,
      disabled: false,
      loading: false,
      onClick: () => void run(),
    };
  })();

  return (
    <Sheet title={fullOnly ? `Repay veBTC #${id} in full` : `Repay veBTC #${id}`} locked={running} onClose={onClose}>
      <p className="loan-sheet-lead">
        You owe {musdText(owed)} MUSD on {formatDate(view.loan.maturity)}.
      </p>

      {fullOnly ? (
        <div className="amount-fixed" aria-label="Amount to repay">
          <span className="amount-fixed-value">{musdText(owed)}</span>
          <span className="amount-fixed-unit">MUSD</span>
        </div>
      ) : (
        <AmountField
          id="repay-amount"
          label="MUSD to repay"
          value={text}
          unit="MUSD"
          decimals={2}
          onChange={setText}
          onMax={() => setText(fullText)}
          maxDisabled={running}
        />
      )}

      <p className="field-note field-note-plain">
        {!fullOnly
          ? "Paying in full returns your veBTC to Doji's custody with no loan, ready to withdraw."
          : view.loan.state === STATE_AUCTION
            ? "Repaying in full ends the auction and keeps your position."
            : "Repaying in full keeps your position before anyone starts its auction."}
      </p>
      {!fullOnly && pay > 0n && !isFull && (
        <p className="field-note field-note-plain">
          This leaves {musdText(owed - pay)} MUSD still owed on {formatDate(view.loan.maturity)}.
        </p>
      )}

      {plan.length > 0 && (
        <div className="summary-steps">
          <Stepper steps={flow.rows(plan)} />
        </div>
      )}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </Sheet>
  );
}

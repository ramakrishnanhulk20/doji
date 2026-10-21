"use client";

import { useMemo, useState } from "react";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanSteps, type FlowStep } from "../../hooks/useLoanSteps";
import type { PositionView } from "../../lib/loans";
import { formatDate } from "../../lib/stats";
import { buildExtendLockCall, extensionDates, loanAllowsVoting } from "../../lib/votes";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { Sheet } from "./Sheet";
import type { SendCall } from "./RepaySheet";

type ExtendLockSheetProps = {
  view: PositionView;
  now: number;
  send: SendCall;
  busy: boolean;
  onClose: () => void;
};

const WEEK = 604_800;

const weeksLonger = (date: number, lockEnd: number): string => {
  const weeks = Math.round((date - lockEnd) / WEEK);
  return `${weeks} week${weeks === 1 ? "" : "s"} longer`;
};

export function ExtendLockSheet({ view, now, send, busy, onClose }: ExtendLockSheetProps) {
  const gate = useLoanGate();
  const flow = useLoanSteps();
  const { id, lock } = view;
  const lockEnd = lock !== null && !lock.isPermanent ? lock.end : null;

  const dates = useMemo(() => (lockEnd === null ? [] : extensionDates(lockEnd, now)), [lockEnd, now]);
  const [pick, setPick] = useState<number | null>(null);
  const date = pick !== null && dates.includes(pick) ? pick : (dates[0] ?? null);

  const plan = date === null ? [] : [{ id: "extend", label: `Extend lock to ${formatDate(date)}` }];

  const run = async () => {
    if (date === null) return;
    const target = date;
    const steps: FlowStep[] = plan.map((step) => ({
      ...step,
      run: () =>
        send(
          buildExtendLockCall(id, target, Math.floor(Date.now() / 1000)),
          `The lock on veBTC #${id} now runs to ${formatDate(target)}.`,
        ),
    }));
    if (await flow.start(steps)) onClose();
  };

  const running = flow.running || busy;
  const confirm = (() => {
    if (!gate.isConnected) return { label: "Connect wallet to extend", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (!loanAllowsVoting(view)) return { label: "Only an on-time, safe loan can extend", disabled: true, loading: false, onClick: () => undefined };
    if (date === null) return { label: "Pick a later date", disabled: true, loading: false, onClick: () => undefined };
    if (flow.confirming) return { label: "Waiting for confirmation", disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow.failedAt !== null) {
      return {
        label: `Try again from step ${flow.failedAt + 1}`,
        disabled: false,
        loading: false,
        onClick: () => void flow.retry().then((done) => done && onClose()),
      };
    }
    return { label: `Extend lock to ${formatDate(date)}`, disabled: false, loading: false, onClick: () => void run() };
  })();

  return (
    <Sheet title={`Extend the lock on veBTC #${id}`} locked={running} onClose={onClose}>
      <p className="loan-sheet-lead">
        {lockEnd === null ? "This lock is permanent." : `Your lock ends ${formatDate(lockEnd)}. Pick a later Thursday.`}
      </p>

      {dates.length === 0 ? (
        <p className="field-note field-note-plain">
          No later Thursday is open: veBTC allows a lock of at most four weeks from today.
        </p>
      ) : (
        <>
          <div className="roll-dates" role="radiogroup" aria-label="New lock end">
            {dates.map((candidate) => (
              <label key={candidate} className="date-card" data-selected={date === candidate}>
                <input
                  type="radio"
                  name="extend-date"
                  className="sr-only"
                  checked={date === candidate}
                  disabled={running}
                  onChange={() => setPick(candidate)}
                />
                <span className="date-card-date display-face">{formatDate(candidate)}</span>
                <span className="date-card-available">{lockEnd === null ? "" : weeksLonger(candidate, lockEnd)}</span>
              </label>
            ))}
          </div>

          {date !== null && (
            <p className="field-note field-note-plain">
              Your BTC stays locked until {formatDate(date)}. Votes close one week before that.
            </p>
          )}

          <div className="summary-steps">
            <Stepper steps={flow.rows(plan)} />
          </div>
        </>
      )}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </Sheet>
  );
}

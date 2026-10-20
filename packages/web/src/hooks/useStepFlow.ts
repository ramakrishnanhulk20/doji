"use client";

import { useCallback, useState } from "react";
import type { StepperStep } from "../components/app/Stepper";
import { usePendingConfirmation } from "./pending";
import { recheckConfirmation, waitForSettlement, type WriteResult } from "./useWrite";

const EXPLORER_TX = "https://explorer.test.mezo.org/tx/";

export type FlowStep = { id: string; label: string; run: () => Promise<WriteResult> };

type Flow<S extends FlowStep> = {
  steps: S[];
  /** Steps finished so far. */
  done: number;
  running: boolean;
  failedAt: number | null;
};

export type FlowOutcome = { ok: boolean; last: WriteResult | null };

/**
 * Runs the steps of one action in order. A step that fails stops the run and remembers where, so the button can offer
 * "Try again from step n". That happens only for a refusal, a cancel in the wallet or a revert: a step whose
 * transaction was sent but not yet confirmed keeps the run waiting, and when Mezo confirms it the run goes on to the
 * next step by itself.
 */
export function useStepFlow<S extends FlowStep>() {
  const [flow, setFlow] = useState<Flow<S> | null>(null);
  const pending = usePendingConfirmation();

  const start = useCallback(async (steps: S[], from = 0): Promise<FlowOutcome> => {
    setFlow({ steps, done: from, running: true, failedAt: null });
    let last: WriteResult | null = null;

    for (let index = from; index < steps.length; index++) {
      let result = await (steps[index] as S).run();
      while (!result.ok && result.confirming && result.hash) {
        result = await waitForSettlement(result.hash);
      }
      last = result;
      if (!result.ok) {
        setFlow({ steps, done: index, running: false, failedAt: index });
        return { ok: false, last };
      }
      setFlow({ steps, done: index + 1, running: index + 1 < steps.length, failedAt: null });
    }
    return { ok: true, last };
  }, []);

  const reset = useCallback(() => setFlow(null), []);

  const confirming = flow?.running === true && pending !== null;

  /** The stepper rows: the live run if there is one, otherwise the plan for the current inputs. */
  const rows = (planned: readonly { id: string; label: string }[]): StepperStep[] =>
    (flow ? flow.steps : planned).map((step, index): StepperStep => {
      const base = { id: step.id, label: step.label };
      if (flow && index < flow.done) return { ...base, state: "done" };
      if (flow && flow.failedAt === index) return { ...base, state: "failed" };
      if (flow && flow.running && index === flow.done) {
        if (pending === null) return { ...base, state: "current" };
        return {
          ...base,
          state: "confirming",
          note: pending.stalled ? "Sent, still confirming" : "Waiting for Mezo to confirm",
          href: `${EXPLORER_TX}${pending.hash}`,
          action: pending.stalled ? { label: "Check again", run: recheckConfirmation } : undefined,
        };
      }
      return { ...base, state: "pending" };
    });

  return {
    start,
    reset,
    rows,
    steps: flow?.steps ?? null,
    running: flow?.running === true,
    confirming,
    failedAt: flow?.failedAt ?? null,
  };
}

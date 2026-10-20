"use client";

import { useCallback, useState } from "react";
import type { StepperStep } from "../components/app/Stepper";
import type { StepSpec } from "../lib/loans";
import type { WriteResult } from "./useWrite";

export type FlowStep = StepSpec & { run: () => Promise<WriteResult> };

type Flow = {
  steps: FlowStep[];
  /** Steps finished so far. */
  done: number;
  running: boolean;
  failedAt: number | null;
};

/**
 * Runs the steps of one action in order. A failed step stops the run and remembers where, so the button can offer
 * "Try again from step n". The steps carry the numbers they were planned with, so a retry repeats nothing stale.
 */
export function useLoanSteps() {
  const [flow, setFlow] = useState<Flow | null>(null);

  const start = useCallback(async (steps: FlowStep[], from = 0): Promise<boolean> => {
    setFlow({ steps, done: from, running: true, failedAt: null });
    for (let index = from; index < steps.length; index++) {
      const result = await (steps[index] as FlowStep).run();
      if (!result.ok) {
        setFlow({ steps, done: index, running: false, failedAt: index });
        return false;
      }
      setFlow({ steps, done: index + 1, running: index + 1 < steps.length, failedAt: null });
    }
    return true;
  }, []);

  const reset = useCallback(() => setFlow(null), []);

  /** The stepper rows: the live run if there is one, otherwise the plan for the current inputs. */
  const rows = (planned: readonly StepSpec[]): StepperStep[] =>
    (flow ? flow.steps : planned).map((step, index) => ({
      id: step.id,
      label: step.label,
      state:
        flow && index < flow.done
          ? "done"
          : flow && flow.failedAt === index
            ? "failed"
            : flow && flow.running && index === flow.done
              ? "current"
              : "pending",
    }));

  return {
    start,
    reset,
    rows,
    running: flow?.running === true,
    failedAt: flow?.failedAt ?? null,
    retry: () => (flow && flow.failedAt !== null ? start(flow.steps, flow.failedAt) : Promise.resolve(false)),
  };
}

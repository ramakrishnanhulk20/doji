"use client";

import { useStepFlow, type FlowStep } from "./useStepFlow";

export type { FlowStep };

/**
 * The step runner the loan screens use. It is the shared runner with a boolean result: true when every step went
 * through. A retry repeats the steps with the numbers they were planned with, so it repeats nothing stale.
 */
export function useLoanSteps() {
  const flow = useStepFlow<FlowStep>();

  return {
    start: async (steps: FlowStep[], from = 0): Promise<boolean> => (await flow.start(steps, from)).ok,
    reset: flow.reset,
    rows: flow.rows,
    running: flow.running,
    confirming: flow.confirming,
    failedAt: flow.failedAt,
    retry: async (): Promise<boolean> =>
      flow.failedAt !== null && flow.steps !== null ? (await flow.start(flow.steps, flow.failedAt)).ok : false,
  };
}

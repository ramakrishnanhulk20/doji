import type { ReactNode } from "react";
import { Seal } from "../Seal";

export type StepState = "pending" | "current" | "confirming" | "done" | "failed";

export type StepperStep = {
  id: string;
  label: string;
  state: StepState;
  /** A line under the label, used while a sent transaction waits for Mezo to confirm it. */
  note?: ReactNode;
  /** Explorer link for the transaction behind the step. */
  href?: string;
  action?: { label: string; run: () => void };
};

const SR_STATE: Record<StepState, string> = {
  pending: "",
  current: ", in progress",
  confirming: ", sent, waiting for Mezo to confirm",
  done: ", done",
  failed: ", failed",
};

/** The steps of a multi-step action. Done steps get a check, the current and the confirming one the busy seal. */
export function Stepper({ steps }: { steps: readonly StepperStep[] }) {
  return (
    <ol className="stepper" aria-label="Steps">
      {steps.map((step, index) => (
        <li key={step.id} className="stepper-step" data-state={step.state}>
          <span className="stepper-mark" aria-hidden="true">
            {step.state === "done" ? (
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path d="M2.5 6.5 5 9l4.5-5.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            ) : step.state === "current" || step.state === "confirming" ? (
              <Seal size={20} title="" busy />
            ) : step.state === "failed" ? (
              "!"
            ) : (
              index + 1
            )}
          </span>
          <span className="stepper-text">
            <span className="stepper-label">{step.label}</span>
            {step.note && (
              <span className="stepper-note">
                {step.note}
                {step.href && (
                  <>
                    {" "}
                    <a className="link-draw" href={step.href} target="_blank" rel="noopener noreferrer">
                      View transaction
                    </a>
                  </>
                )}
                {step.action && (
                  <>
                    {" "}
                    <button type="button" className="stepper-action" onClick={step.action.run}>
                      {step.action.label}
                    </button>
                  </>
                )}
              </span>
            )}
          </span>
          <span className="sr-only">{SR_STATE[step.state]}</span>
        </li>
      ))}
    </ol>
  );
}

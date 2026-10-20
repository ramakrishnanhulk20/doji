import { Seal } from "../Seal";

export type StepState = "pending" | "current" | "done" | "failed";

export type StepperStep = {
  id: string;
  label: string;
  state: StepState;
};

/** The steps of a multi-step action. Done steps get a check, the current one the busy seal. */
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
            ) : step.state === "current" ? (
              <Seal size={20} title="" busy />
            ) : step.state === "failed" ? (
              "!"
            ) : (
              index + 1
            )}
          </span>
          <span className="stepper-label">{step.label}</span>
          <span className="sr-only">
            {step.state === "done" ? ", done" : step.state === "current" ? ", in progress" : step.state === "failed" ? ", failed" : ""}
          </span>
        </li>
      ))}
    </ol>
  );
}

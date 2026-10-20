import { SectionHeading } from "../landing/SectionHeading";
import { ThursdayBoard } from "./ThursdayBoard";

const STEPS = [
  {
    title: "Lenders post offers",
    body: "A lender sets an amount, a Thursday and a fixed rate. The MUSD waits in the contract until a borrower takes it, and whatever is not taken can be cancelled at any time.",
  },
  {
    title: "Borrowers lock and borrow",
    body: "A borrower hands Doji a veBTC position, or locks BTC in the same step, picks a Thursday and takes the cheapest offers. The MUSD arrives at once, and the amount owed on that date is fixed.",
  },
  {
    title: "Repay or roll",
    body: "Repay any time before the date and the position comes back. Or roll into a later Thursday in one step. The lock keeps running and the votes and rewards stay with the borrower throughout.",
  },
  {
    title: "Lenders get paid",
    body: "After the date, lenders withdraw their share of what has been collected, and the rest as the last loans close. Each lender's claim is a credit unit they can also send to someone else.",
  },
] as const;

export function HowItWorks() {
  return (
    <section id="how" className="section">
      <div className="section-inner">
        <SectionHeading
          label="How a loan works"
          title="One market for every Thursday."
          body="Every loan and every lender's claim is tied to a Thursday, 00:00 UTC. Each Thursday is its own market, so a bad loan in one week never touches another."
        />
        <ol className="steps">
          {STEPS.map((step, index) => (
            <li key={step.title}>
              <span className="step-number">{String(index + 1).padStart(2, "0")}</span>
              <h3 className="step-title display-face">{step.title}</h3>
              <p className="step-body">{step.body}</p>
            </li>
          ))}
        </ol>
        <ThursdayBoard />
      </div>
    </section>
  );
}

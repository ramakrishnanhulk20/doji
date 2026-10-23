"use client";

import { useEffect, useRef } from "react";
import { useDemoLoan } from "../../hooks/useDemoLoan";
import { demoLoan } from "../../lib/addresses";
import { cssVars } from "../../lib/css-vars";
import { formatDate, formatMusd } from "../../lib/stats";
import { ArrowOut } from "../ArrowOut";
import { EXPLORER_TX_URL } from "./copy";

const COUNT_MS = 1400;

type ReadState = "loading" | "error" | "ready";

type RowProps = {
  index: number;
  status: ReadState;
  text: string;
  value: string;
};

function Row({ index, status, text, value }: RowProps) {
  return (
    <li className="card-row" style={cssVars({ "--i": index })}>
      <span className="card-mark" aria-hidden="true" />
      {status === "loading" ? (
        <span className="card-bar shimmer" role="status">
          <span className="sr-only">Loading</span>
        </span>
      ) : (
        <>
          <span className="card-row-text">{text}</span>
          <span className={status === "error" ? "card-row-value is-unavailable" : "card-row-value"}>
            {status === "error" ? "unavailable" : value}
          </span>
          {status === "ready" && <span className="card-tag">unchanged</span>}
        </>
      )}
    </li>
  );
}

type CounterProps = {
  principal: number;
  /** True from the impact until the stamp resets. */
  running: boolean;
  /** Skips the count and shows the final amount at once. */
  instant: boolean;
};

// The count writes to the text node on each animation frame, so React never re-renders for it.
function Counter({ principal, running, instant }: CounterProps) {
  const ref = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const element = ref.current;
    if (!element) return;

    if (!running) {
      element.textContent = formatMusd(0);
      return;
    }
    if (instant) {
      element.textContent = formatMusd(principal);
      return;
    }

    let frame = 0;
    const start = performance.now();
    const step = (now: number) => {
      const progress = Math.min(1, (now - start) / COUNT_MS);
      element.textContent = formatMusd(principal * (1 - Math.pow(1 - progress, 3)));
      if (progress < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [principal, running, instant]);

  return (
    <div className="card-counter">
      <span className="card-counter-number">
        <span ref={ref} />
        <span className="card-counter-unit"> MUSD</span>
      </span>
    </div>
  );
}

type LoanCardProps = {
  struck: boolean;
  reduced: boolean;
};

export function LoanCard({ struck, reduced }: LoanCardProps) {
  const { state, principal } = useDemoLoan();
  const loan = state.data;

  const rowStatus: ReadState = loan ? "ready" : state.isError ? "error" : "loading";
  const principalStatus: ReadState = principal.data !== undefined ? "ready" : principal.isError ? "error" : "loading";

  const lockValue = loan ? (loan.isPermanent ? "permanent lock" : `until ${formatDate(loan.lockEnd)}`) : "";
  const votesText = loan ? (loan.voted ? "Votes still counting" : "Votes yours to cast") : "Votes";
  const rewardsValue = loan
    ? loan.claimableBtc > 0
      ? `${loan.claimableBtc.toFixed(6)} BTC waiting`
      : "none due yet"
    : "";

  return (
    <aside className="loan-card" aria-label={`Loan ${demoLoan.tokenId} on Mezo testnet`}>
      <p className="card-header">Loan {String(demoLoan.tokenId)} · live on Mezo testnet</p>
      {loan && !loan.active && (
        <p className="card-closed">Loan {String(demoLoan.tokenId)} has closed on chain</p>
      )}

      <ul className="card-rows">
        <Row index={0} status={rowStatus} text="Still locked" value={lockValue} />
        <Row index={1} status={rowStatus} text={votesText} value={`veBTC #${String(demoLoan.tokenId)}`} />
        <Row index={2} status={rowStatus} text="Rewards go to you" value={rewardsValue} />
      </ul>

      <hr className="card-divider" />

      <div className="card-counter-wrap">
        {principalStatus === "ready" && principal.data !== undefined ? (
          <Counter principal={principal.data} running={struck} instant={reduced} />
        ) : principalStatus === "error" ? (
          <div className="card-counter">
            <span className="card-counter-number is-unavailable">unavailable</span>
          </div>
        ) : (
          <span className="card-counter-bar shimmer" role="status">
            <span className="sr-only">Loading</span>
          </span>
        )}
        <p className="card-wallet">in the borrower&apos;s wallet</p>
      </div>

      <div className="card-footer">
        <a
          className="link-draw card-link"
          href={`${EXPLORER_TX_URL}${demoLoan.hash}`}
          target="_blank"
          rel="noopener noreferrer"
        >
          See the borrow on the explorer
          <ArrowOut />
        </a>
        <p className="card-source">Read live from LoanManager, veBTC and the fee distributor</p>
      </div>
    </aside>
  );
}

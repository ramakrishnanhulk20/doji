"use client";

import { Fragment } from "react";
import { THREAT_MODEL_URL, type Attack, type AttackOutcome } from "../../lib/attacks";
import { formatBlock } from "../../lib/stats";
import { Seal } from "../Seal";
import "../button.css";

type AttackCardProps = {
  attack: Attack;
  /** The latest result for this exact call from this exact address, or null when it has not been run. */
  outcome: AttackOutcome | null;
  running: boolean;
  /** True while any attack is running, so two simulations never overlap. */
  locked: boolean;
  onRun: () => void;
};

function Result({ attack, outcome }: { attack: Attack; outcome: AttackOutcome }) {
  if (outcome.kind === "refused") {
    return (
      <>
        <p className="break-verdict">
          <span className="break-mark break-mark-circle" aria-hidden="true" />
          <span>
            Refused: <span className="break-error-name">{outcome.errorName}</span>
          </span>
        </p>
        <p className="break-detail">{outcome.detail}</p>
        {!outcome.matches && (
          <p className="break-detail">
            Expected {attack.expected}; the contract answered {outcome.errorName} instead.
          </p>
        )}
        <p className="break-block">Simulated on block {formatBlock(outcome.block)}</p>
      </>
    );
  }
  if (outcome.kind === "through") {
    return (
      <>
        <p className="break-verdict break-verdict-watch">
          <span className="break-mark break-mark-diamond" aria-hidden="true" />
          <span>This would go through</span>
        </p>
        <p className="break-detail">{attack.goesThrough}</p>
        <p className="break-block">Simulated on block {formatBlock(outcome.block)}</p>
      </>
    );
  }
  return (
    <>
      <p className="break-verdict break-verdict-watch">
        <span className="break-mark break-mark-diamond" aria-hidden="true" />
        <span>Could not run it</span>
      </p>
      <p className="break-detail">{outcome.detail}</p>
    </>
  );
}

export function AttackCard({ attack, outcome, running, locked, onRun }: AttackCardProps) {
  const unavailable = attack.unavailable !== null;
  // A line break may fall just after the opening bracket, so a short call never splits in the middle of a number.
  const open = attack.call.indexOf("(") + 1;

  return (
    <article className="break-card">
      <h2 className="break-card-title display-face">{attack.title}</h2>
      <p className="break-card-line">{attack.line}</p>
      <code className="break-code">
        {attack.call.slice(0, open)}
        <wbr />
        {attack.call.slice(open)}
      </code>

      <div className="break-card-foot">
        <p className="break-rule">
          {attack.rules.length > 1 ? "Rules" : "Rule"}{" "}
          {attack.rules.map((rule, index) => (
            <Fragment key={rule}>
              {index > 0 && ", "}
              <a
                className="break-link"
                href={THREAT_MODEL_URL}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={`Rule ${rule} in the threat model, opens in a new tab`}
              >
                {rule}
              </a>
            </Fragment>
          ))}
        </p>
        <button
          type="button"
          className="btn btn-secondary break-run"
          disabled={locked || unavailable}
          aria-busy={running || undefined}
          data-loading={running || undefined}
          aria-label={`Run it: ${attack.title}`}
          onClick={onRun}
        >
          <span className="btn-label">Run it</span>
          {running && <Seal size={16} title="" busy className="btn-seal" />}
        </button>
      </div>

      <div className="break-result" aria-live="polite">
        {unavailable && !running && <p className="break-detail">{attack.unavailable}</p>}
        {!unavailable && !running && outcome && <Result attack={attack} outcome={outcome} />}
      </div>
    </article>
  );
}

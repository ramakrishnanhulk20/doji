"use client";

import { useVotes } from "../../hooks/useVotes";
import type { PositionView } from "../../lib/loans";
import { formatDate } from "../../lib/stats";
import { loanAllowsVoting, percentText, voteCutoff, votingClosed } from "../../lib/votes";
import { Button } from "../Button";
import { RowAction } from "./RowAction";

type VotesPanelProps = {
  /** "row" is the Votes line on a My loans card; "column" is the left half of the card on the loan page. */
  mode: "row" | "column";
  view: PositionView;
  now: number;
  /** The wallet is on another network, so nothing can be sent yet. */
  locked: boolean;
  busy: boolean;
  /** The vote action that is running now, as "reset:389". */
  acting: string | null;
  onVote: () => void;
  onReset: () => void;
};

const unavailable = <span className="loan-unavailable">unavailable</span>;

export function VotesPanel({ mode, view, now, locked, busy, acting, onVote, onReset }: VotesPanelProps) {
  const votes = useVotes(view.id, view.voted === true || mode === "column");
  const pools = votes.data?.pools ?? [];
  const allowed = loanAllowsVoting(view);
  const closed = votingClosed(view.lock, now);
  const canVote = allowed && !closed;
  const canReset = allowed && view.voted === true;
  const off = locked || busy;

  if (mode === "row") {
    const summary =
      view.voted === null
        ? unavailable
        : view.voted
          ? pools.length > 0
            ? `still counting on ${pools.length} pool${pools.length === 1 ? "" : "s"}`
            : "still counting"
          : "yours to cast";
    return (
      <div className="loan-row">
        <dt>Votes</dt>
        <dd className="loan-row-actions">
          <span>{summary}</span>
          {(canVote || canReset) && (
            <span className="row-actions">
              {canVote && (
                <RowAction disabled={off} onClick={onVote}>
                  Vote
                </RowAction>
              )}
              {canReset && (
                <RowAction disabled={off} busy={acting === `reset:${view.id}`} onClick={onReset}>
                  Reset
                </RowAction>
              )}
            </span>
          )}
        </dd>
      </div>
    );
  }

  const cutoff = voteCutoff(view.lock);
  return (
    <div className="vr-col">
      <h3 className="fact-label">Votes</h3>
      {votes.isError ? (
        unavailable
      ) : pools.length > 0 ? (
        <ul className="vr-list">
          {pools.map((entry) => (
            <li key={entry.pool}>
              {entry.symbol}: {percentText(entry.percent)}%
            </li>
          ))}
        </ul>
      ) : (
        <p className="vr-value">{votes.isPending ? "Checking the votes" : "No votes cast."}</p>
      )}
      <p className="vr-note">
        {cutoff === null
          ? "Your lock is permanent, so votes never close."
          : `${closed ? "Votes closed on" : "Votes close on"} ${formatDate(cutoff)}.`}
      </p>
      {allowed ? (
        <>
          <div className="vr-buttons">
            {canVote && (
              <Button className="vr-btn" disabled={off} onClick={onVote}>
                Vote
              </Button>
            )}
            <Button
              className="vr-btn"
              variant="secondary"
              disabled={off || !canReset}
              loading={acting === `reset:${view.id}`}
              onClick={onReset}
            >
              Reset votes
            </Button>
          </div>
          <p className="vr-note">A reset is possible from the next weekly epoch after a vote.</p>
        </>
      ) : (
        <p className="vr-note">You can vote while the loan is active, on time and safe.</p>
      )}
    </div>
  );
}

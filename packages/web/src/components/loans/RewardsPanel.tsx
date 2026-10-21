"use client";

import { useClaimPlan, useVotes } from "../../hooks/useVotes";
import { btcText, type PositionView } from "../../lib/loans";
import { loanAllowsClaims, rebaseLine } from "../../lib/votes";
import { Button } from "../Button";
import { RowAction } from "./RowAction";

type RewardsPanelProps = {
  /** "row" is the Rewards line on a My loans card; "column" is the right half of the card on the loan page. */
  mode: "row" | "column";
  view: PositionView;
  now: number;
  /** The wallet is on another network, so nothing can be sent yet. */
  locked: boolean;
  busy: boolean;
  /** The reward action that is running now, as "rebase:389" or "rewards:389". */
  acting: string | null;
  onClaimRebase: () => void;
  onClaimRewards: () => void;
};

const unavailable = <span className="loan-unavailable">unavailable</span>;

export function RewardsPanel({ mode, view, now, locked, busy, acting, onClaimRebase, onClaimRewards }: RewardsPanelProps) {
  const column = mode === "column";
  const votes = useVotes(view.id, view.voted === true || column);
  const hasVotes = (votes.data?.pools.length ?? 0) > 0;
  const plan = useClaimPlan(view.id, column && hasVotes);
  const allowed = loanAllowsClaims(view);
  const waiting = view.rewards !== null && view.rewards > 0n;
  const off = locked || busy;

  if (mode === "row") {
    return (
      <div className="loan-row">
        <dt>Rewards</dt>
        <dd className="loan-row-actions">
          <span>{view.rewards === null ? unavailable : waiting ? `${btcText(view.rewards)} BTC waiting` : "none due yet"}</span>
          {allowed && (waiting || hasVotes) && (
            <span className="row-actions">
              {waiting && (
                <RowAction disabled={off} busy={acting === `rebase:${view.id}`} onClick={onClaimRebase}>
                  Claim rebase
                </RowAction>
              )}
              {hasVotes && (
                <RowAction disabled={off} busy={acting === `rewards:${view.id}`} onClick={onClaimRewards}>
                  Claim pool rewards
                </RowAction>
              )}
            </span>
          )}
        </dd>
      </div>
    );
  }

  const nothingToClaim = hasVotes && plan.isSuccess && plan.data.gauges.length === 0;
  return (
    <div className="vr-col">
      <h3 className="fact-label">Rewards</h3>
      <p className="vr-value">Rebase waiting: {view.rewards === null ? unavailable : `${btcText(view.rewards)} BTC`}</p>
      <p className="vr-note">{rebaseLine(view.lock, now)}</p>
      <p className="vr-value">Pool fees and incentives: claim to see what is due</p>
      {allowed && (
        <div className="vr-buttons">
          <Button
            className="vr-btn"
            variant="secondary"
            disabled={off || !waiting}
            loading={acting === `rebase:${view.id}`}
            onClick={onClaimRebase}
          >
            Claim rebase
          </Button>
          <Button
            className="vr-btn"
            variant="secondary"
            disabled={off || !hasVotes || nothingToClaim}
            loading={acting === `rewards:${view.id}`}
            onClick={onClaimRewards}
          >
            Claim pool rewards
          </Button>
        </div>
      )}
      {allowed && !hasVotes && votes.isSuccess && (
        <p className="vr-note">Pools pay the positions that voted for them. Vote first to earn their fees and incentives.</p>
      )}
      {allowed && nothingToClaim && (
        <p className="vr-note">Mezo's voter lists no reward token for these pools yet, so there is nothing Doji can claim.</p>
      )}
    </div>
  );
}

"use client";

import { useState } from "react";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useVoteActions } from "../../hooks/useVotes";
import type { PositionView } from "../../lib/loans";
import { formatDate } from "../../lib/stats";
import { canExtendLock } from "../../lib/votes";
import { Button } from "../Button";
import { ExtendLockSheet } from "./ExtendLockSheet";
import type { SendCall } from "./RepaySheet";
import { RewardsPanel } from "./RewardsPanel";
import { VoteSheet } from "./VoteSheet";
import { VotesPanel } from "./VotesPanel";

type VotesAndRewardsProps = {
  view: PositionView;
  now: number;
  send: SendCall;
  busy: boolean;
};

/** The borrower's controls on the loan page: the votes Doji holds for them, the rewards, and the lock. */
export function VotesAndRewards({ view, now, send, busy }: VotesAndRewardsProps) {
  const gate = useLoanGate();
  const actions = useVoteActions(send);
  const [sheet, setSheet] = useState<"vote" | "extend" | null>(null);
  const locked = gate.wrongChain;
  const lock = view.lock;

  return (
    <>
      <section className="vr-card" aria-labelledby="vr-title">
        <h2 id="vr-title" className="vr-title display-face">
          Votes and rewards
        </h2>
        {locked && (
          <div className="paused-strip loans-network">
            <span>Your wallet is on another network. Switch to Mezo testnet to vote, claim or extend.</span>
            <Button className="vr-btn" variant="secondary" onClick={gate.switchNetwork}>
              Switch to Mezo testnet
            </Button>
          </div>
        )}
        <div className="vr-cols">
          <VotesPanel
            mode="column"
            view={view}
            now={now}
            locked={locked}
            busy={busy}
            acting={actions.acting}
            onVote={() => setSheet("vote")}
            onReset={() => void actions.resetVotes(view.id)}
          />
          <RewardsPanel
            mode="column"
            view={view}
            now={now}
            locked={locked}
            busy={busy}
            acting={actions.acting}
            onClaimRebase={() => void actions.claimRebase(view.id)}
            onClaimRewards={() => void actions.claimRewards(view.id)}
          />
        </div>
      </section>

      {canExtendLock(view, now) && lock !== null && (
        <div className="vr-extend">
          <Button className="vr-btn" variant="secondary" disabled={locked || busy} onClick={() => setSheet("extend")}>
            Extend lock
          </Button>
          <span className="vr-extend-note">Lock ends {formatDate(lock.end)}.</span>
        </div>
      )}

      {sheet === "vote" && <VoteSheet view={view} now={now} send={send} busy={busy} onClose={() => setSheet(null)} />}
      {sheet === "extend" && <ExtendLockSheet view={view} now={now} send={send} busy={busy} onClose={() => setSheet(null)} />}
    </>
  );
}

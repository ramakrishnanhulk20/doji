"use client";

import Link from "next/link";
import type { ReactNode } from "react";
import { motion } from "motion/react";
import {
  STATE_NONE,
  auctionLineFor,
  btcText,
  lineUsedBps,
  musdText,
  standingOf,
  toMusdNumber,
  type PositionView,
} from "../../lib/loans";
import type { VoteActions } from "../../hooks/useVotes";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatDate, formatMusd } from "../../lib/stats";
import { canExtendLock } from "../../lib/votes";
import { Button } from "../Button";
import { TweenText } from "../borrow/TweenText";
import { RewardsPanel } from "./RewardsPanel";
import { RowAction } from "./RowAction";
import { LimitBar, StatusChip } from "./Status";
import { VotesPanel } from "./VotesPanel";

type PositionCardProps = {
  view: PositionView;
  index: number;
  now: number;
  /** The wallet is on another network, so nothing can be sent yet. */
  locked: boolean;
  /** The action that is running now, as "withdraw:389", so only its button shows the busy seal. */
  acting: string | null;
  busy: boolean;
  onRepay: (fullOnly: boolean) => void;
  onRoll: () => void;
  onWithdraw: () => void;
  onVote: () => void;
  onExtend: () => void;
  voteActions: VoteActions;
};

function Row({ label, actions, children }: { label: string; actions?: ReactNode; children: ReactNode }) {
  return (
    <div className="loan-row">
      <dt>{label}</dt>
      {actions ? (
        <dd className="loan-row-actions">
          <span>{children}</span>
          <span className="row-actions">{actions}</span>
        </dd>
      ) : (
        <dd>{children}</dd>
      )}
    </div>
  );
}

const unavailable = <span className="loan-unavailable">unavailable</span>;

export function PositionCard({
  view,
  index,
  now,
  locked,
  acting,
  busy,
  onRepay,
  onRoll,
  onWithdraw,
  onVote,
  onExtend,
  voteActions,
}: PositionCardProps) {
  const reduced = useReducedMotion();
  const standing = standingOf(view);
  const hasLoan = view.loan.state !== STATE_NONE;
  const line = auctionLineFor(view);
  const key = `withdraw:${view.id}`;

  return (
    <motion.article
      className="loan-card"
      initial={reduced ? false : { opacity: 0, y: 12 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.45, delay: reduced ? 0 : 0.18 + index * 0.06, ease: [0.22, 1, 0.36, 1] }}
    >
      <header className="loan-card-head">
        <h2 className="loan-card-title display-face">
          <Link className="link-draw" href={`/loans/${view.id}`}>
            veBTC #{String(view.id)}
          </Link>
        </h2>
        <StatusChip standing={standing} />
      </header>

      <dl className="loan-rows">
        <Row label="You owe">
          {hasLoan ? (
            <>
              <TweenText value={toMusdNumber(view.owed)} format={formatMusd} /> MUSD on {formatDate(view.loan.maturity)}
            </>
          ) : (
            "nothing"
          )}
        </Row>
        <Row label="Collateral">
          {view.lock ? `${btcText(view.lock.amount)} BTC` : unavailable}
          {", worth "}
          {view.value === null ? unavailable : `${musdText(view.value)} MUSD`}
        </Row>
      </dl>

      {hasLoan && (
        <LimitBar
          usedBps={lineUsedBps(view)}
          label={line === null ? "Auction line" : `Auction line at BTC ${musdText(line)} MUSD`}
        />
      )}

      <dl className="loan-rows">
        <Row
          label="Lock"
          actions={
            canExtendLock(view, now) && (
              <RowAction disabled={locked || busy} onClick={onExtend}>
                Extend
              </RowAction>
            )
          }
        >
          {view.lock === null ? unavailable : view.lock.isPermanent ? "permanent" : `until ${formatDate(view.lock.end)}`}
        </Row>
        <VotesPanel
          mode="row"
          view={view}
          now={now}
          locked={locked}
          busy={busy}
          acting={voteActions.acting}
          onVote={onVote}
          onReset={() => void voteActions.resetVotes(view.id)}
        />
        <RewardsPanel
          mode="row"
          view={view}
          now={now}
          locked={locked}
          busy={busy}
          acting={voteActions.acting}
          onClaimRebase={() => void voteActions.claimRebase(view.id)}
          onClaimRewards={() => void voteActions.claimRewards(view.id)}
        />
      </dl>

      <div className="loan-actions">
        {(standing === "safe" || standing === "close" || standing === "unknown") && (
          <>
            <Button className="loan-btn" disabled={locked || busy} onClick={() => onRepay(false)}>
              Repay
            </Button>
            <Button className="loan-btn" variant="secondary" disabled={locked || busy} onClick={onRoll}>
              Roll to a later date
            </Button>
          </>
        )}
        {(standing === "auction" || standing === "overdue") && (
          <Button className="loan-btn" disabled={locked || busy} onClick={() => onRepay(true)}>
            Repay in full
          </Button>
        )}
        {standing === "none" && (
          <>
            <Button
              className="loan-btn"
              variant="secondary"
              disabled={locked || busy}
              loading={acting === key}
              onClick={onWithdraw}
            >
              Withdraw veBTC
            </Button>
            <Button className="loan-btn" variant="secondary" href={`/borrow?position=${view.id}`}>
              Borrow against it
            </Button>
          </>
        )}
        <Link className="link-draw loan-open" href={`/loans/${view.id}`}>
          Open loan page
        </Link>
      </div>
    </motion.article>
  );
}

"use client";

import { formatApr, formatDate } from "../../lib/stats";
import { Button } from "../Button";
import { Seal } from "../Seal";
import { fmtMusd } from "../borrow/format";

export type Posted = {
  offerId: bigint;
  amount: bigint;
  aprBps: number;
  maturity: number;
  hash: `0x${string}`;
};

type PostedCardProps = {
  result: Posted;
  onAgain: () => void;
};

export function PostedCard({ result, onAgain }: PostedCardProps) {
  return (
    <section className="success-card">
      <div className="success-seal">
        <Seal size={96} title="Doji" />
      </div>
      <h2 className="success-title display-face">Your offer is live.</h2>
      <p className="lend-posted-line">
        Offer #{String(result.offerId)} · {fmtMusd(result.amount)} MUSD at {formatApr(result.aprBps / 100)} until{" "}
        {formatDate(result.maturity)}
      </p>

      <div className="success-actions">
        <a
          className="btn btn-secondary"
          href={`https://explorer.test.mezo.org/tx/${result.hash}`}
          target="_blank"
          rel="noopener noreferrer"
        >
          <span className="btn-label">View transaction</span>
        </a>
        <Button onClick={onAgain}>Post another</Button>
      </div>
    </section>
  );
}

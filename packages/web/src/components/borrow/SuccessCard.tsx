"use client";

import { Button } from "../Button";
import { Seal } from "../Seal";
import { formatDate } from "../../lib/stats";
import { fmtMusd } from "./format";

export type Borrowed = {
  tokenId: bigint;
  principal: bigint;
  face: bigint;
  maturity: number;
  hash: `0x${string}`;
};

type SuccessCardProps = {
  result: Borrowed;
  onAgain: () => void;
};

export function SuccessCard({ result, onAgain }: SuccessCardProps) {
  return (
    <section className="success-card">
      <div className="success-seal">
        <Seal size={96} title="Doji" />
      </div>
      <h2 className="success-title display-face">{fmtMusd(result.principal)} MUSD is in your wallet.</h2>

      <dl className="success-rows">
        <div className="summary-row">
          <dt>Owed on {formatDate(result.maturity)}</dt>
          <dd>{fmtMusd(result.face)} MUSD</dd>
        </div>
        <div className="summary-row">
          <dt>veBTC #{String(result.tokenId)}</dt>
          <dd>locked, votes and rewards still yours</dd>
        </div>
      </dl>

      <div className="success-actions">
        <Button href={`/loans/${result.tokenId}`}>See your loan</Button>
        <a
          className="btn btn-secondary"
          href={`https://explorer.test.mezo.org/tx/${result.hash}`}
          target="_blank"
          rel="noopener noreferrer"
        >
          <span className="btn-label">View transaction</span>
        </a>
      </div>
      <button type="button" className="text-button success-again" onClick={onAgain}>
        Borrow again
      </button>
    </section>
  );
}

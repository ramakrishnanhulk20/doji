"use client";

import type { ReactNode } from "react";
import type { UseQueryResult } from "@tanstack/react-query";
import {
  EXPLORER,
  STATE_NONE,
  auctionLineFor,
  btcText,
  formatDateTime,
  lineUsedBps,
  musdText,
  shortAddress,
  toMusdNumber,
  type OpenedRecord,
  type PositionView,
} from "../../lib/loans";
import { formatDate, formatHours, formatMusd, formatPercentBps } from "../../lib/stats";
import { ArrowOut } from "../ArrowOut";
import { TweenText } from "../borrow/TweenText";
import { LimitBar } from "./Status";

type FactsProps = {
  view: PositionView;
  opened: UseQueryResult<OpenedRecord | null>;
};

const unavailable = <span className="loan-unavailable">unavailable</span>;

function Fact({ label, wide = false, children }: { label: string; wide?: boolean; children: ReactNode }) {
  return (
    <div className="fact" data-wide={wide || undefined}>
      <dt className={wide ? "sr-only" : "fact-label"}>{label}</dt>
      <dd className="fact-value">{children}</dd>
    </div>
  );
}

function ExplorerLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className="link-draw fact-link" href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <ArrowOut />
    </a>
  );
}

export function Facts({ view, opened }: FactsProps) {
  const hasLoan = view.loan.state !== STATE_NONE;
  const { loan, lock } = view;
  const line = auctionLineFor(view);
  // A token nobody has deposited and that reads no lock is not a position: only its empty borrower is worth showing.
  const bare = !hasLoan && view.borrower === null && lock === null && !opened.data;

  if (bare) {
    return (
      <dl className="facts">
        <Fact label="Borrower">none</Fact>
      </dl>
    );
  }

  return (
    <dl className="facts">
      <Fact label="Borrower">
        {view.borrower ? (
          <ExplorerLink href={`${EXPLORER}/address/${view.borrower}`}>{shortAddress(view.borrower)}</ExplorerLink>
        ) : (
          "none"
        )}
      </Fact>

      {(opened.isPending || opened.isError || opened.data) && (
        <Fact label="Opened">
          {opened.isPending ? (
            <span className="shimmer fact-bar" aria-hidden="true" />
          ) : opened.isError || !opened.data ? (
            unavailable
          ) : (
            <span className="fact-stack">
              <span>
                {musdText(opened.data.principal)} MUSD on {formatDateTime(opened.data.timestamp)}
              </span>
              <ExplorerLink href={`${EXPLORER}/tx/${opened.data.hash}`}>View transaction</ExplorerLink>
            </span>
          )}
        </Fact>
      )}

      {hasLoan && (
        <Fact label="Owed">
          <TweenText value={toMusdNumber(view.owed)} format={formatMusd} /> MUSD on {formatDate(loan.maturity)}
        </Fact>
      )}

      <Fact label="Collateral">
        {lock ? `${btcText(lock.amount)} BTC` : unavailable}
        {", worth "}
        {view.value === null ? unavailable : `${musdText(view.value)} MUSD`}
      </Fact>

      {hasLoan && (
        <Fact label="Limit" wide>
          <LimitBar
            usedBps={lineUsedBps(view)}
            label={line === null ? "Auction line" : `Auction line at BTC ${musdText(line)} MUSD`}
          />
        </Fact>
      )}

      <Fact label="Lock end">
        {lock === null ? unavailable : lock.isPermanent ? "permanent" : formatDate(lock.end)}
      </Fact>
      <Fact label="Votes">{view.voted === null ? unavailable : view.voted ? "still counting" : "yours to cast"}</Fact>
      <Fact label="Rewards">
        {view.rewards === null ? unavailable : view.rewards > 0n ? `${btcText(view.rewards)} BTC waiting` : "none due yet"}
      </Fact>

      {hasLoan && (
        <Fact label="Terms">
          {`limit ${formatPercentBps(loan.maxLtvBps)}, auction line ${formatPercentBps(loan.liqLtvBps)}, floor ${formatPercentBps(loan.auctionFloorBps)}, auction ${formatHours(loan.auctionDuration)}, penalty ${formatPercentBps(loan.penaltyBps)}`}
        </Fact>
      )}
    </dl>
  );
}

"use client";

import Link from "next/link";
import { formatApr, formatDate, formatMusd } from "../../lib/stats";
import { Button } from "../Button";
import { Stepper, type StepperStep } from "../app/Stepper";
import { toNumber } from "./format";
import { TweenText } from "./TweenText";

// The share of the borrow limit up to which the bar stays in the safe colour.
const SAFE_SHARE_BPS = 7_500;

export type SummaryData = {
  collateralText: string | null;
  valueWei: bigint | null;
  maturity: number | null;
  principal: bigint;
  face: bigint | null;
  aprBps: number | null;
  usedBps: number | null;
  auctionPriceWei: bigint | null;
};

export type ConfirmButton = {
  label: string;
  disabled: boolean;
  loading: boolean;
  onClick: () => void;
};

type SummaryCardProps = {
  data: SummaryData;
  steps: readonly StepperStep[];
  confirm: ConfirmButton;
};

const dash = <span className="summary-empty">-</span>;

const money = (wei: bigint | null) =>
  wei === null || wei === 0n ? dash : (
    <>
      <TweenText value={toNumber(wei)} format={formatMusd} /> MUSD
    </>
  );

export function SummaryCard({ data, steps, confirm }: SummaryCardProps) {
  const date = data.maturity === null ? null : formatDate(data.maturity);
  const used = data.usedBps;

  return (
    <div className="summary-card">
      <p className="summary-title">Your loan</p>

      <dl className="summary-rows">
        <div className="summary-row">
          <dt>Collateral</dt>
          <dd>{data.collateralText ?? dash}</dd>
        </div>
        <div className="summary-row">
          <dt>Value now</dt>
          <dd>{money(data.valueWei)}</dd>
        </div>
        <div className="summary-row">
          <dt>Due</dt>
          <dd>{date ? `${date}, 00:00 UTC` : dash}</dd>
        </div>
        <div className="summary-row summary-row-strong">
          <dt>You receive now</dt>
          <dd className="summary-receive">{money(data.principal)}</dd>
        </div>
        <div className="summary-row">
          <dt>{date ? `You owe on ${date}` : "You owe at the due date"}</dt>
          <dd>{money(data.face)}</dd>
        </div>
        <div className="summary-row">
          <dt>Fixed rate</dt>
          <dd>
            {data.aprBps === null ? (
              dash
            ) : (
              <>
                <TweenText value={data.aprBps / 100} format={(value) => formatApr(value).replace("%", "")} />% a year
              </>
            )}
          </dd>
        </div>
        <div className="summary-row summary-row-bar">
          <dt>Borrow limit used</dt>
          <dd>{used === null ? dash : <TweenText value={used / 100} format={(value) => `${value.toFixed(1)}%`} />}</dd>
          <div className="limit-track" aria-hidden="true">
            <div
              className="limit-fill"
              data-over={used !== null && used > SAFE_SHARE_BPS}
              style={{ width: `${Math.min(100, (used ?? 0) / 100)}%` }}
            />
          </div>
        </div>
        <div className="summary-row">
          <dt>Auction line</dt>
          <dd>
            {data.auctionPriceWei === null || data.auctionPriceWei === 0n ? (
              dash
            ) : (
              <>
                if BTC falls below <TweenText value={toNumber(data.auctionPriceWei)} format={formatMusd} /> MUSD
              </>
            )}
          </dd>
        </div>
        <div className="summary-row">
          <dt>Votes and rewards</dt>
          <dd>stay yours</dd>
        </div>
      </dl>

      <p className="summary-print">Repaying early still costs the full amount owed: the lender&apos;s return is fixed.</p>
      <p className="summary-print">
        If the loan becomes unsafe or the date passes unpaid, the position goes to a{" "}
        <Link className="link-draw" href="/#risk">
          protected auction
        </Link>
        .
      </p>

      {steps.length > 0 && (
        <div className="summary-steps">
          <Stepper steps={steps} />
        </div>
      )}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </div>
  );
}

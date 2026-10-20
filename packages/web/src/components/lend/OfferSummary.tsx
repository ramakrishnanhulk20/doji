"use client";

import { formatUnitsNumber } from "../../lib/lend";
import { formatApr, formatDate } from "../../lib/stats";
import { Button } from "../Button";
import { Stepper, type StepperStep } from "../app/Stepper";
import { toNumber } from "../borrow/format";
import { TweenText } from "../borrow/TweenText";

export type OfferSummaryData = {
  amount: bigint;
  maturity: number | null;
  aprBps: number | null;
  makerUnits: bigint | null;
  treasuryUnits: bigint | null;
  /** The protocol's share of the interest in basis points, read from the contract. */
  feeShareBps: number | null;
};

export type ConfirmButton = {
  label: string;
  disabled: boolean;
  loading: boolean;
  onClick: () => void;
};

type OfferSummaryProps = {
  data: OfferSummaryData;
  steps: readonly StepperStep[];
  confirm: ConfirmButton;
};

const dash = <span className="summary-empty">-</span>;

const musd = (wei: bigint) => <TweenText value={toNumber(wei)} format={formatUnitsNumber} />;

export function OfferSummary({ data, steps, confirm }: OfferSummaryProps) {
  const date = data.maturity === null ? null : formatDate(data.maturity);
  const fee = data.feeShareBps === null ? null : +(data.feeShareBps / 100).toFixed(2);

  return (
    <div className="summary-card lend-summary">
      <p className="summary-title">Your offer</p>

      <dl className="summary-rows">
        <div className="summary-row summary-row-strong">
          <dt>Lend</dt>
          <dd className="summary-receive">
            {data.amount > 0n ? <>{musd(data.amount)} MUSD</> : dash}
          </dd>
        </div>
        <div className="summary-row">
          <dt>Until</dt>
          <dd>{date ? `${date}, 00:00 UTC` : dash}</dd>
        </div>
        <div className="summary-row">
          <dt>Rate</dt>
          <dd>
            {data.aprBps === null ? (
              dash
            ) : (
              <>
                <TweenText value={data.aprBps / 100} format={(value) => formatApr(value).replace("%", "")} />% a year, fixed
              </>
            )}
          </dd>
        </div>
        <div className="summary-row">
          <dt>If taken now, you are owed</dt>
          <dd>
            {data.makerUnits === null || date === null ? (
              dash
            ) : (
              <>
                {musd(data.makerUnits)} MUSD on {date}
              </>
            )}
          </dd>
        </div>
        <div className="summary-row">
          <dt>Credit units</dt>
          <dd>
            {data.makerUnits === null || date === null ? (
              dash
            ) : (
              <>
                {musd(data.makerUnits)} <span className="lend-row-note">(1 unit = 1 MUSD due on {date})</span>
              </>
            )}
          </dd>
        </div>
        <div className="summary-row">
          <dt>Protocol fee</dt>
          <dd>
            {data.treasuryUnits === null || fee === null ? (
              dash
            ) : (
              <>
                {musd(data.treasuryUnits)} units
                <span className="lend-row-note">, {fee}% of the interest, sharing any loss with you</span>
              </>
            )}
          </dd>
        </div>
      </dl>

      <p className="summary-print">
        Interest counts from when a borrower takes the offer, so an offer taken later earns a little less.
      </p>
      <p className="summary-print">
        Your units for a date share that date&apos;s repayments, auction proceeds and settled Bitcoin with every other
        lender at that date.
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

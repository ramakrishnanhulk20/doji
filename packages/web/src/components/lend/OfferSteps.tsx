"use client";

import Link from "next/link";
import type { ThursdayCard } from "../../lib/stats";
import { formatApr, formatDate, formatMusd } from "../../lib/stats";
import { fmtMusd, sanitizeAmount } from "../borrow/format";
import { AmountField, StepHeader } from "../borrow/Steps";

type DateStepProps = {
  dates: readonly ThursdayCard[];
  selected: number | null;
  onSelect: (maturity: number) => void;
  status: "loading" | "error" | "ready";
};

export function LendDateStep({ dates, selected, onSelect, status }: DateStepProps) {
  return (
    <section className="borrow-step">
      <StepHeader number="01" title="Due date" />
      <div className="date-strip" role="radiogroup" aria-label="Due date">
        {status === "loading" ? (
          [0, 1, 2, 3].map((slot) => <span key={slot} className="date-skeleton shimmer" />)
        ) : status === "error" ? (
          <p className="field-note field-note-problem">unavailable</p>
        ) : dates.length === 0 ? (
          <p className="field-note field-note-plain">No Thursday is open for new offers right now.</p>
        ) : (
          dates.map((card) => (
            <label key={card.maturity} className="date-card" data-selected={selected === card.maturity}>
              <input
                type="radio"
                name="offer-date"
                className="sr-only"
                checked={selected === card.maturity}
                onChange={() => onSelect(card.maturity)}
              />
              <span className="date-card-date display-face">{formatDate(card.maturity)}</span>
              {card.bestAprBps === null ? (
                <span className="date-card-available">no offers yet: you&apos;d set the rate</span>
              ) : (
                <>
                  <span className="lend-best">
                    <span className="date-card-available">best now</span>{" "}
                    <span className="date-card-rate">{formatApr(card.bestAprBps / 100)}</span>
                  </span>
                  <span className="date-card-available">
                    {card.offerCount} {card.offerCount === 1 ? "offer" : "offers"} · {formatMusd(card.musdOnOffer)} MUSD on offer · {formatMusd(card.lent)} MUSD due to lenders
                  </span>
                </>
              )}
            </label>
          ))
        )}
      </div>
    </section>
  );
}

type RateStepProps = {
  rateText: string;
  onRateText: (text: string) => void;
  /** The chosen date and the lowest rate among its open offers, or null when it has none. */
  date: { maturity: number; bestAprBps: number | null } | null;
};

export function RateStep({ rateText, onRateText, date }: RateStepProps) {
  return (
    <section className="borrow-step">
      <StepHeader number="02" title="Your rate" />
      <div className="step-body">
        <div className="amount-field lend-rate-field">
          <label className="sr-only" htmlFor="offer-rate">
            Rate in percent a year
          </label>
          <input
            id="offer-rate"
            className="amount-input"
            inputMode="decimal"
            autoComplete="off"
            value={rateText}
            onChange={(event) => onRateText(sanitizeAmount(event.target.value, 2))}
          />
          {rateText === "" && (
            <span className="amount-hint" aria-hidden="true">
              0.00
            </span>
          )}
          <span className="amount-unit">% a year</span>
        </div>
        <p className="field-note field-note-plain">
          Borrowers take the cheapest offers first.
          {date !== null &&
            (date.bestAprBps === null
              ? ` No offers for ${formatDate(date.maturity)} yet.`
              : ` Best offer for ${formatDate(date.maturity)} now: ${formatApr(date.bestAprBps / 100)}.`)}
        </p>
      </div>
    </section>
  );
}

type AmountStepProps = {
  amountText: string;
  onAmountText: (text: string) => void;
  onMax: () => void;
  maxDisabled: boolean;
  /** The wallet's MUSD balance, or why it is not shown. */
  balance: { kind: "connect" } | { kind: "loading" } | { kind: "error" } | { kind: "ready"; wei: bigint };
  minOffer: bigint | undefined;
};

export function LendAmountStep({ amountText, onAmountText, onMax, maxDisabled, balance, minOffer }: AmountStepProps) {
  const minimum = minOffer === undefined ? null : `minimum ${fmtMusd(minOffer)} MUSD`;
  const lead =
    balance.kind === "ready"
      ? `Balance ${fmtMusd(balance.wei)} MUSD`
      : balance.kind === "connect"
        ? "Connect a wallet to see your balance"
        : balance.kind === "loading"
          ? "Reading your balance"
          : "Balance unavailable";

  return (
    <section className="borrow-step">
      <StepHeader number="03" title="Amount" />
      <div className="step-body">
        <AmountField
          id="offer-amount"
          label="MUSD to lend"
          value={amountText}
          unit="MUSD"
          decimals={2}
          onChange={onAmountText}
          onMax={onMax}
          maxDisabled={maxDisabled}
        />
        <p className={balance.kind === "error" ? "field-note field-note-problem" : "field-note"}>
          {lead}
          {minimum !== null && ` · ${minimum}`}
        </p>
        {(balance.kind === "connect" || (balance.kind === "ready" && balance.wei === 0n)) && (
          <p className="field-note field-note-plain">
            No test MUSD yet?{" "}
            <Link className="link-draw" href="/borrow">
              Borrow some on Doji
            </Link>
            , then lend it.
          </p>
        )}
      </div>
    </section>
  );
}

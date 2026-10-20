"use client";

import type { CSSProperties, ReactNode } from "react";
import type { Position } from "../../lib/borrow-reads";
import type { DateGroup } from "../../lib/borrow";
import { formatApr, formatDate } from "../../lib/stats";
import { fmtBtc, fmtMusd, sanitizeAmount } from "./format";

type StepHeaderProps = { number: string; title: string };

export function StepHeader({ number, title }: StepHeaderProps) {
  return (
    <div className="step-head">
      <span className="step-head-number">{number}</span>
      <h2 className="step-head-title display-face">{title}</h2>
    </div>
  );
}

type AmountFieldProps = {
  id: string;
  label: string;
  value: string;
  unit: string;
  decimals: number;
  onChange: (text: string) => void;
  onMax?: () => void;
  maxDisabled?: boolean;
};

export function AmountField({ id, label, value, unit, decimals, onChange, onMax, maxDisabled }: AmountFieldProps) {
  return (
    <div className="amount-field">
      <label className="sr-only" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className="amount-input"
        inputMode="decimal"
        autoComplete="off"
        value={value}
        onChange={(event) => onChange(sanitizeAmount(event.target.value, decimals))}
      />
      {value === "" && (
        <span className="amount-hint" aria-hidden="true">
          0.00
        </span>
      )}
      <span className="amount-unit">{unit}</span>
      {onMax && (
        <button type="button" className="amount-max" disabled={maxDisabled} onClick={onMax}>
          Max
        </button>
      )}
    </div>
  );
}

type SegmentedProps = {
  value: "lock" | "position";
  onChange: (value: "lock" | "position") => void;
};

function Segmented({ value, onChange }: SegmentedProps) {
  return (
    <div className="segmented" role="tablist" aria-label="Collateral">
      <button type="button" role="tab" aria-selected={value === "lock"} className="segmented-tab" onClick={() => onChange("lock")}>
        Lock BTC now
      </button>
      <button type="button" role="tab" aria-selected={value === "position"} className="segmented-tab" onClick={() => onChange("position")}>
        Use a veBTC position
      </button>
    </div>
  );
}

type CollateralStepProps = {
  tab: "lock" | "position";
  onTab: (tab: "lock" | "position") => void;
  btcText: string;
  onBtcText: (text: string) => void;
  onMaxBtc: () => void;
  connected: boolean;
  balance: bigint | undefined;
  balanceValue: bigint | undefined;
  maturity: number | null;
  positions: { loading: boolean; error: boolean; list: readonly Position[] | undefined };
  selectedId: bigint | null;
  onSelectPosition: (id: bigint) => void;
  onConnect: () => void;
};

export function CollateralStep(props: CollateralStepProps) {
  const { tab, connected, positions } = props;

  return (
    <section className="borrow-step">
      <StepHeader number="01" title="Your collateral" />
      <Segmented value={tab} onChange={props.onTab} />

      {tab === "lock" ? (
        <div className="step-body">
          <AmountField
            id="btc-amount"
            label="BTC to lock"
            value={props.btcText}
            unit="BTC"
            decimals={18}
            onChange={props.onBtcText}
            onMax={props.onMaxBtc}
            maxDisabled={!connected || props.balance === undefined}
          />
          <p className="field-note">
            {connected && props.balance !== undefined
              ? `Balance ${fmtBtc(props.balance, 4)} BTC${
                  props.balanceValue !== undefined ? ` · worth ${fmtMusd(props.balanceValue)} MUSD at the oracle price` : ""
                }`
              : "Connect a wallet to see your balance"}
          </p>
          {props.maturity !== null && (
            <p className="field-note field-note-plain">
              Locked until {formatDate(props.maturity)}, the day the loan is due.
            </p>
          )}
        </div>
      ) : (
        <div className="step-body">
          {!connected ? (
            <p className="field-note field-note-plain">
              Connect a wallet to see your veBTC positions.{" "}
              <button type="button" className="text-button" onClick={props.onConnect}>
                Connect wallet
              </button>
            </p>
          ) : positions.loading ? (
            <div className="position-list" aria-busy="true">
              {[0, 1].map((slot) => (
                <span key={slot} className="position-skeleton shimmer" />
              ))}
            </div>
          ) : positions.error ? (
            <p className="field-note field-note-problem">unavailable</p>
          ) : (positions.list ?? []).length === 0 ? (
            <p className="field-note field-note-plain">
              No veBTC positions in this wallet.{" "}
              <button type="button" className="text-button" onClick={() => props.onTab("lock")}>
                Lock BTC now instead.
              </button>
            </p>
          ) : (
            <div className="position-list" role="radiogroup" aria-label="veBTC positions">
              {(positions.list ?? []).map((position) => (
                <label
                  key={String(position.id)}
                  className="position-row"
                  data-disabled={!position.accepted}
                  data-selected={props.selectedId === position.id}
                >
                  <input
                    type="radio"
                    name="position"
                    className="sr-only"
                    disabled={!position.accepted}
                    checked={props.selectedId === position.id}
                    onChange={() => props.onSelectPosition(position.id)}
                  />
                  <span className="position-id">
                    veBTC #{String(position.id)}
                    {position.inDoji && <span className="position-tag">in Doji</span>}
                  </span>
                  <span className="position-amount">{fmtBtc(position.amount, 4)} BTC</span>
                  <span className="position-lock">
                    {position.isPermanent ? "permanent lock" : `locked until ${formatDate(position.end)}`}
                  </span>
                  {position.accepted ? (
                    <span className="position-value">{fmtMusd(position.value)} MUSD</span>
                  ) : (
                    <span className="position-reason">grant-backed, can&apos;t be used</span>
                  )}
                </label>
              ))}
            </div>
          )}
        </div>
      )}
    </section>
  );
}

type DateStepProps = {
  dates: readonly number[];
  groups: readonly DateGroup[];
  selected: number | null;
  onSelect: (maturity: number) => void;
  status: "loading" | "error" | "ready";
  /** A date whose offers add up to less than this can still be picked, but is marked. */
  minLoan: bigint;
};

export function DateStep({ dates, groups, selected, onSelect, status, minLoan }: DateStepProps) {
  return (
    <section className="borrow-step">
      <StepHeader number="02" title="Due date" />
      <div className="date-strip" role="radiogroup" aria-label="Due date">
        {status === "loading" ? (
          [0, 1, 2, 3].map((slot) => <span key={slot} className="date-skeleton shimmer" />)
        ) : status === "error" ? (
          <p className="field-note field-note-problem">unavailable</p>
        ) : dates.length === 0 ? (
          <p className="field-note field-note-plain">No Thursday is open for this collateral yet.</p>
        ) : (
          dates.map((date) => {
            const group = groups.find((candidate) => candidate.maturity === date);
            return (
              <label key={date} className="date-card" data-selected={selected === date} data-disabled={!group}>
                <input
                  type="radio"
                  name="due-date"
                  className="sr-only"
                  disabled={!group}
                  checked={selected === date}
                  onChange={() => onSelect(date)}
                />
                <span className="date-card-date display-face">{formatDate(date)}</span>
                {group ? (
                  <>
                    <span className="date-card-rate">{formatApr(group.bestAprBps / 100)}</span>
                    <span className="date-card-available">{fmtMusd(group.available)} MUSD available</span>
                    {minLoan > 0n && group.available < minLoan && (
                      <span className="date-card-available">below the {fmtMusd(minLoan)} MUSD minimum</span>
                    )}
                  </>
                ) : (
                  <span className="date-card-available">no offers yet</span>
                )}
              </label>
            );
          })
        )}
      </div>
    </section>
  );
}

type AmountStepProps = {
  principalText: string;
  onPrincipalText: (text: string) => void;
  maxCents: number;
  cents: number;
  onSlide: (cents: number) => void;
  onMax: () => void;
  maxDisabled: boolean;
  note: ReactNode;
};

export function AmountStep({ principalText, onPrincipalText, maxCents, cents, onSlide, onMax, maxDisabled, note }: AmountStepProps) {
  const fill = maxCents > 0 ? Math.min(100, (cents / maxCents) * 100) : 0;
  return (
    <section className="borrow-step">
      <StepHeader number="03" title="Amount" />
      <div className="step-body">
        <AmountField
          id="musd-amount"
          label="MUSD to borrow"
          value={principalText}
          unit="MUSD"
          decimals={2}
          onChange={onPrincipalText}
          onMax={onMax}
          maxDisabled={maxDisabled}
        />
        <input
          className="range"
          type="range"
          min={0}
          max={Math.max(maxCents, 1)}
          step={1}
          value={Math.min(cents, Math.max(maxCents, 1))}
          disabled={maxCents <= 0}
          aria-label="MUSD to borrow"
          style={{ "--fill": `${fill}%` } as CSSProperties}
          onChange={(event) => onSlide(Number(event.target.value))}
        />
        <p className="field-note">{note}</p>
      </div>
    </section>
  );
}

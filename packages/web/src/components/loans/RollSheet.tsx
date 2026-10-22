"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useLoanClock } from "../../hooks/useLoanClock";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanSteps, type FlowStep } from "../../hooks/useLoanSteps";
import { groupOffersByDate, roundDownToCent, selectOffers, type DateGroup } from "../../lib/borrow";
import type { BorrowSettings } from "../../lib/borrow-reads";
import {
  approveMusdCall,
  approveText,
  musdText,
  quoteRoll,
  rollCall,
  rollDates,
  rollProblem,
  rollSteps,
  toMusdNumber,
  type MusdWallet,
  type PositionView,
} from "../../lib/loans";
import { formatApr, formatDate, formatMusd, type OpenOffer } from "../../lib/stats";
import { buildExtendLockCall, rollExtensionDates } from "../../lib/votes";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { fmtMusd, musdFieldText, parseAmount } from "../borrow/format";
import { AmountField } from "../borrow/Steps";
import { TweenText } from "../borrow/TweenText";
import { Sheet } from "./Sheet";
import type { SendCall } from "./RepaySheet";

type RollSheetProps = {
  view: PositionView;
  client: PublicClient | undefined;
  settings: BorrowSettings | undefined;
  offers: readonly OpenOffer[] | undefined;
  wallet: MusdWallet | undefined;
  send: SendCall;
  busy: boolean;
  onClose: () => void;
};

const dash = <span className="summary-empty">-</span>;

/** A top-up under a cent would read as zero, so it says so. */
const smallMusd = (wei: bigint): string => (wei > 0n && wei < 10n ** 16n ? "under 0.01" : fmtMusd(wei));

export function RollSheet({ view, client, settings, offers, wallet, send, busy, onClose }: RollSheetProps) {
  const gate = useLoanGate();
  const flow = useLoanSteps();
  const now = useLoanClock(30_000);
  const { id, owed } = view;

  const [pick, setPick] = useState<number | null>(null);
  // Rounding up leaves a payout of under a cent instead of a top-up, so the default roll needs no approval step.
  const [text, setText] = useState(() => musdFieldText(roundDownToCent(owed + 10n ** 16n - 1n)));

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    if (!flow.running) flow.reset();
  }, [pick, text]);

  const groups = useMemo(() => groupOffersByDate(offers ?? []), [offers]);
  const insideLock = useMemo(() => (settings ? rollDates(view, settings.maxTermSeconds, now) : []), [settings, view, now]);
  const pastLock = useMemo(() => (settings ? rollExtensionDates(view, settings.maxTermSeconds, now) : []), [settings, view, now]);
  const dates = useMemo(() => [...insideLock, ...pastLock], [insideLock, pastLock]);

  const minLoan = settings?.minLoan ?? 0n;
  const defaultDate =
    dates.find((date) => groups.some((group) => group.maturity === date && group.available >= minLoan)) ??
    dates.find((date) => groups.some((group) => group.maturity === date)) ??
    null;
  const maturity = pick !== null && dates.includes(pick) && groups.some((group) => group.maturity === pick) ? pick : defaultDate;
  const group: DateGroup | undefined = maturity === null ? undefined : groups.find((candidate) => candidate.maturity === maturity);

  const principal = roundDownToCent(parseAmount(text));
  const selection = useMemo(() => selectOffers(principal, group?.offers ?? []), [principal, group]);
  const offersKey = (group?.offers ?? []).map((offer) => `${offer.id}:${offer.remaining}`).join(",");

  const quote = useQuery({
    queryKey: ["roll-quote", String(id), maturity, principal.toString(), offersKey],
    queryFn: () => quoteRoll(client as PublicClient, { view, group: group as DateGroup, principal }),
    enabled: client !== undefined && group !== undefined && principal > 0n && selection.filled === principal,
    staleTime: 10_000,
    retry: false,
  });

  const reason = (() => {
    if (!settings || wallet === undefined) return "Checking the numbers";
    if (quote.isError) return "Doji could not price this roll. Pick another date or try again.";
    return rollProblem({ view, settings, group, principal, quote: quote.data, musdBalance: wallet.balance });
  })();

  const extendTo = maturity !== null && pastLock.includes(maturity) ? maturity : null;
  const plan = quote.data && wallet ? rollSteps(quote.data.topUp, wallet.allowance, extendTo) : [];

  const run = async () => {
    if (!quote.data || wallet === undefined || maturity === null) return;
    const planned = quote.data;
    const date = maturity;
    const steps: FlowStep[] = rollSteps(planned.topUp, wallet.allowance, extendTo).map((step) => ({
      ...step,
      run: () => {
        if (step.id === "extend") {
          return send(
            buildExtendLockCall(id, date, Math.floor(Date.now() / 1000)),
            `The lock on veBTC #${id} now runs to ${formatDate(date)}.`,
          );
        }
        if (step.id === "approve") {
          return send(approveMusdCall(planned.topUp), `Approved ${approveText(planned.topUp)} MUSD for Doji.`);
        }
        return send(rollCall(id, date, planned.selection, planned.topUp), `veBTC #${id} rolled to ${formatDate(date)}.`);
      },
    }));
    if (await flow.start(steps)) onClose();
  };

  const running = flow.running || busy;
  const confirm = (() => {
    if (!gate.isConnected) return { label: "Connect wallet to roll", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (reason) return { label: reason, disabled: true, loading: false, onClick: () => undefined };
    if (flow.confirming) return { label: "Waiting for confirmation", disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow.failedAt !== null) {
      return {
        label: `Try again from step ${flow.failedAt + 1}`,
        disabled: false,
        loading: false,
        onClick: () => void flow.retry().then((done) => done && onClose()),
      };
    }
    return { label: `Roll to ${formatDate(maturity as number)}`, disabled: false, loading: false, onClick: () => void run() };
  })();

  const lock = view.lock;
  const noDates =
    lock === null
      ? "No later Thursday is open for this loan."
      : lock.isPermanent
        ? "No later Thursday is inside the longest term."
        : `No later Thursday fits inside your lock, which ends ${formatDate(lock.end)}.`;

  const ready = settings !== undefined && offers !== undefined;
  const q = quote.data;

  return (
    <Sheet title={`Roll veBTC #${id}`} locked={running} onClose={onClose}>
      <p className="loan-sheet-lead">
        You owe {musdText(owed)} MUSD on {formatDate(view.loan.maturity)}.
      </p>

      {!ready ? (
        <div className="roll-dates" aria-busy="true">
          {[0, 1, 2].map((slot) => (
            <span key={slot} className="date-skeleton shimmer" />
          ))}
        </div>
      ) : dates.length === 0 ? (
        <p className="field-note field-note-plain">{noDates}</p>
      ) : (
        <>
          <div className="roll-dates" role="radiogroup" aria-label="Later due date">
            {dates.map((date) => {
              const dateGroup = groups.find((candidate) => candidate.maturity === date);
              return (
                <label key={date} className="date-card" data-selected={maturity === date} data-disabled={!dateGroup}>
                  <input
                    type="radio"
                    name="roll-date"
                    className="sr-only"
                    disabled={!dateGroup}
                    checked={maturity === date}
                    onChange={() => setPick(date)}
                  />
                  <span className="date-card-date display-face">{formatDate(date)}</span>
                  {dateGroup ? (
                    <>
                      <span className="date-card-rate">{formatApr(dateGroup.bestAprBps / 100)}</span>
                      <span className="date-card-available">{fmtMusd(dateGroup.available)} MUSD available</span>
                    </>
                  ) : (
                    <span className="date-card-available">no offers yet</span>
                  )}
                  {pastLock.includes(date) && <span className="date-card-tag">extends your lock</span>}
                </label>
              );
            })}
          </div>

          <AmountField
            id="roll-amount"
            label="New principal in MUSD"
            value={text}
            unit="MUSD"
            decimals={2}
            onChange={setText}
          />

          <dl className="summary-rows roll-rows">
            <div className="summary-row">
              <dt>New principal</dt>
              <dd>{principal > 0n ? `${musdText(principal)} MUSD` : dash}</dd>
            </div>
            <div className="summary-row">
              <dt>{maturity === null ? "You owe at the due date" : `You owe on ${formatDate(maturity)}`}</dt>
              <dd>{q ? <><TweenText value={toMusdNumber(q.face)} format={formatMusd} /> MUSD</> : dash}</dd>
            </div>
            <div className="summary-row">
              <dt>Fixed rate</dt>
              <dd>
                {q ? <><TweenText value={q.aprBps / 100} format={(value) => formatApr(value).replace("%", "")} />% a year</> : dash}
              </dd>
            </div>
            {q && q.topUp > 0n && (
              <div className="summary-row">
                <dt>You top up</dt>
                <dd>{smallMusd(q.topUp)} MUSD</dd>
              </div>
            )}
            {q && q.excess > 0n && (
              <div className="summary-row">
                <dt>Paid out to you</dt>
                <dd>{smallMusd(q.excess)} MUSD</dd>
              </div>
            )}
          </dl>

          <p className="field-note field-note-plain">
            Rolling repays this loan from the new one in a single step. If the new principal is less than what you owe, you
            top up the difference.
          </p>
          {extendTo !== null && <p className="field-note field-note-plain">Your BTC stays locked until the new date.</p>}

          {plan.length > 0 && (
            <div className="summary-steps">
              <Stepper steps={flow.rows(plan)} />
            </div>
          )}

          <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
            {confirm.label}
          </Button>
        </>
      )}
    </Sheet>
  );
}

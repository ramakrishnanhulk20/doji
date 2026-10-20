"use client";

import { useId, useRef, useState } from "react";
import { motion } from "motion/react";
import { formatUnits, getAddress, isAddress, type Address } from "viem";
import {
  dateState,
  finalizeCall,
  claimUnitsCall,
  fmtBtcAmount,
  fmtPerUnit,
  formatUnitsNumber,
  redeemAmounts,
  redeemCall,
  sendUnitsCall,
  unitValue,
  withdrawCollectedCall,
  withdrawalAmounts,
  type DateUnits,
  type LendCall,
} from "../../lib/lend";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatDate } from "../../lib/stats";
import { Button } from "../Button";
import { fmtMusd, parseAmount, sanitizeAmount, toNumber } from "../borrow/format";
import { TweenText } from "../borrow/TweenText";
import type { ListState } from "./OffersTable";
import { StatusChip } from "./StatusChip";
import { useDialog } from "./useDialog";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Runs one write. Resolves true when it went through. */
export type Act = (key: string, call: LendCall, successLine: string) => Promise<boolean>;

type Shared = {
  runningKey: string | null;
  busy: boolean;
  act: Act;
};

const units = (wei: bigint) => <TweenText value={toNumber(wei)} format={formatUnitsNumber} />;
const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;

type SendFormProps = Shared & {
  row: DateUnits;
  address: Address;
  onClose: () => void;
};

function SendForm({ row, address, act, busy, runningKey, onClose }: SendFormProps) {
  const [to, setTo] = useState("");
  const [unitsText, setUnitsText] = useState("");
  const toId = useId();
  const unitsId = useId();

  const target = to.trim();
  const wei = parseAmount(unitsText);
  const addressProblem =
    target === ""
      ? null
      : !isAddress(target)
        ? "That isn't a valid address. If it has capital letters, they have to match the address's checksum."
        : target.toLowerCase() === ZERO_ADDRESS
          ? "Units can't be sent to the zero address."
          : null;
  const validTarget = target !== "" && addressProblem === null;
  const unitsProblem = wei > row.balance ? `You hold ${fmtMusd(row.balance)} units.` : null;
  const key = `send:${row.maturity}`;
  const ready = validTarget && wei > 0n && unitsProblem === null;

  const send = async () => {
    if (!ready) return;
    const recipient = getAddress(target);
    const done = await act(
      key,
      sendUnitsCall(address, recipient, row.maturity, wei),
      `Sent ${fmtMusd(wei)} units to ${shortAddress(recipient)}.`,
    );
    if (done) onClose();
  };

  return (
    <div className="lend-send">
      <div className="lend-field">
        <label htmlFor={toId}>Send to</label>
        <input
          id={toId}
          className="lend-input"
          autoComplete="off"
          spellCheck={false}
          value={to}
          onChange={(event) => setTo(event.target.value)}
        />
        {addressProblem !== null ? (
          <p className="lend-field-note lend-field-problem">{addressProblem}</p>
        ) : validTarget ? (
          <p className="lend-field-note">Sending to {getAddress(target)}</p>
        ) : null}
      </div>
      <div className="lend-field">
        <label htmlFor={unitsId}>Units</label>
        <div className="lend-input-wrap">
          <input
            id={unitsId}
            className="lend-input"
            inputMode="decimal"
            autoComplete="off"
            value={unitsText}
            onChange={(event) => setUnitsText(sanitizeAmount(event.target.value, 18))}
          />
          <button type="button" className="amount-max" onClick={() => setUnitsText(formatUnits(row.balance, 18))}>
            Max
          </button>
        </div>
        {unitsProblem !== null && <p className="lend-field-note lend-field-problem">{unitsProblem}</p>}
      </div>
      <div className="lend-send-actions">
        <Button className="lend-small" disabled={!ready || busy} loading={runningKey === key} onClick={() => void send()}>
          {wei > 0n && unitsProblem === null ? `Send ${fmtMusd(wei)} units` : "Send units"}
        </Button>
        <button type="button" className="text-button lend-text-action" onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}

type WithdrawSheetProps = Shared & {
  row: DateUnits;
  onClose: () => void;
};

function WithdrawSheet({ row, act, busy, runningKey, onClose }: WithdrawSheetProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  useDialog(dialogRef, onClose);
  const titleId = useId();
  const unitsId = useId();
  const [unitsText, setUnitsText] = useState(formatUnits(row.balance, 18));

  const wei = parseAmount(unitsText);
  const over = wei > row.balance;
  const pay = withdrawalAmounts(row.market, row.claim, over ? row.balance : wei);
  const key = `withdraw:${row.maturity}`;

  const confirm = async () => {
    if (wei === 0n || over) return;
    const done = await act(key, withdrawCollectedCall(row.maturity, wei), `You withdrew ${fmtMusd(pay.musd)} MUSD and ${fmtBtcAmount(pay.btc)} BTC.`);
    if (done) onClose();
  };

  return (
    <div className="modal-overlay" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <div ref={dialogRef} className="modal-card" data-lenis-prevent role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <p className="lend-modal-date">{formatDate(row.maturity)}</p>
        <h2 id={titleId} className="modal-title display-face">
          Withdraw what&apos;s collected
        </h2>

        <div className="lend-field lend-modal-field">
          <label htmlFor={unitsId}>Units to move</label>
          <div className="lend-input-wrap">
            <input
              id={unitsId}
              className="lend-input"
              inputMode="decimal"
              autoComplete="off"
              value={unitsText}
              onChange={(event) => setUnitsText(sanitizeAmount(event.target.value, 18))}
            />
            <button type="button" className="amount-max" onClick={() => setUnitsText(formatUnits(row.balance, 18))}>
              Max
            </button>
          </div>
          {over && <p className="lend-field-note lend-field-problem">{`You hold ${fmtMusd(row.balance)} units.`}</p>}
        </div>

        <p className="lend-get">
          You get now: {fmtMusd(pay.musd)} MUSD and {fmtBtcAmount(pay.btc)} BTC
        </p>
        <p className="lend-watch-note">
          Units you move into a withdrawal can no longer be sold or sent; you keep your share of what is still to come.
        </p>

        <div className="lend-modal-actions">
          <Button
            className="lend-modal-confirm"
            disabled={wei === 0n || over || busy}
            loading={runningKey === key}
            onClick={() => void confirm()}
          >
            Withdraw
          </Button>
          <button type="button" className="text-button lend-text-action" onClick={onClose}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}

type CardProps = Shared & {
  row: DateUnits;
  now: number;
  address: Address;
};

function UnitsCard({ row, now, address, act, busy, runningKey }: CardProps) {
  const reduced = useReducedMotion();
  const [panel, setPanel] = useState<"send" | "withdraw" | null>(null);
  const { market, claim, maturity } = row;
  const state = dateState(market, maturity, now);
  const date = formatDate(maturity);
  const waiting = withdrawalAmounts(market, claim, 0n);
  const hasWaiting = claim.units > 0n && (waiting.musd > 0n || waiting.btc > 0n);
  const perUnit = unitValue(market);
  const redeem = redeemAmounts(market, row.balance);
  const key = (name: string) => `${name}:${maturity}`;
  const loading = (name: string) => runningKey === key(name);
  const openLoans = Number(market.openLoans);

  const hasActions =
    (state === "open" && row.balance > 0n) ||
    ((state === "due" || state === "closeable") && (row.balance > 0n || hasWaiting || state === "closeable")) ||
    (state === "final" && (row.balance > 0n || hasWaiting));

  return (
    <>
      <motion.article
        className="lend-card"
        initial={reduced ? false : { opacity: 0, y: 12 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.45, ease: [0.22, 1, 0.36, 1] }}
      >
        <header className="lend-card-head">
          <h3 className="lend-card-date display-face">{date}</h3>
          {state === "open" ? (
            <StatusChip tone="safe">Open</StatusChip>
          ) : state === "final" ? (
            <StatusChip tone="neutral">Closed</StatusChip>
          ) : (
            <StatusChip tone="watch">{`Due, ${openLoans} ${openLoans === 1 ? "loan" : "loans"} still open`}</StatusChip>
          )}
        </header>

        <dl className="summary-rows">
          <div className="summary-row">
            <dt>Units you hold</dt>
            <dd>{units(row.balance)}</dd>
          </div>
          <div className="summary-row">
            <dt>Waiting to be claimed</dt>
            <dd className="lend-dd-action">
              {units(row.pending)}
              {row.pending > 0n && (
                <Button
                  variant="secondary"
                  className="lend-small"
                  disabled={busy}
                  loading={loading("claim")}
                  onClick={() =>
                    void act(key("claim"), claimUnitsCall(maturity), `${fmtMusd(row.pending)} units for ${date} are in your wallet.`)
                  }
                >
                  Claim units
                </Button>
              )}
            </dd>
            <p className="lend-help">Units from your filled offers are minted when you claim them.</p>
          </div>
          {claim.units > 0n && (
            <div className="summary-row">
              <dt>In your withdrawal</dt>
              <dd>
                {units(claim.units)} units, {units(claim.musdPaid)} MUSD and {fmtBtcAmount(claim.btcPaid)} BTC paid so far
              </dd>
            </div>
          )}
          <div className="summary-row">
            <dt>Collected for this date</dt>
            <dd>
              {units(market.collectedMusd)} MUSD and {fmtBtcAmount(market.collectedBtc)} BTC of {units(market.faceTotal)} MUSD due
            </dd>
          </div>
          <div className="summary-row">
            <dt>Value of one unit now</dt>
            <dd>
              {fmtPerUnit(perUnit.musd)} MUSD + {fmtPerUnit(perUnit.btc)} BTC
            </dd>
          </div>
        </dl>

        {hasActions && (
          <div className="lend-actions">
            {state === "open" && row.balance > 0n && (
              <Button
                variant="secondary"
                className="lend-small"
                disabled={busy}
                onClick={() => setPanel((current) => (current === "send" ? null : "send"))}
              >
                Send units
              </Button>
            )}

            {(state === "due" || state === "closeable") && row.balance > 0n && (
              <Button variant="secondary" className="lend-small" disabled={busy} onClick={() => setPanel("withdraw")}>
                Withdraw what&apos;s collected
              </Button>
            )}

            {(state === "due" || state === "closeable") && hasWaiting && (
              <Button
                variant="secondary"
                className="lend-small"
                disabled={busy}
                loading={loading("more")}
                onClick={() =>
                  void act(
                    key("more"),
                    withdrawCollectedCall(maturity, 0n),
                    `You withdrew ${fmtMusd(waiting.musd)} MUSD and ${fmtBtcAmount(waiting.btc)} BTC.`,
                  )
                }
              >
                Withdraw the new part
              </Button>
            )}

            {state === "closeable" && (
              <Button
                variant="secondary"
                className="lend-small"
                disabled={busy}
                loading={loading("finalize")}
                onClick={() => void act(key("finalize"), finalizeCall(maturity), `${date} is closed.`)}
              >
                Close this date
              </Button>
            )}

            {state === "final" && row.balance > 0n && (
              <Button
                className="lend-small"
                disabled={busy}
                loading={loading("redeem")}
                onClick={() =>
                  void act(
                    key("redeem"),
                    redeemCall(maturity, row.balance),
                    `You received ${fmtMusd(redeem.musd)} MUSD and ${fmtBtcAmount(redeem.btc)} BTC.`,
                  )
                }
              >
                {`Redeem ${fmtMusd(row.balance)} units`}
              </Button>
            )}

            {state === "final" && hasWaiting && (
              <Button
                variant="secondary"
                className="lend-small"
                disabled={busy}
                loading={loading("more")}
                onClick={() =>
                  void act(
                    key("more"),
                    withdrawCollectedCall(maturity, 0n),
                    `You withdrew ${fmtMusd(waiting.musd)} MUSD and ${fmtBtcAmount(waiting.btc)} BTC.`,
                  )
                }
              >
                Withdraw the rest
              </Button>
            )}

            {(state === "due" || state === "closeable") && hasWaiting && (
              <p className="lend-action-note">
                Waiting for you: {fmtMusd(waiting.musd)} MUSD and {fmtBtcAmount(waiting.btc)} BTC
              </p>
            )}
            {state === "final" && row.balance > 0n && (
              <p className="lend-action-note">
                You get {fmtMusd(redeem.musd)} MUSD and {fmtBtcAmount(redeem.btc)} BTC
              </p>
            )}
            {state === "final" && hasWaiting && (
              <p className="lend-action-note">
                Still owed from your withdrawal: {fmtMusd(waiting.musd)} MUSD and {fmtBtcAmount(waiting.btc)} BTC
              </p>
            )}
            {state === "closeable" && (
              <p className="lend-action-note">Anyone can close a date once its last loan has ended.</p>
            )}
          </div>
        )}

        {panel === "send" && (
          <SendForm row={row} address={address} act={act} busy={busy} runningKey={runningKey} onClose={() => setPanel(null)} />
        )}
      </motion.article>
      {panel === "withdraw" && (
        <WithdrawSheet row={row} act={act} busy={busy} runningKey={runningKey} onClose={() => setPanel(null)} />
      )}
    </>
  );
}

type UnitsCardsProps = Shared & {
  state: ListState;
  rows: readonly DateUnits[];
  now: number;
  address: Address | undefined;
};

export function UnitsCards({ state, rows, now, address, act, busy, runningKey }: UnitsCardsProps) {
  if (state === "connect" || address === undefined) {
    return <p className="lend-empty">Connect a wallet to see your offers and units.</p>;
  }
  if (state === "loading") {
    return (
      <div aria-busy="true" className="lend-cards">
        {[0, 1].map((slot) => (
          <span key={slot} className="lend-card-skeleton shimmer" />
        ))}
      </div>
    );
  }
  if (state === "error") return <p className="lend-empty lend-empty-problem">unavailable, retrying</p>;
  if (rows.length === 0) {
    return <p className="lend-empty">No credit units yet. When a borrower takes your offer, your units appear here.</p>;
  }
  return (
    <div className="lend-cards">
      {rows.map((row) => (
        <UnitsCard key={row.maturity} row={row} now={now} address={address} act={act} busy={busy} runningKey={runningKey} />
      ))}
    </div>
  );
}

"use client";

import { useEffect, useRef, useState } from "react";
import { earnedNumber, formatEarned, offerStatus, type MyOffer, type OfferStatus, type OfferYield } from "../../lib/lend";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatApr, formatDate } from "../../lib/stats";
import { Button } from "../Button";
import { CountValue } from "../CountValue";
import { fmtMusd } from "../borrow/format";
import { StatusChip, type Tone } from "./StatusChip";

const STATUS: Record<OfferStatus, { label: string; tone: Tone }> = {
  open: { label: "Open", tone: "safe" },
  partly: { label: "Partly taken", tone: "safe" },
  taken: { label: "Taken", tone: "neutral" },
  cancelled: { label: "Cancelled", tone: "neutral" },
  expired: { label: "Expired", tone: "watch" },
};

export type ListState = "connect" | "loading" | "error" | "ready";

type OffersTableProps = {
  state: ListState;
  offers: readonly MyOffer[];
  now: number;
  /** The key of the write that is running, so the matching button can show it. */
  runningKey: string | null;
  busy: boolean;
  onCancel: (offer: MyOffer) => void;
  /** What each parked Wave 2 offer has earned, by offer id. Missing while the read is loading or has failed. */
  yields: ReadonlyMap<bigint, OfferYield>;
};

type EarnedTotalProps = {
  /** Null while the yields are loading or could not be read. */
  total: bigint | null;
  disabled: boolean;
  loading: boolean;
  onWithdraw: () => void;
};

/** The sum of what the wallet's parked offers have earned, with the button that pays it out. */
export function EarnedTotal({ total, disabled, loading, onWithdraw }: EarnedTotalProps) {
  const reduced = useReducedMotion();
  return (
    <div className="lend-earned-total">
      <p>
        Earned in sMUSD{" "}
        {total === null ? (
          <span>-</span>
        ) : (
          <CountValue value={earnedNumber(total)} format={formatEarned} reduced={reduced} />
        )}{" "}
        MUSD
      </p>
      <Button variant="secondary" disabled={disabled || total === null || total === 0n} loading={loading} onClick={onWithdraw}>
        Withdraw earnings
      </Button>
    </div>
  );
}

type PopoverProps = {
  offer: MyOffer;
  /** Closes without cancelling. `refocus` is true when the keyboard closed it, so focus goes back to the button. */
  onClose: (refocus: boolean) => void;
  onConfirm: () => void;
};

function CancelPopover({ offer, onClose, onConfirm }: PopoverProps) {
  const ref = useRef<HTMLDivElement>(null);
  const keepRef = useRef<HTMLButtonElement>(null);
  const close = useRef(onClose);
  useEffect(() => {
    close.current = onClose;
  });

  useEffect(() => {
    keepRef.current?.focus();
    const onOutside = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) close.current(false);
    };
    const onEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") close.current(true);
    };
    document.addEventListener("mousedown", onOutside);
    window.addEventListener("keydown", onEscape);
    return () => {
      document.removeEventListener("mousedown", onOutside);
      window.removeEventListener("keydown", onEscape);
    };
  }, []);

  return (
    <div ref={ref} className="lend-popover" role="dialog" aria-label={`Cancel offer #${offer.id}`}>
      <p className="lend-popover-text">
        Cancel offer #{String(offer.id)}? {fmtMusd(offer.remaining)} MUSD comes back to you.
      </p>
      <div className="lend-popover-actions">
        <button ref={keepRef} type="button" className="lend-popover-keep" onClick={() => onClose(true)}>
          Keep it
        </button>
        <button type="button" className="lend-popover-confirm" onClick={onConfirm}>
          Yes, cancel
        </button>
      </div>
    </div>
  );
}

// Offer ids repeat across the two pairs, so a row is named by its pair and id together.
const rowKey = (offer: MyOffer): string => `${offer.pair}:${offer.id}`;

const focusCancelButton = (key: string) =>
  document.querySelector<HTMLButtonElement>(`[data-cancel="${key}"] button`)?.focus();

export function OffersTable({ state, offers, now, runningKey, busy, onCancel, yields }: OffersTableProps) {
  const [askingKey, setAskingKey] = useState<string | null>(null);
  const reduced = useReducedMotion();

  if (state === "connect") return <p className="lend-empty">Connect a wallet to see your offers and units.</p>;
  if (state === "loading") {
    return (
      <div aria-busy="true" className="lend-skeletons">
        {[0, 1, 2].map((slot) => (
          <span key={slot} className="lend-skeleton shimmer" />
        ))}
      </div>
    );
  }
  if (state === "error") return <p className="lend-empty lend-empty-problem">unavailable, retrying</p>;
  if (offers.length === 0) return <p className="lend-empty">No offers from this wallet yet.</p>;

  return (
    <table className="lend-offers">
      <thead>
        <tr>
          <th scope="col">Offer</th>
          <th scope="col">Due</th>
          <th scope="col">Rate</th>
          <th scope="col">Posted</th>
          <th scope="col">Left</th>
          <th scope="col">Earned</th>
          <th scope="col">Status</th>
          <th scope="col">
            <span className="sr-only">Action</span>
          </th>
        </tr>
      </thead>
      <tbody>
        {offers.map((offer) => {
          const status = STATUS[offerStatus(offer, now)];
          const row = rowKey(offer);
          const key = `cancel:${row}`;
          const earned = offer.pair === "wave2" && offer.parked ? yields.get(offer.id) : undefined;
          return (
            <tr key={row}>
              <td data-label="Offer">
                <span>
                  #{String(offer.id)}
                  {offer.pair === "legacy" && (
                    <span
                      className="lend-tag"
                      data-kind="legacy"
                      title="Posted on Doji's 20 October contracts. Cancel works as before."
                    >
                      20 Oct
                    </span>
                  )}
                </span>
              </td>
              <td data-label="Due">{formatDate(offer.maturity)}</td>
              <td data-label="Rate">{formatApr(offer.aprBps / 100)}</td>
              <td data-label="Posted">{fmtMusd(offer.posted)} MUSD</td>
              <td data-label="Left">
                <span>
                  {fmtMusd(offer.remaining)} MUSD
                  {earned?.inVault && (
                    <span className="lend-tag" title="This MUSD is earning in Mezo's sMUSD vault">
                      sMUSD
                    </span>
                  )}
                </span>
              </td>
              <td data-label="Earned">
                {earned === undefined ? (
                  <span className="lend-earned-none">-</span>
                ) : (
                  <span>
                    <CountValue value={earnedNumber(earned.pending)} format={formatEarned} reduced={reduced} /> MUSD
                  </span>
                )}
              </td>
              <td data-label="Status">
                <StatusChip tone={status.tone}>{status.label}</StatusChip>
              </td>
              <td data-label="" className="lend-action">
                {offer.remaining > 0n && (
                  <>
                    <span data-cancel={row}>
                      <Button
                        variant="secondary"
                        className="lend-small"
                        disabled={busy && runningKey !== key}
                        loading={runningKey === key}
                        onClick={() => setAskingKey(row)}
                      >
                        Cancel
                      </Button>
                    </span>
                    {askingKey === row && (
                      <CancelPopover
                        offer={offer}
                        onClose={(refocus) => {
                          setAskingKey(null);
                          if (refocus) focusCancelButton(row);
                        }}
                        onConfirm={() => {
                          setAskingKey(null);
                          onCancel(offer);
                        }}
                      />
                    )}
                  </>
                )}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

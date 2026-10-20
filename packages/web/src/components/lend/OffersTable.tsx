"use client";

import { useEffect, useRef, useState } from "react";
import { offerStatus, type MyOffer, type OfferStatus } from "../../lib/lend";
import { formatApr, formatDate } from "../../lib/stats";
import { Button } from "../Button";
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
};

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

const focusCancelButton = (id: bigint) =>
  document.querySelector<HTMLButtonElement>(`[data-cancel="${String(id)}"] button`)?.focus();

export function OffersTable({ state, offers, now, runningKey, busy, onCancel }: OffersTableProps) {
  const [askingId, setAskingId] = useState<bigint | null>(null);

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
          <th scope="col">Status</th>
          <th scope="col">
            <span className="sr-only">Action</span>
          </th>
        </tr>
      </thead>
      <tbody>
        {offers.map((offer) => {
          const status = STATUS[offerStatus(offer, now)];
          const key = `cancel:${offer.id}`;
          return (
            <tr key={String(offer.id)}>
              <td data-label="Offer">#{String(offer.id)}</td>
              <td data-label="Due">{formatDate(offer.maturity)}</td>
              <td data-label="Rate">{formatApr(offer.aprBps / 100)}</td>
              <td data-label="Posted">{fmtMusd(offer.posted)} MUSD</td>
              <td data-label="Left">{fmtMusd(offer.remaining)} MUSD</td>
              <td data-label="Status">
                <StatusChip tone={status.tone}>{status.label}</StatusChip>
              </td>
              <td data-label="" className="lend-action">
                {offer.remaining > 0n && (
                  <>
                    <span data-cancel={String(offer.id)}>
                      <Button
                        variant="secondary"
                        className="lend-small"
                        disabled={busy && runningKey !== key}
                        loading={runningKey === key}
                        onClick={() => setAskingId(offer.id)}
                      >
                        Cancel
                      </Button>
                    </span>
                    {askingId === offer.id && (
                      <CancelPopover
                        offer={offer}
                        onClose={(refocus) => {
                          setAskingId(null);
                          if (refocus) focusCancelButton(offer.id);
                        }}
                        onConfirm={() => {
                          setAskingId(null);
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

"use client";

import { useEffect, useId, useRef, type ReactNode } from "react";

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])';

type SheetProps = {
  title: string;
  onClose: () => void;
  /** True while a transaction is running: the sheet stays open so the steps stay in view. */
  locked?: boolean;
  children: ReactNode;
};

/** A dialog that is centred on a desktop and rises from the bottom on a phone. */
export function Sheet({ title, onClose, locked = false, children }: SheetProps) {
  const titleId = useId();
  const dialogRef = useRef<HTMLDivElement>(null);
  const latest = useRef({ onClose, locked });

  useEffect(() => {
    latest.current = { onClose, locked };
  });

  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const dialog = dialogRef.current;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";

    const field = dialog?.querySelector<HTMLElement>("input:not([disabled])");
    (field ?? dialog?.querySelector<HTMLElement>(FOCUSABLE))?.focus();

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (!latest.current.locked) latest.current.onClose();
        return;
      }
      if (event.key !== "Tab" || !dialog) return;
      const items = [...dialog.querySelectorAll<HTMLElement>(FOCUSABLE)];
      const first = items[0];
      const last = items[items.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
      document.body.style.overflow = previousOverflow;
      opener?.focus();
    };
  }, []);

  return (
    <div
      className="loan-sheet-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget && !locked) onClose();
      }}
    >
      <div ref={dialogRef} className="loan-sheet" data-lenis-prevent role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <div className="loan-sheet-head">
          <h2 id={titleId} className="loan-sheet-title display-face">
            {title}
          </h2>
          <button type="button" className="loan-sheet-close" disabled={locked} onClick={onClose}>
            Close
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}

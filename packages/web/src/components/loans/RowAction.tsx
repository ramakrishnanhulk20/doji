"use client";

import type { ReactNode } from "react";

type RowActionProps = {
  disabled?: boolean;
  /** This action is the one running now: it dims and ignores clicks. */
  busy?: boolean;
  onClick: () => void;
  children: ReactNode;
};

/** A small text action at the end of a card row. */
export function RowAction({ disabled = false, busy = false, onClick, children }: RowActionProps) {
  return (
    <button
      type="button"
      className="link-draw row-action"
      disabled={disabled || busy}
      aria-busy={busy || undefined}
      data-busy={busy || undefined}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

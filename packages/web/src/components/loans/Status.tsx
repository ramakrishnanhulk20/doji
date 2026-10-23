"use client";

import { SAFE_SHARE_BPS, type Standing } from "../../lib/loans";
import { TweenText } from "../borrow/TweenText";

const CHIPS: Record<Standing, { label: string; mark: "circle" | "diamond" | "square" | "ring"; tone: "safe" | "watch" | "auction" | "dim" }> = {
  safe: { label: "Safe", mark: "circle", tone: "safe" },
  close: { label: "Close to the limit", mark: "diamond", tone: "watch" },
  auction: { label: "In auction", mark: "square", tone: "auction" },
  overdue: { label: "Overdue", mark: "diamond", tone: "watch" },
  none: { label: "No loan", mark: "ring", tone: "dim" },
  unknown: { label: "Price unavailable", mark: "ring", tone: "dim" },
};

/** A status in words with a shape, so it never depends on colour alone. */
export function StatusChip({ standing }: { standing: Standing }) {
  const chip = CHIPS[standing];
  return (
    <span className="status-chip" data-tone={chip.tone}>
      <span className="status-mark" data-mark={chip.mark} aria-hidden="true" />
      {chip.label}
    </span>
  );
}

type LimitBarProps = {
  /** Share of the auction line the debt has used, in basis points of the line. Null while the value is unknown. */
  usedBps: number | null;
  label: string;
};

export function LimitBar({ usedBps, label }: LimitBarProps) {
  return (
    <div className="loan-limit">
      <div className="loan-limit-text">
        <span className="loan-limit-label">{label}</span>
        <span className="loan-limit-value">
          {usedBps === null ? (
            <span className="loan-unavailable">unavailable</span>
          ) : (
            <TweenText value={usedBps / 100} format={(value) => `${value.toFixed(1)}% of the way there`} />
          )}
        </span>
      </div>
      <div className="limit-track" aria-hidden="true">
        <div
          className="limit-fill"
          data-over={usedBps !== null && usedBps > SAFE_SHARE_BPS}
          style={{ width: `${Math.min(100, (usedBps ?? 0) / 100)}%` }}
        />
      </div>
    </div>
  );
}

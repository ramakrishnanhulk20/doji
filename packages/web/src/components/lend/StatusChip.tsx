import type { ReactNode } from "react";

/** Safe and watch come from the status palette. Neutral is for things that are over and need nothing from the lender. */
export type Tone = "safe" | "watch" | "neutral";

/** A status word with a small mark, so the meaning never rests on colour alone. */
export function StatusChip({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span className="lend-chip" data-tone={tone}>
      <span className="lend-chip-mark" aria-hidden="true" />
      {children}
    </span>
  );
}

"use client";

import { useEffect, useRef, type RefObject } from "react";

const COUNT_MS = 1100;

type CountValueProps = {
  value: number;
  format: (value: number) => string;
  /** Milliseconds after `since` before the count may start, so it plays while the value is visible. */
  startAfterMs?: number;
  /** The moment startAfterMs counts from, on the performance.now() clock. Defaults to the moment the value becomes active. */
  since?: RefObject<number | null>;
  reduced: boolean;
  /** The count waits until this is true, for values that load before they scroll into view. */
  active?: boolean;
};

// The count writes straight to the text node on each animation frame, so React never re-renders for it. The first
// time a value loads it counts up from zero; later polls only update the text. Before the count the final value sits
// hidden in place, so no 0 is ever shown that is not the first frame of a count. The count's start is its first
// frame's timestamp, because that timestamp can be earlier than any clock read before it, which would make the first
// frame negative.
export function CountValue({ value, format, startAfterMs = 0, since, reduced, active = true }: CountValueProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const formatRef = useRef(format);
  const anchor = useRef<number | null>(null);
  const phase = useRef<"waiting" | "counting" | "done">("waiting");

  useEffect(() => {
    formatRef.current = format;
  });

  useEffect(() => {
    const element = ref.current;
    if (!element) return;

    const show = (n: number) => {
      element.textContent = formatRef.current(n);
      element.style.visibility = "";
    };

    if (phase.current !== "waiting" || reduced) {
      phase.current = "done";
      show(value);
      return;
    }

    element.textContent = formatRef.current(value);
    element.style.visibility = "hidden";
    if (!active) return;

    anchor.current ??= since?.current ?? performance.now();

    let frame = 0;
    const timer = window.setTimeout(
      () => {
        phase.current = "counting";
        let start: number | null = null;
        const step = (now: number) => {
          start ??= now;
          const progress = Math.min(1, (now - start) / COUNT_MS);
          show(value * (1 - Math.pow(1 - progress, 3)));
          if (progress < 1) frame = requestAnimationFrame(step);
          else phase.current = "done";
        };
        frame = requestAnimationFrame(step);
      },
      Math.max(0, anchor.current + startAfterMs - performance.now()),
    );

    return () => {
      window.clearTimeout(timer);
      cancelAnimationFrame(frame);
    };
  }, [value, reduced, startAfterMs, active, since]);

  return <span ref={ref} />;
}

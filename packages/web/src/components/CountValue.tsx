"use client";

import { useEffect, useRef } from "react";

const COUNT_MS = 1100;

type CountValueProps = {
  value: number;
  format: (value: number) => string;
  /** Milliseconds after mount before the count may start, so it plays while the value is visible. */
  startAfterMs?: number;
  reduced: boolean;
  /** The count waits until this is true, for values that load before they scroll into view. */
  active?: boolean;
};

// The count writes straight to the text node on each animation frame, so React never re-renders for it. The first
// time a value loads it counts up from zero; later polls only update the text.
export function CountValue({ value, format, startAfterMs = 0, reduced, active = true }: CountValueProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const mountedAt = useRef(0);
  const formatRef = useRef(format);
  const hasCounted = useRef(false);

  useEffect(() => {
    mountedAt.current = performance.now();
  }, []);

  useEffect(() => {
    formatRef.current = format;
  });

  useEffect(() => {
    const element = ref.current;
    if (!element) return;

    if (hasCounted.current || reduced) {
      hasCounted.current = true;
      element.textContent = formatRef.current(value);
      return;
    }

    element.textContent = formatRef.current(0);
    if (!active) return;

    let frame = 0;
    const wait = Math.max(0, startAfterMs - (performance.now() - mountedAt.current));
    const timer = window.setTimeout(() => {
      const start = performance.now();
      const step = (now: number) => {
        const progress = Math.min(1, (now - start) / COUNT_MS);
        element.textContent = formatRef.current(value * (1 - Math.pow(1 - progress, 3)));
        if (progress < 1) frame = requestAnimationFrame(step);
        else hasCounted.current = true;
      };
      frame = requestAnimationFrame(step);
    }, wait);

    return () => {
      window.clearTimeout(timer);
      cancelAnimationFrame(frame);
    };
  }, [value, reduced, startAfterMs, active]);

  return <span ref={ref} />;
}

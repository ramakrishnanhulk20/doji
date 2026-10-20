"use client";

import { useEffect, useRef } from "react";
import { useReducedMotion } from "../../lib/motion-mode";

const TWEEN_MS = 200;

type TweenTextProps = {
  value: number;
  format: (value: number) => string;
};

// The number moves to its new value over 200ms by writing the text node, so React does not render for each frame.
export function TweenText({ value, format }: TweenTextProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const shown = useRef(value);
  const formatRef = useRef(format);
  const reduced = useReducedMotion();

  useEffect(() => {
    formatRef.current = format;
  });

  useEffect(() => {
    const element = ref.current;
    if (!element) return;
    if (reduced || shown.current === value) {
      shown.current = value;
      element.textContent = formatRef.current(value);
      return;
    }

    const from = shown.current;
    const start = performance.now();
    let frame = 0;
    const step = (now: number) => {
      const progress = Math.min(1, (now - start) / TWEEN_MS);
      const next = from + (value - from) * progress;
      shown.current = next;
      element.textContent = formatRef.current(next);
      if (progress < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [value, reduced]);

  return <span ref={ref} />;
}

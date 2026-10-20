"use client";

import { useEffect, useState } from "react";

const nowSeconds = () => Math.floor(Date.now() / 1000);

/** The current time in unix seconds, refreshed every `everyMs`. */
export function useLoanClock(everyMs: number): number {
  const [now, setNow] = useState(nowSeconds);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(nowSeconds()), everyMs);
    return () => window.clearInterval(timer);
  }, [everyMs]);
  return now;
}

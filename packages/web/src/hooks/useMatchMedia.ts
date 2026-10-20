"use client";

import { useSyncExternalStore } from "react";

/** Follows a CSS media query. False on the server, so the first paint matches the server's HTML. */
export function useMatchMedia(query: string): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const list = window.matchMedia(query);
      list.addEventListener("change", onChange);
      return () => list.removeEventListener("change", onChange);
    },
    () => window.matchMedia(query).matches,
    () => false,
  );
}

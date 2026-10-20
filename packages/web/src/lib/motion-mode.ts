"use client";

import { useSyncExternalStore } from "react";

export type MotionMode = "full" | "reduced";

const QUERY = "(prefers-reduced-motion: reduce)";

function subscribeToPreference(onChange: () => void) {
  const list = window.matchMedia(QUERY);
  list.addEventListener("change", onChange);
  return () => list.removeEventListener("change", onChange);
}

/** True when the visitor's system asks for reduced motion. False on the server, so the first paint matches. */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(
    subscribeToPreference,
    () => window.matchMedia(QUERY).matches,
    () => false,
  );
}

// The lab's Motion switch lives far from the smooth-scroll provider, so the choice is shared through this store.
let override: MotionMode = "full";
const listeners = new Set<() => void>();

export function setMotionOverride(mode: MotionMode) {
  if (mode === override) return;
  override = mode;
  listeners.forEach((listener) => listener());
}

function subscribeToOverride(onChange: () => void) {
  listeners.add(onChange);
  return () => {
    listeners.delete(onChange);
  };
}

/** Reduced when the system asks for it or the lab switch forces it. */
export function useReducedMotion(): boolean {
  const prefers = usePrefersReducedMotion();
  const forced = useSyncExternalStore(
    subscribeToOverride,
    () => override === "reduced",
    () => false,
  );
  return prefers || forced;
}

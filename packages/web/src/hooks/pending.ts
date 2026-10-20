"use client";

import { useSyncExternalStore } from "react";
import type { Hex } from "viem";

/** The one transaction that was sent and has not been confirmed or reverted yet. */
export type PendingConfirmation = {
  toastId: string;
  hash: Hex;
  /** True once ten minutes of asking found nothing. It may still be mined: the screens keep waiting for it. */
  stalled: boolean;
  successLine: string;
};

let pending: PendingConfirmation | null = null;
const listeners = new Set<() => void>();

export function setPending(next: PendingConfirmation | null) {
  pending = next;
  listeners.forEach((listener) => listener());
}

export const getPending = (): PendingConfirmation | null => pending;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export function usePendingConfirmation(): PendingConfirmation | null {
  return useSyncExternalStore(subscribe, () => pending, () => null);
}

"use client";

import { useSyncExternalStore } from "react";

let open = false;
let opener: HTMLElement | null = null;
const listeners = new Set<() => void>();

function publish(next: boolean) {
  open = next;
  listeners.forEach((listener) => listener());
}

/** Opens the connect modal from anywhere and remembers what had focus, so focus can go back to it. */
export function openConnectModal() {
  opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  publish(true);
}

export function closeConnectModal() {
  publish(false);
  opener?.focus();
  opener = null;
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

export function useConnectModalOpen(): boolean {
  return useSyncExternalStore(subscribe, () => open, () => false);
}

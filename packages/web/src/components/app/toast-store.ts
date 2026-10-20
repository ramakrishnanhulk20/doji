"use client";

import { useSyncExternalStore } from "react";

export type Toast = {
  id: string;
  kind: "wallet" | "sending" | "done" | "problem";
  title: string;
  detail?: string;
  /** Explorer link for the transaction, when there is one. */
  href?: string;
};

const DONE_CLOSES_AFTER_MS = 8_000;

let toasts: readonly Toast[] = [];
const listeners = new Set<() => void>();
const timers = new Map<string, number>();

function publish(next: readonly Toast[]) {
  toasts = next;
  listeners.forEach((listener) => listener());
}

export function dismissToast(id: string) {
  const timer = timers.get(id);
  if (timer !== undefined) {
    window.clearTimeout(timer);
    timers.delete(id);
  }
  publish(toasts.filter((toast) => toast.id !== id));
}

/** Adds a toast, or replaces the one with the same id so a transaction keeps a single card through its stages. */
export function showToast(toast: Toast) {
  const existing = timers.get(toast.id);
  if (existing !== undefined) {
    window.clearTimeout(existing);
    timers.delete(toast.id);
  }
  const index = toasts.findIndex((candidate) => candidate.id === toast.id);
  publish(index === -1 ? [...toasts, toast] : toasts.map((candidate) => (candidate.id === toast.id ? toast : candidate)));
  if (toast.kind === "done") {
    timers.set(
      toast.id,
      window.setTimeout(() => dismissToast(toast.id), DONE_CLOSES_AFTER_MS),
    );
  }
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};

const noToasts: readonly Toast[] = [];

export function useToasts(): readonly Toast[] {
  return useSyncExternalStore(subscribe, () => toasts, () => noToasts);
}

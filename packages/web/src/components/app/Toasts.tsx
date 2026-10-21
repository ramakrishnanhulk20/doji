"use client";

import { useEffect, useRef } from "react";
import { dismissToast, useToasts } from "./toast-store";
import { Seal } from "../Seal";

/** A Done toast closes by itself. Sending and Failed stay until the person closes them. */
const DONE_CLOSES_AFTER_MS = 4_000;

export function Toasts() {
  const toasts = useToasts();
  const timers = useRef(new Map<string, number>());

  useEffect(() => {
    const open = new Set(toasts.filter((toast) => toast.kind === "done").map((toast) => toast.id));
    for (const id of open) {
      if (timers.current.has(id)) continue;
      timers.current.set(
        id,
        window.setTimeout(() => {
          timers.current.delete(id);
          dismissToast(id);
        }, DONE_CLOSES_AFTER_MS),
      );
    }
    for (const [id, timer] of timers.current) {
      if (open.has(id)) continue;
      window.clearTimeout(timer);
      timers.current.delete(id);
    }
  }, [toasts]);

  useEffect(() => {
    const pending = timers.current;
    return () => {
      pending.forEach((timer) => window.clearTimeout(timer));
      pending.clear();
    };
  }, []);

  return (
    <div className="toasts" role="region" aria-label="Transaction status" aria-live="polite">
      {toasts.map((toast) => (
        <div key={toast.id} className="toast" data-kind={toast.kind}>
          <span className="toast-mark" aria-hidden="true">
            {toast.kind === "wallet" || toast.kind === "sending" || toast.kind === "stalled" ? (
              <Seal size={20} title="" busy />
            ) : toast.kind === "done" ? (
              <span className="toast-circle" />
            ) : (
              <span className="toast-diamond" />
            )}
          </span>
          <div className="toast-body">
            <p className="toast-title">{toast.title}</p>
            {toast.detail && <p className="toast-detail">{toast.detail}</p>}
            {toast.href && (
              <a className="link-draw toast-link" href={toast.href} target="_blank" rel="noopener noreferrer">
                View transaction
              </a>
            )}
            {toast.action && (
              <button type="button" className="toast-action" onClick={toast.action.run}>
                {toast.action.label}
              </button>
            )}
          </div>
          <button type="button" className="toast-close" aria-label="Close" onClick={() => dismissToast(toast.id)}>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
              <path d="M2.5 2.5 9.5 9.5M9.5 2.5 2.5 9.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      ))}
    </div>
  );
}

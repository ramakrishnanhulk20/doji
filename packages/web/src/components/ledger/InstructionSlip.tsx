"use client";

import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import type { Hex } from "viem";
import type { QuestId } from "../../lib/quests/table";
import { Button } from "../Button";
import { Seal } from "../Seal";
import { QUEST_COPY, QUEST_FACTS, explorerTx, ledgerDate, sealTilt } from "./chapters";
import { ClaimKit } from "./ClaimKit";
import { PaperSheet } from "./PaperSheet";
import "./ledger.css";

type InstructionSlipProps = {
  id: QuestId;
  open: boolean;
  onClose: () => void;
  done: boolean;
  /** Unix seconds of the block that proved the quest. */
  at?: number;
  hash?: Hex;
  /** Someone else's ledger: the steps show and nothing here acts (C76). */
  readOnly?: boolean;
};

const FOCUSABLE = 'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function InstructionSlip({ id, open, onClose, done, at, hash, readOnly = false }: InstructionSlipProps) {
  const titleId = useId();
  const panelRef = useRef<HTMLDivElement>(null);
  const openerRef = useRef<HTMLElement | null>(null);
  // The slip is in the page before it opens. It flips to "open" one frame later so the slide has something to move from.
  const [shown, setShown] = useState(false);

  const copy = QUEST_COPY[id];
  const facts = QUEST_FACTS[id];
  const date = done && at !== undefined ? ledgerDate(at) : null;

  useEffect(() => {
    if (!open) {
      setShown(false);
      return;
    }
    openerRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    // Two frames: the first lets the browser paint the closed position, the second starts the slide.
    let second = 0;
    const first = window.requestAnimationFrame(() => {
      second = window.requestAnimationFrame(() => setShown(true));
    });
    return () => {
      window.cancelAnimationFrame(first);
      window.cancelAnimationFrame(second);
      openerRef.current?.focus({ preventScroll: true });
    };
  }, [open]);

  // A hidden element cannot take focus, so focus moves in only once the slip is showing.
  useEffect(() => {
    if (shown) panelRef.current?.querySelector<HTMLElement>(FOCUSABLE)?.focus({ preventScroll: true });
  }, [shown]);

  useEffect(() => {
    if (!open) return;
    const panel = panelRef.current;

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
        return;
      }
      if (event.key !== "Tab" || !panel) return;
      const items = [...panel.querySelectorAll<HTMLElement>(FOCUSABLE)];
      const first = items[0];
      const last = items[items.length - 1];
      if (!first || !last) return;
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  const tilt = { "--tilt": `${sealTilt({ hash, position: 0 })}deg` } as CSSProperties;

  return (
    <div className="ledger ledger-slip-root" data-state={shown ? "open" : "closed"} inert={!open}>
      <div className="ledger-slip-scrim" onClick={onClose} aria-hidden="true" />
      <div
        ref={panelRef}
        className="ledger-slip-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        data-lenis-prevent
      >
        <PaperSheet className="ledger-slip">
          <div className="ledger-slip-scroll">
            <button type="button" className="ledger-slip-close" onClick={onClose}>
              Close
            </button>
            <span className="ledger-slip-glyph">
              <span className="ledger-slip-kanji" lang="ja" aria-hidden="true">
                {facts.kanji}
              </span>
              {done && (
                <span className="ledger-slip-seal" style={tilt}>
                  <Seal size={64} title="" />
                </span>
              )}
            </span>
            <h2 id={titleId} className="ledger-slip-title display-face">
              {copy.title}
            </h2>
            <p className="ledger-slip-exp">{facts.expLabel}</p>

            {done && (
              <div className="ledger-slip-done">
                <p className="ledger-slip-done-line">{date === null ? "Done" : `Done on ${date}`}</p>
                {hash !== undefined && (
                  <a className="link-draw" href={explorerTx(hash)} target="_blank" rel="noopener noreferrer">
                    See the transaction
                  </a>
                )}
              </div>
            )}

            <hr className="ledger-slip-rule" />
            <ol className="ledger-slip-steps">
              {copy.steps.map((step, index) => (
                <li key={step}>
                  <span className="ledger-slip-step-number">{index + 1}</span>
                  <span>{step}</span>
                </li>
              ))}
            </ol>

            <p className="ledger-slip-label">What you need</p>
            <p className="ledger-slip-need">{copy.need}</p>

            {!readOnly && !done && id === "kit" && <ClaimKit open={open} />}
            {!readOnly && !done && id !== "kit" && (
              <Button variant="primary" arrow href={copy.button.href} className="ledger-slip-button">
                {copy.button.label}
              </Button>
            )}
          </div>
        </PaperSheet>
      </div>
    </div>
  );
}

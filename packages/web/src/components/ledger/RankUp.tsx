"use client";

import { useEffect, useId, useRef, useState, type CSSProperties } from "react";
import type { Address } from "viem";
import { useReducedMotion } from "../../lib/motion-mode";
import type { RankId } from "../../lib/quests/ranks";
import { Button } from "../Button";
import { PaperSheet } from "./PaperSheet";
import { RANK_TEXT } from "./rank-names";
import { RankSeal } from "./RankSeal";
import { StampPress } from "./StampPress";
import "./ledger.css";

type RankUpProps = {
  rank: RankId;
  /** The wallet that rose, already parsed. */
  address: Address;
  onClose: () => void;
};

const FOCUSABLE = 'a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])';
const STAMP_AFTER_MS = 200;
const SEAL_SIZE = 280;
const SEAL_TILT = { "--tilt": "-3deg" } as CSSProperties;

// A fixed origin, never the page address, so a look-alike domain cannot end up in the post.
const SITE_URL = "https://www.dojis.site";

function shareUrl(name: string, meaning: string, address: Address): string {
  const text = encodeURIComponent(`I reached ${name}, ${meaning}, in the Doji ledger.`);
  const page = encodeURIComponent(`${SITE_URL}/quests/${address}`);
  return `https://x.com/intent/post?text=${text}&url=${page}`;
}

/** Fills the screen when a wallet reaches a new rank. */
export function RankUp({ rank, address, onClose }: RankUpProps) {
  const titleId = useId();
  const reduced = useReducedMotion();
  const rootRef = useRef<HTMLDivElement>(null);
  const [stamped, setStamped] = useState(false);
  const { name, meaning } = RANK_TEXT[rank];

  useEffect(() => {
    const timer = window.setTimeout(() => setStamped(true), STAMP_AFTER_MS);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    rootRef.current?.querySelector<HTMLElement>(FOCUSABLE)?.focus({ preventScroll: true });
    return () => opener?.focus({ preventScroll: true });
  }, []);

  useEffect(() => {
    const root = rootRef.current;

    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        // The slip listens on the window too, and a slip underneath must stay open.
        event.stopPropagation();
        onClose();
        return;
      }
      if (event.key !== "Tab" || !root) return;
      const items = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)];
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
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [onClose]);

  const share = () => window.open(shareUrl(name, meaning, address), "_blank", "noopener,noreferrer");

  return (
    <div ref={rootRef} className="ledger ledger-rankup" role="dialog" aria-modal="true" aria-labelledby={titleId} data-lenis-prevent>
      <div className="ledger-rankup-body">
        <PaperSheet className="ledger-sheet ledger-rankup-sheet" style={SEAL_TILT}>
          <StampPress stamped={stamped || reduced} reduced={reduced}>
            <RankSeal rank={rank} size={SEAL_SIZE} />
          </StampPress>
        </PaperSheet>
        <h2 id={titleId} className="ledger-rankup-title display-face">
          You are now {name}
        </h2>
        <p className="ledger-rankup-meaning">{meaning}.</p>
        <div className="ledger-rankup-actions">
          <Button variant="primary" onClick={share}>
            Share on X
          </Button>
          <Button variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      </div>
    </div>
  );
}

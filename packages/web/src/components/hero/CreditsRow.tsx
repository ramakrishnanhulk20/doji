"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useLiveStats } from "../../hooks/useLiveStats";
import { cssVars } from "../../lib/css-vars";
import { formatApr, formatBlock, formatBtc, formatDate, formatMusd, formatUsdCompact } from "../../lib/stats";
import { CREDIT_TIPS } from "./copy";

const COUNT_MS = 1100;
const COLUMN_START_MS = 1500;
const COLUMN_STEP_MS = 90;
const NBSP = " ";

type ReadState = "loading" | "error" | "ready";

function readState(query: { data: unknown; isError: boolean }): ReadState {
  if (query.data !== undefined) return "ready";
  return query.isError ? "error" : "loading";
}

type CountValueProps = {
  value: number;
  format: (value: number) => string;
  /** Milliseconds after the hero mounted before the count may start, so it plays while the column is visible. */
  startAfterMs: number;
  reduced: boolean;
};

// The count writes straight to the text node on each animation frame, so React never re-renders for it.
function CountValue({ value, format, startAfterMs, reduced }: CountValueProps) {
  const ref = useRef<HTMLSpanElement>(null);
  const mountedAt = useRef(0);
  const formatRef = useRef(format);
  const hasCounted = useRef(false);

  useEffect(() => {
    mountedAt.current = performance.now();
  }, []);

  useEffect(() => {
    formatRef.current = format;
  });

  useEffect(() => {
    const element = ref.current;
    if (!element) return;

    if (hasCounted.current || reduced) {
      hasCounted.current = true;
      element.textContent = formatRef.current(value);
      return;
    }

    element.textContent = formatRef.current(0);
    let frame = 0;
    const wait = Math.max(0, startAfterMs - (performance.now() - mountedAt.current));
    const timer = window.setTimeout(() => {
      const start = performance.now();
      const step = (now: number) => {
        const progress = Math.min(1, (now - start) / COUNT_MS);
        element.textContent = formatRef.current(value * (1 - Math.pow(1 - progress, 3)));
        if (progress < 1) frame = requestAnimationFrame(step);
        else hasCounted.current = true;
      };
      frame = requestAnimationFrame(step);
    }, wait);

    return () => {
      window.clearTimeout(timer);
      cancelAnimationFrame(frame);
    };
  }, [value, reduced, startAfterMs]);

  return <span ref={ref} />;
}

type CreditProps = {
  index: number;
  open: boolean;
  onOpenChange: (index: number | null) => void;
  label: string;
  tip: string;
  value: ReactNode;
  source: ReactNode;
  lead?: ReactNode;
};

function Credit({ index, open, onOpenChange, label, tip, value, source, lead }: CreditProps) {
  const tipId = useId();

  return (
    <div
      className="credit enter"
      style={cssVars({ "--delay": `${COLUMN_START_MS + index * COLUMN_STEP_MS}ms`, "--rise": "12px" })}
      tabIndex={0}
      aria-describedby={tipId}
      onPointerEnter={(event) => event.pointerType === "mouse" && onOpenChange(index)}
      onPointerLeave={(event) => event.pointerType === "mouse" && onOpenChange(null)}
      onPointerDown={(event) => event.pointerType !== "mouse" && onOpenChange(open ? null : index)}
      onFocus={() => onOpenChange(index)}
      onBlur={() => onOpenChange(null)}
    >
      <div className="credit-value">
        {lead}
        {value}
      </div>
      <div className="credit-label">{label}</div>
      <div className="credit-source">{source}</div>
      <div id={tipId} role="tooltip" className="credit-tip" data-open={open}>
        {tip}
      </div>
    </div>
  );
}

const loadingBar = (
  <span className="credit-bar shimmer" role="status">
    <span className="sr-only">Loading</span>
  </span>
);
const loadingSource = <span className="credit-bar-source shimmer" aria-hidden="true" />;
const unavailable = <span className="credit-unavailable">unavailable</span>;

export function CreditsRow({ reduced }: { reduced: boolean }) {
  const { locked, offers, block } = useLiveStats();
  const [openIndex, setOpenIndex] = useState<number | null>(null);
  const [pulse, setPulse] = useState(0);
  const seenFirstBlock = useRef(false);

  useEffect(() => {
    if (openIndex === null) return;
    const closeOnOutsideTap = (event: PointerEvent) => {
      if (!(event.target instanceof Element) || !event.target.closest(".credit")) setOpenIndex(null);
    };
    document.addEventListener("pointerdown", closeOnOutsideTap);
    return () => document.removeEventListener("pointerdown", closeOnOutsideTap);
  }, [openIndex]);

  // The dot answers every block after the first one it shows.
  useEffect(() => {
    if (block.data === undefined) return;
    if (!seenFirstBlock.current) {
      seenFirstBlock.current = true;
      return;
    }
    setPulse((count) => count + 1);
  }, [block.data]);

  const startAfter = (index: number) => COLUMN_START_MS + index * COLUMN_STEP_MS + 150;

  const lockedState = readState(locked);
  const offersState = readState(offers);
  const blockState = readState(block);

  const lockedValue =
    lockedState === "ready" && locked.data ? (
      <>
        <CountValue value={locked.data.btc} format={formatBtc} startAfterMs={startAfter(0)} reduced={reduced} />
        {NBSP}BTC
      </>
    ) : lockedState === "error" ? (
      unavailable
    ) : (
      loadingBar
    );

  const lockedSource =
    lockedState === "ready" && locked.data
      ? locked.data.usd === null
        ? "oracle price unavailable · mainnet"
        : `about ${formatUsdCompact(locked.data.usd)} at the oracle price · mainnet`
      : lockedState === "error"
        ? "retrying"
        : loadingSource;

  const offersValue =
    offersState === "ready" && offers.data ? (
      <>
        <CountValue
          value={offers.data.musdOnOffer}
          format={formatMusd}
          startAfterMs={startAfter(1)}
          reduced={reduced}
        />
        {NBSP}MUSD
      </>
    ) : offersState === "error" ? (
      unavailable
    ) : (
      loadingBar
    );

  const offersSource = offersState === "error" ? "retrying" : "lenders' open offers · testnet";

  const best = offers.data?.best ?? null;
  const rateValue =
    offersState === "ready" && offers.data ? (
      best ? (
        <CountValue
          value={best.aprBps / 100}
          format={formatApr}
          startAfterMs={startAfter(2)}
          reduced={reduced}
        />
      ) : (
        "none"
      )
    ) : offersState === "error" ? (
      unavailable
    ) : (
      loadingBar
    );

  const rateSource =
    offersState === "ready" && offers.data
      ? best
        ? `to ${formatDate(best.maturity)} · testnet`
        : "no open offers · testnet"
      : offersState === "error"
        ? "retrying"
        : loadingSource;

  const blockValue =
    blockState === "ready" && block.data !== undefined ? (
      <CountValue value={block.data} format={formatBlock} startAfterMs={startAfter(3)} reduced={reduced} />
    ) : blockState === "error" ? (
      unavailable
    ) : (
      loadingBar
    );

  const blockSource = blockState === "error" ? "retrying" : "Mezo testnet · live";

  const blockLead = (
    <span className="live-dot" aria-hidden="true">
      {pulse > 0 && <span key={pulse} className="live-ring" />}
    </span>
  );

  return (
    <div className="credits">
      <Credit
        index={0}
        open={openIndex === 0}
        onOpenChange={setOpenIndex}
        label="Locked as veBTC on Mezo"
        tip={CREDIT_TIPS[0]}
        value={lockedValue}
        source={lockedSource}
      />
      <Credit
        index={1}
        open={openIndex === 1}
        onOpenChange={setOpenIndex}
        label="On offer in Doji"
        tip={CREDIT_TIPS[1]}
        value={offersValue}
        source={offersSource}
      />
      <Credit
        index={2}
        open={openIndex === 2}
        onOpenChange={setOpenIndex}
        label="Best fixed rate"
        tip={CREDIT_TIPS[2]}
        value={rateValue}
        source={rateSource}
      />
      <Credit
        index={3}
        open={openIndex === 3}
        onOpenChange={setOpenIndex}
        label="Latest block"
        tip={CREDIT_TIPS[3]}
        value={blockValue}
        source={blockSource}
        lead={blockLead}
      />
    </div>
  );
}

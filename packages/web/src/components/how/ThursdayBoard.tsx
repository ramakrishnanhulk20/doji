"use client";

import Link from "next/link";
import { useThursdayBoard } from "../../hooks/useChainReads";
import { useLiveStats } from "../../hooks/useLiveStats";
import { useMatchMedia } from "../../hooks/useMatchMedia";
import { useInViewOnce } from "../../hooks/useInViewOnce";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatApr, formatBlock, formatDate, formatMusd, type ThursdayCard } from "../../lib/stats";
import { CountValue } from "../CountValue";

const DAY_SECONDS = 86_400;

const formatCount = (value: number) => String(Math.round(value));

function whenText(maturity: number, now: number): string {
  if (maturity <= now) return "closed for new loans";
  const days = Math.ceil((maturity - now) / DAY_SECONDS);
  const sameDay = new Date(maturity * 1000).toISOString().slice(0, 10) === new Date(now * 1000).toISOString().slice(0, 10);
  if (sameDay) return "today";
  return `in ${days} ${days === 1 ? "day" : "days"}`;
}

type CellProps = {
  value: number;
  format: (value: number) => string;
  index: number;
  counting: boolean;
  reduced: boolean;
};

function Cell({ value, format, index, counting, reduced }: CellProps) {
  return <CountValue value={value} format={format} startAfterMs={index * 90} reduced={reduced} active={counting} />;
}

type CardProps = {
  card: ThursdayCard;
  index: number;
  now: number;
  counting: boolean;
  reduced: boolean;
};

function Card({ card, index, now, counting, reduced }: CardProps) {
  const cell = (value: number, format: (v: number) => string) => (
    <Cell value={value} format={format} index={index} counting={counting} reduced={reduced} />
  );

  return (
    <article className="board-card">
      <h3 className="board-date display-face">{formatDate(card.maturity)}</h3>
      <p className="board-sub">{whenText(card.maturity, now)}</p>

      <div className="board-middle">
        {card.bestAprBps === null ? (
          <>
            <p className="board-none">no offers yet</p>
            <Link className="link-draw board-cta" href={`/lend?date=${card.maturity}`}>
              Be the first lender
            </Link>
          </>
        ) : (
          <>
            <div className="board-rate">{cell(card.bestAprBps / 100, formatApr)}</div>
            <p className="board-rate-label">best fixed rate</p>
          </>
        )}
      </div>

      <dl className="board-rows">
        <div className="board-row">
          <dt>on offer</dt>
          <dd>
            {cell(card.musdOnOffer, formatMusd)} MUSD
          </dd>
        </div>
        <div className="board-row">
          <dt>offers</dt>
          <dd>{cell(card.offerCount, formatCount)}</dd>
        </div>
        <div className="board-row">
          <dt>due to lenders</dt>
          <dd>
            {cell(card.lent, formatMusd)} MUSD
          </dd>
        </div>
        <div className="board-row">
          <dt>open loans</dt>
          <dd>{cell(card.openLoans, formatCount)}</dd>
        </div>
      </dl>
    </article>
  );
}

const WEEK_SECONDS = 604_800;

// When the read fails the dates are still known from the calendar; only the values are missing.
function ErrorCard({ maturity, now }: { maturity: number; now: number }) {
  return (
    <article className="board-card">
      <h3 className="board-date display-face">{formatDate(maturity)}</h3>
      <p className="board-sub">{whenText(maturity, now)}</p>
      <div className="board-middle">
        <p className="board-none is-unavailable">unavailable</p>
        <p className="board-rate-label">retrying</p>
      </div>
      <dl className="board-rows">
        {["on offer", "offers", "due to lenders", "open loans"].map((label) => (
          <div key={label} className="board-row">
            <dt>{label}</dt>
            <dd className="is-unavailable">unavailable</dd>
          </div>
        ))}
      </dl>
    </article>
  );
}

function LoadingCard() {
  return (
    <article className="board-card" aria-busy="true">
      <span className="board-bar shimmer" style={{ width: 140 }} role="status">
        <span className="sr-only">Loading</span>
      </span>
      <span className="board-bar shimmer" style={{ width: 90, height: 14, marginTop: 8 }} />
      <div className="board-middle">
        <span className="board-bar shimmer" style={{ width: 150, height: 36 }} />
      </div>
      <div className="board-rows">
        {[0, 1, 2, 3].map((row) => (
          <span key={row} className="board-bar shimmer" style={{ height: 14 }} />
        ))}
      </div>
    </article>
  );
}

export function ThursdayBoard() {
  const board = useThursdayBoard();
  const { block } = useLiveStats();
  const reduced = useReducedMotion();
  const [ref, inView] = useInViewOnce<HTMLDivElement>(0.3);
  // Below 1024px the cards scroll sideways, so the strip needs the keyboard too.
  const scrolls = useMatchMedia("(max-width: 1023px)");
  const now = Math.floor(Date.now() / 1000);

  return (
    <div ref={ref} className="board">
      <div className="board-head">
        <p className="label-mono">Live on Mezo testnet · next four Thursdays</p>
        <span className="board-block">
          <span className="net-dot" aria-hidden="true" />
          {block.data !== undefined ? `block ${formatBlock(block.data)}` : "block"}
        </span>
      </div>

      <div
        className="board-strip"
        tabIndex={scrolls ? 0 : undefined}
        role="group"
        aria-label="The next four Thursdays"
      >
        {board.data !== undefined ? (
          board.data.map((card, index) => (
            <Card key={card.maturity} card={card} index={index} now={now} counting={inView} reduced={reduced} />
          ))
        ) : board.isError ? (
          [1, 2, 3, 4].map((week) => (
            <ErrorCard key={week} maturity={(Math.floor(now / WEEK_SECONDS) + week) * WEEK_SECONDS} now={now} />
          ))
        ) : (
          [0, 1, 2, 3].map((slot) => <LoadingCard key={slot} />)
        )}
      </div>
    </div>
  );
}

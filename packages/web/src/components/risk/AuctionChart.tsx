"use client";

import Link from "next/link";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { useOpenAuctions, useRiskSettings } from "../../hooks/useChainReads";
import { useInViewOnce } from "../../hooks/useInViewOnce";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatMusd, type OpenAuction, type RiskSettings } from "../../lib/stats";
import { SectionHeading } from "../landing/SectionHeading";

const Y_MIN = 40;
const Y_MAX = 105;
const PAD = { left: 12, right: 12, top: 28, bottom: 36 } as const;
const TICK_HOURS = 12;
const CHART_HEIGHT = { desktop: 360, phone: 260 } as const;

type ChartProps = {
  settings: RiskSettings;
  auctions: readonly OpenAuction[];
  width: number;
  height: number;
};

const trim = (value: number) => String(+value.toFixed(2));

function Chart({ settings, auctions, width, height }: ChartProps) {
  const plotW = width - PAD.left - PAD.right;
  const plotH = height - PAD.top - PAD.bottom;
  const durationH = settings.auctionDuration / 3600;
  const xMax = Math.max(durationH, ...auctions.map((a) => a.duration / 3600)) + 24;
  const floor = settings.auctionFloorBps / 100;
  const line = settings.liqLtvBps / 100;
  const limit = settings.maxLtvBps / 100;

  const x = (hours: number) => PAD.left + (Math.min(hours, xMax) / xMax) * plotW;
  const y = (percent: number) => PAD.top + ((Y_MAX - percent) / (Y_MAX - Y_MIN)) * plotH;

  const hourTicks: number[] = [];
  for (let h = 0; h <= xMax; h += TICK_HOURS) hourTicks.push(h);

  const nowSeconds = Date.now() / 1000;
  const bandTop = y(Math.max(floor, line));
  const bandBottom = y(Math.min(floor, line));

  return (
    <svg
      className="chart-svg"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={`The auction price falls from the full value to ${trim(floor)} percent over ${trim(durationH)} hours, then holds.`}
    >
      {hourTicks.map((hours) => (
        <g key={hours}>
          <line x1={x(hours)} x2={x(hours)} y1={PAD.top} y2={PAD.top + plotH} stroke="var(--line)" strokeWidth={1} />
          <text className="chart-text" x={x(hours)} y={height - 12} textAnchor="middle">
            {hours}h
          </text>
        </g>
      ))}

      <rect x={PAD.left} y={bandTop} width={plotW} height={bandBottom - bandTop} fill="var(--beni)" fillOpacity={0.08} />
      <text
        className="chart-text chart-text-strong"
        x={PAD.left + plotW - 8}
        y={(bandTop + bandBottom) / 2 + 4}
        textAnchor="end"
      >
        always above the debt
      </text>

      <line x1={PAD.left} x2={PAD.left + plotW} y1={y(100)} y2={y(100)} stroke="var(--line-strong)" strokeWidth={1} />
      <line x1={PAD.left} x2={PAD.left + plotW} y1={y(floor)} y2={y(floor)} stroke="var(--line-strong)" strokeWidth={1} />
      <line
        x1={PAD.left}
        x2={PAD.left + plotW}
        y1={y(line)}
        y2={y(line)}
        stroke="var(--watch)"
        strokeWidth={1}
        strokeDasharray="4 4"
      />
      <line
        x1={PAD.left}
        x2={PAD.left + plotW}
        y1={y(limit)}
        y2={y(limit)}
        stroke="var(--safe)"
        strokeWidth={1}
        strokeDasharray="4 4"
      />

      <text className="chart-text" x={PAD.left + 6} y={y(100) - 6}>
        {trim(100)}% start
      </text>
      <text className="chart-text" x={PAD.left + 6} y={y(floor) - 6}>
        {trim(floor)}% floor
      </text>
      <text className="chart-text" x={PAD.left + 6} y={y(line) - 6}>
        {trim(line)}% auction line
      </text>
      <text className="chart-text" x={PAD.left + 6} y={y(limit) - 6}>
        {trim(limit)}% borrow limit
      </text>

      <path
        className="chart-price"
        d={`M ${x(0)} ${y(100)} L ${x(durationH)} ${y(floor)} L ${x(xMax)} ${y(floor)}`}
        pathLength={1}
        fill="none"
        stroke="var(--beni)"
        strokeWidth={2.5}
        strokeLinejoin="round"
      />

      {auctions.map((auction) => {
        const floorPercent = (auction.floorPrice / auction.startValue) * 100;
        const nowPercent = (auction.price / auction.startValue) * 100;
        const hoursIn = (nowSeconds - auction.startTime) / 3600;
        return (
          <g key={String(auction.tokenId)}>
            <path
              d={`M ${x(0)} ${y(100)} L ${x(auction.duration / 3600)} ${y(floorPercent)} L ${x(xMax)} ${y(floorPercent)}`}
              fill="none"
              stroke="var(--paper)"
              strokeWidth={1.5}
              strokeLinejoin="round"
            />
            <circle cx={x(Math.max(0, hoursIn))} cy={y(nowPercent)} r={5} fill="var(--paper)" />
          </g>
        );
      })}
    </svg>
  );
}

export function AuctionChart() {
  const settings = useRiskSettings();
  const auctions = useOpenAuctions();
  const reduced = useReducedMotion();
  const [wrapRef, seen] = useInViewOnce<HTMLDivElement>(0.4);
  const frameRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(1000);

  useEffect(() => {
    const frame = frameRef.current;
    if (!frame) return;
    const measure = () => setWidth(Math.max(280, Math.floor(frame.getBoundingClientRect().width)));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(frame);
    return () => observer.disconnect();
  }, []);

  const height = width < 768 ? CHART_HEIGHT.phone : CHART_HEIGHT.desktop;
  const data = settings.data;
  const live = auctions.data ?? [];

  const bar = <span className="inline-bar shimmer" aria-hidden="true" />;
  const gone = <span className="is-unavailable">unavailable</span>;
  const part = (value: string): ReactNode => (data ? value : settings.isError ? gone : bar);

  return (
    <section id="risk" className="section">
      <div className="section-inner">
        <SectionHeading
          label="If a loan goes wrong"
          title="The Bitcoin covers the debt. Always first."
          body="A loan goes to auction if it becomes unsafe or the date passes unpaid. The position is sold in a falling-price auction that starts at its full value. Lenders are paid what they are owed first, the protocol takes a stated penalty, and the borrower keeps everything else."
        />

        <div ref={wrapRef} className="chart-wrap" data-drawn={reduced || seen}>
          <div className="chart-live" aria-live="polite">
            {live.map((auction) => (
              <Link key={String(auction.tokenId)} className="link-draw" href={`/loans/${auction.tokenId}`}>
                Loan {String(auction.tokenId)} is in auction now: {formatMusd(auction.price)} MUSD
              </Link>
            ))}
          </div>
          <div ref={frameRef}>
            {data ? (
              <Chart settings={data} auctions={live} width={width} height={height} />
            ) : settings.isError ? (
              <p className="chart-unavailable" style={{ minHeight: height }}>
                unavailable
              </p>
            ) : (
              <span className="chart-skeleton shimmer" style={{ height }} role="status">
                <span className="sr-only">Loading</span>
              </span>
            )}
          </div>
        </div>

        <ol className="chart-notes">
          <li>
            <span className="chart-note-number">1</span>
            <p className="chart-note-body">
              The price falls from the full value to {part(data ? `${trim(data.auctionFloorBps / 100)}%` : "")} over{" "}
              {part(data ? trim(data.auctionDuration / 3600) : "")} hours, then holds.
            </p>
          </li>
          <li>
            <span className="chart-note-number">2</span>
            <p className="chart-note-body">
              It never falls below what is owed while the Bitcoin still covers it, so nobody can buy a position back
              cheap, and the price rises again if Bitcoin recovers.
            </p>
          </li>
          <li>
            <span className="chart-note-number">3</span>
            <p className="chart-note-body">
              If nobody buys before the lock ends, the lenders receive the Bitcoin itself at the oracle price, and the
              borrower gets the rest back. There is no forced sale on a thin market.
            </p>
          </li>
        </ol>
      </div>
    </section>
  );
}

// The single-loan mode below draws one auction's own curve for the loan page. Its classes live in components/loans/loans.css,
// which the loan page loads; the landing page never renders it.

export type LoanCurve = {
  /** Unix seconds. */
  startTime: number;
  /** Seconds the price takes to fall from the start value to the floor. */
  duration: number;
  /** MUSD. */
  startValue: number;
  /** MUSD. */
  floorPrice: number;
  /** MUSD a buyer pays now. */
  price: number;
  /** MUSD still owed. Drawn only when it falls inside the chart. */
  owed: number;
};

const TICK_STEPS = [1, 2, 3, 6, 12, 24, 48] as const;

function LoanCurveChart({ curve, now, width, height }: { curve: LoanCurve; now: number; width: number; height: number }) {
  if (!(curve.startValue > 0) || !(curve.floorPrice > 0)) return null;
  const plotW = width - PAD.left - PAD.right;
  const plotH = height - PAD.top - PAD.bottom;
  const durationH = curve.duration / 3600;
  const xMax = durationH + 24;
  const yMax = Math.max(curve.startValue, curve.price) * 1.04;
  const yMin = curve.floorPrice * 0.9;
  const hoursIn = Math.min(Math.max(0, (now - curve.startTime) / 3600), xMax);

  const x = (hours: number) => PAD.left + (Math.min(hours, xMax) / xMax) * plotW;
  const y = (value: number) => PAD.top + ((yMax - value) / (yMax - yMin)) * plotH;

  // Wider charts take a tick every few hours; a narrow one keeps the labels from touching.
  const step = TICK_STEPS.find((candidate) => xMax / candidate <= Math.max(3, plotW / 70)) ?? 48;
  const hourTicks: number[] = [];
  for (let hours = 0; hours <= xMax; hours += step) hourTicks.push(hours);

  const owedShown = curve.owed >= yMin && curve.owed <= yMax;
  const dotX = x(hoursIn);
  const dotY = y(curve.price);
  const labelOnLeft = dotX > PAD.left + plotW * 0.55;
  const labelBelow = dotY < PAD.top + 24;
  const money = (value: number) => formatMusd(value);

  return (
    <svg
      className="loan-chart-svg"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label={`This auction's price falls from ${money(curve.startValue)} to ${money(curve.floorPrice)} MUSD over ${trim(durationH)} hours, then holds. It stands at ${money(curve.price)} MUSD now.`}
    >
      {hourTicks.map((hours) => (
        <g key={hours}>
          <line x1={x(hours)} x2={x(hours)} y1={PAD.top} y2={PAD.top + plotH} stroke="var(--line)" strokeWidth={1} />
          <text className="loan-chart-text" x={x(hours)} y={height - 12} textAnchor="middle">
            {hours}h
          </text>
        </g>
      ))}

      <line x1={PAD.left} x2={PAD.left + plotW} y1={y(curve.startValue)} y2={y(curve.startValue)} stroke="var(--line-strong)" strokeWidth={1} />
      <line x1={PAD.left} x2={PAD.left + plotW} y1={y(curve.floorPrice)} y2={y(curve.floorPrice)} stroke="var(--line-strong)" strokeWidth={1} />
      {owedShown && (
        <line
          x1={PAD.left}
          x2={PAD.left + plotW}
          y1={y(curve.owed)}
          y2={y(curve.owed)}
          stroke="var(--watch)"
          strokeWidth={1}
          strokeDasharray="4 4"
        />
      )}

      <text className="loan-chart-text" x={PAD.left + plotW - 6} y={y(curve.startValue) - 6} textAnchor="end">
        value at start {money(curve.startValue)}
      </text>
      <text className="loan-chart-text" x={PAD.left + 6} y={y(curve.floorPrice) - 6}>
        floor {money(curve.floorPrice)}
      </text>
      {owedShown && (
        <text className="loan-chart-text" x={PAD.left + plotW - 6} y={y(curve.owed) - 6} textAnchor="end">
          owed {money(curve.owed)}
        </text>
      )}

      <path
        className="loan-chart-price"
        d={`M ${x(0)} ${y(curve.startValue)} L ${x(durationH)} ${y(curve.floorPrice)} L ${x(xMax)} ${y(curve.floorPrice)}`}
        pathLength={1}
        fill="none"
        stroke="var(--beni)"
        strokeWidth={2.5}
        strokeLinejoin="round"
      />

      <circle cx={dotX} cy={dotY} r={5} fill="var(--paper)" />
      <circle cx={dotX} cy={dotY} r={9} fill="none" stroke="var(--paper)" strokeOpacity={0.35} strokeWidth={1} />
      <text
        className="loan-chart-text loan-chart-text-strong"
        x={labelOnLeft ? dotX - 14 : dotX + 14}
        y={labelBelow ? dotY + 20 : dotY - 12}
        textAnchor={labelOnLeft ? "end" : "start"}
      >
        now {money(curve.price)}
      </text>
    </svg>
  );
}

/** The 13.4 chart for one auction: hours from its start along the bottom, MUSD up the side, a dot at the price now. */
export function LoanAuctionChart({ curve, now }: { curve: LoanCurve; now: number }) {
  const reduced = useReducedMotion();
  const [wrapRef, seen] = useInViewOnce<HTMLDivElement>(0.4);
  const frameRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);

  useEffect(() => {
    const frame = frameRef.current;
    if (!frame) return;
    const measure = () => setWidth(Math.max(240, Math.floor(frame.getBoundingClientRect().width)));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(frame);
    return () => observer.disconnect();
  }, []);

  const height = width < 768 ? CHART_HEIGHT.phone : CHART_HEIGHT.desktop;

  return (
    <div ref={wrapRef} className="loan-chart" data-drawn={reduced || seen}>
      <div ref={frameRef}>
        <LoanCurveChart curve={curve} now={now} width={width} height={height} />
      </div>
      <p className="loan-chart-caption">Hours since this auction started</p>
    </div>
  );
}

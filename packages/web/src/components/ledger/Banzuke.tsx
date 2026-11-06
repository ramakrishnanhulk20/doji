"use client";

import Link from "next/link";
import type { CSSProperties } from "react";
import type { Address } from "viem";
import { useInViewOnce } from "../../hooks/useInViewOnce";
import { useReducedMotion } from "../../lib/motion-mode";
import type { RankId } from "../../lib/quests/ranks";
import { PaperSheet } from "./PaperSheet";
import { RANK_KANJI, RankSeal } from "./RankSeal";
import { SEAL_PATHS } from "./seal-paths";
import "./banzuke.css";

export type BanzukeRow = { place: number; address: Address; exp: number; rank: RankId };

type BanzukeProps = {
  rows: readonly BanzukeRow[];
  /** Unix seconds, as the leaderboard route reports it. */
  asOf: number;
  /** The connected wallet, whose row gets an outline. */
  you?: Address;
};

type Tier = { last: number; seal: number; kanji: number };

// Where each tier ends, the seal beside each row (0 for none) and the height of the small rank kanji, which follows the
// EXP size of that tier. The sizes of the type and the rules live in banzuke.css.
const TIERS: readonly Tier[] = [
  { last: 2, seal: 44, kanji: 15 },
  { last: 8, seal: 28, kanji: 13 },
  { last: 20, seal: 0, kanji: 12 },
  { last: 50, seal: 0, kanji: 11 },
];

// The centre column lists the ladder from the top down.
const LADDER: readonly RankId[] = ["sobashi", "ryogaesho", "nakagai", "banto", "tedai", "decchi"];

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const EMPTY_LINE = "No one is ranked yet. The first seal puts you at the top.";
const FOOT_LINE = "Doji's own wallets are left off this sheet. EXP has no cash value.";

// Shown to the minute and fixed to UTC, so the server and the browser print the same text.
function formatAsOf(unixSeconds: number): string {
  const at = new Date(unixSeconds * 1000);
  const two = (value: number) => String(value).padStart(2, "0");
  const month = MONTHS[at.getUTCMonth()] ?? "";
  return `${at.getUTCDate()} ${month} ${at.getUTCFullYear()} ${two(at.getUTCHours())}:${two(at.getUTCMinutes())} UTC`;
}

function tierOf(place: number): number {
  return TIERS.findIndex((tier) => place <= tier.last);
}

const shortAddress = (address: string) => `${address.slice(0, 6)}…${address.slice(-4)}`;
const formatExp = (exp: number) => `${exp.toLocaleString("en-US")} EXP`;

/**
 * Kanji drawn from the seal outlines, because the brush font does not hold the rank names. The outlines are in a
 * 1000-unit square, so one scale for every character gives the same size and weight a font would.
 */
function Kanji({ chars, size }: { chars: string; size: number }) {
  const scale = size / 1000;
  const gap = size * 0.06;
  let cursor = 0;
  const placed = [...chars].flatMap((char) => {
    const glyph = SEAL_PATHS[char];
    if (!glyph) return [];
    const x = cursor;
    cursor += glyph.width * scale + gap;
    const y = (size - glyph.height * scale) / 2;
    return [{ char, d: glyph.d, transform: `translate(${x.toFixed(2)} ${y.toFixed(2)}) scale(${scale})` }];
  });
  const width = Math.max(cursor - gap, 0);

  return (
    <svg
      className="bz-kanji"
      width={width}
      height={size}
      viewBox={`0 0 ${width.toFixed(2)} ${size}`}
      role="img"
      aria-label={chars}
      focusable="false"
    >
      {placed.map((part) => (
        <path key={part.char} d={part.d} transform={part.transform} fill="currentColor" />
      ))}
    </svg>
  );
}

type Side = "east" | "west";

function BanzukeRowItem({ row, tier, side, isYou, endsTier }: { row: BanzukeRow; tier: number; side: Side; isYou: boolean; endsTier: boolean }) {
  const seal = TIERS[tier]?.seal ?? 0;
  const kanji = TIERS[tier]?.kanji ?? 11;

  return (
    <li className="bz-item" value={row.place} data-tier-end={endsTier || undefined} style={{ "--place": row.place } as CSSProperties}>
      <div className="bz-row" data-you={isYou || undefined} data-side={side}>
        {seal > 0 && <RankSeal rank={row.rank} size={seal} />}
        <div className="bz-text">
          <span className="bz-line">
            <Link className="bz-address" href={`/quests/${row.address}`} prefetch={false} title={row.address}>
              {shortAddress(row.address)}
            </Link>
            {isYou && <span className="bz-you">you</span>}
          </span>
          <span className="bz-meta">
            <Kanji chars={RANK_KANJI[row.rank]} size={kanji} />
            <span className="bz-exp">{formatExp(row.exp)}</span>
          </span>
        </div>
      </div>
    </li>
  );
}

export function Banzuke({ rows, asOf, you }: BanzukeProps) {
  const reduced = useReducedMotion();
  const [ref, seen] = useInViewOnce<HTMLDivElement>(0.05);

  const placed = rows.filter((row) => tierOf(row.place) >= 0).sort((a, b) => a.place - b.place);
  const wallet = you?.toLowerCase();

  // Odd places sit in the East column, even places in the West, so the first place heads the East.
  const sides: Record<Side, BanzukeRow[][]> = {
    east: TIERS.map(() => []),
    west: TIERS.map(() => []),
  };
  const lastPlaceInTier = TIERS.map(() => 0);
  for (const row of placed) {
    const tier = tierOf(row.place);
    sides[row.place % 2 === 1 ? "east" : "west"][tier]?.push(row);
    lastPlaceInTier[tier] = row.place;
  }

  const sideColumn = (side: Side) => (
    <section className="bz-side" data-side={side} aria-label={side === "east" ? "East" : "West"}>
      <h3 className="bz-label" lang="ja" aria-hidden="true">
        {side === "east" ? "東" : "西"}
      </h3>
      {sides[side].map((tierRows, tier) =>
        tierRows.length === 0 ? null : (
          <ol key={tier} className="bz-tier" data-tier={tier} style={{ "--tier": tier } as CSSProperties}>
            {tierRows.map((row) => (
              <BanzukeRowItem
                key={row.place}
                row={row}
                tier={tier}
                side={side}
                isYou={wallet !== undefined && row.address.toLowerCase() === wallet}
                endsTier={row.place === lastPlaceInTier[tier]}
              />
            ))}
          </ol>
        ),
      )}
    </section>
  );

  return (
    <div ref={ref} className="ledger bz" data-seen={seen} data-motion={reduced ? "off" : "on"}>
      <PaperSheet className="banzuke-sheet">
        <header className="bz-head">
          <h2 className="bz-title" lang="ja">
            番付
          </h2>
          <p className="bz-asof">Doji rankings, {formatAsOf(asOf)}</p>
        </header>
        <div className="bz-rule" aria-hidden="true" />

        {placed.length === 0 ? (
          <p className="bz-empty">{EMPTY_LINE}</p>
        ) : (
          <div className="bz-body">
            {sideColumn("west")}
            <div className="bz-ranks" aria-hidden="true">
              {LADDER.map((rank) => (
                <Kanji key={rank} chars={RANK_KANJI[rank]} size={22} />
              ))}
            </div>
            {sideColumn("east")}
          </div>
        )}

        <p className="bz-foot">{FOOT_LINE}</p>
      </PaperSheet>
    </div>
  );
}

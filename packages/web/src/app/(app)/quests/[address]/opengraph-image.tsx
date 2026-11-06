import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { ReactElement, ReactNode } from "react";
import { ImageResponse } from "next/og";
import { notFound, redirect } from "next/navigation";
import { after } from "next/server";
import type { Address } from "viem";
import { RANK_TEXT } from "../../../../components/ledger/rank-names";
import { RANK_KANJI, type Rank } from "../../../../components/ledger/RankSeal";
import { SEAL_PATHS } from "../../../../components/ledger/seal-paths";
import { parseAddress } from "../../../../lib/address";
import { readExpSnapshot, type WalletStanding } from "../../../../lib/quests/read-all";

export const alt = "A wallet's rank in the Doji ledger";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const dynamic = "force-dynamic";
// Long enough for a first scan to finish after the reply, because `after` keeps the function alive for it.
export const maxDuration = 60;

const SHARED_CACHE = "public, s-maxage=60, stale-while-revalidate=600";

// Long enough for a usual scan, short enough that a link preview is still waiting.
const READ_CEILING_MS = 9_000;

const WASHI = "#efe3cd";
const SUMI = "#1c1815";
const SUMI_SOFT = "rgba(28, 24, 21, 0.62)";
const SEAL_RED = "#b52533";
const SEAL_SIZE = 300;
const FIBRE_TILE = "640px 640px";

const ellipse = (rx: number, ry: number) => `M${100 - rx} 100a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0Z`;

function box(inset: number, radius = 0): string {
  const side = 200 - 2 * inset;
  if (radius === 0) return `M${inset} ${inset}h${side}v${side}h${-side}Z`;
  const run = side - 2 * radius;
  const arc = (x: number, y: number) => `a${radius} ${radius} 0 0 1 ${x} ${y}`;
  return `M${inset + radius} ${inset}h${run}${arc(radius, radius)}v${run}${arc(-radius, radius)}h${-run}${arc(-radius, -radius)}v${-run}${arc(radius, -radius)}Z`;
}

const band = (d: string) => `<path d="${d}" fill-rule="evenodd" fill="${SEAL_RED}"/>`;

function kobanTicks(): string {
  const ticks = [60, 86, 114, 140].flatMap((y) => {
    const edge = 72 * Math.sqrt(1 - ((y - 100) / 96) ** 2);
    return [100 + edge, 100 - edge].map((x) => `M${x - 6} ${y - 1.5}h12v3h-12Z`);
  });
  return `<path d="${ticks.join("")}" fill="${SEAL_RED}"/>`;
}

type Slot = { w: number; h: number; cy: number };

const twoSlots = (w: number, h: number): Slot[] => [
  { w, h, cy: 100 - h / 2 },
  { w, h, cy: 100 + h / 2 },
];

function kanji(rank: Rank, slots: readonly Slot[], fill: string, cx = 100): string {
  return [...RANK_KANJI[rank]]
    .map((char, index) => {
      const glyph = SEAL_PATHS[char];
      const slot = slots[index];
      if (!glyph || !slot) return "";
      const scale = Math.min(slot.w / glyph.width, slot.h / glyph.height);
      const x = cx - (glyph.width * scale) / 2;
      const y = slot.cy - (glyph.height * scale) / 2;
      return `<path d="${glyph.d}" fill="${fill}" transform="translate(${x.toFixed(2)} ${y.toFixed(2)}) scale(${scale.toFixed(5)})"/>`;
    })
    .join("");
}

function cutOutOfSolid(mask: string): string {
  return `<mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="200" height="200">${mask}</mask><rect x="0" y="0" width="200" height="200" fill="${SEAL_RED}" mask="url(#cut)"/>`;
}

const FUNDO =
  "M 38 30 Q 100 16 162 30 C 176 34 176 60 160 72 C 146 82 132 88 132 100 C 132 112 146 118 160 128 " +
  "C 176 140 176 166 162 170 Q 100 184 38 170 C 24 166 24 140 40 128 C 54 118 68 112 68 100 " +
  "C 68 88 54 82 40 72 C 24 60 24 34 38 30 Z";

const FUNDO_SLOTS: Slot[] = [
  { w: 66, h: 40, cy: 58 },
  { w: 50, h: 38, cy: 100 },
  { w: 66, h: 40, cy: 142 },
];

const SOBASHI_SLOTS: Slot[] = [44, 100, 156].map((cy) => ({ w: 100, h: 50, cy }));
const SOBASHI_KANJI_CENTRE_X = 124;

/**
 * RankSeal's shapes as plain SVG text. next/og's renderer has no filters and no page styles, and RankSeal cannot run here
 * because it uses a hook, so this draws the shapes with the rough edge and the speckle left out.
 */
function rankSealUrl(rank: Rank): string {
  const shapes: Record<Rank, () => string> = {
    decchi: () => band(ellipse(92, 92) + ellipse(85, 85)) + kanji(rank, twoSlots(84, 66), SEAL_RED),
    tedai: () => band(box(14, 4) + box(23)) + kanji(rank, twoSlots(112, 72), SEAL_RED),
    banto: () => band(box(14, 4) + box(24)) + band(box(30) + box(33)) + kanji(rank, twoSlots(96, 60), SEAL_RED),
    nakagai: () => band(ellipse(72, 96) + ellipse(62, 86)) + band(ellipse(56, 80) + ellipse(53, 77)) + kobanTicks() + kanji(rank, twoSlots(68, 56), SEAL_RED),
    ryogaesho: () => cutOutOfSolid(`<path d="${FUNDO}" fill="white"/>${kanji(rank, FUNDO_SLOTS, "black")}`),
    sobashi: () =>
      cutOutOfSolid(
        `<path d="${box(8, 6)}" fill="white"/><rect x="17.5" y="17.5" width="165" height="165" rx="1" fill="none" stroke="black" stroke-width="3"/>` +
          kanji(rank, SOBASHI_SLOTS, "black", SOBASHI_KANJI_CENTRE_X) +
          '<rect x="42.5" y="36" width="7" height="128" fill="black"/><rect x="26" y="96" width="40" height="8" fill="black"/>',
      ),
  };
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SEAL_SIZE}" height="${SEAL_SIZE}" viewBox="0 0 200 200">${shapes[rank]()}</svg>`;
  return `data:image/svg+xml;base64,${Buffer.from(svg).toString("base64")}`;
}

type Art = { serif: Buffer; mono: Buffer; fibres: string };

let loadedArt: Promise<Art> | null = null;

// Every file is bundled, so a render reaches nothing remote (C77). The fonts are Latin subsets of Fraunces and IBM Plex
// Mono (OFL), and all text on a card is ASCII, so next/og never goes looking for a missing glyph.
function loadArt(): Promise<Art> {
  loadedArt ??= Promise.all([
    readFile(join(process.cwd(), "src/fonts/og-fraunces.ttf")),
    readFile(join(process.cwd(), "src/fonts/og-plex-mono.ttf")),
    readFile(join(process.cwd(), "public/art/washi-fibres.svg")),
  ]).then(([serif, mono, fibres]) => ({ serif, mono, fibres: `url(data:image/svg+xml;base64,${fibres.toString("base64")})` }));
  return loadedArt;
}

function Paper({ fibres, children }: { fibres: string; children: ReactNode }) {
  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "center",
        gap: 76,
        padding: "0 88px",
        color: SUMI,
        fontFamily: "Doji Card Serif",
        backgroundColor: WASHI,
        backgroundImage: fibres,
        backgroundSize: FIBRE_TILE,
      }}
    >
      {children}
    </div>
  );
}

const MONO = { fontFamily: "Doji Card Mono" };

function rankCard(fibres: string, address: Address, standing: WalletStanding): ReactElement {
  const { name, meaning } = RANK_TEXT[standing.rank];
  return (
    <Paper fibres={fibres}>
      <img src={rankSealUrl(standing.rank)} alt="" width={SEAL_SIZE} height={SEAL_SIZE} />
      <div style={{ display: "flex", flexDirection: "column" }}>
        <div style={{ ...MONO, fontSize: 26, color: SUMI_SOFT }}>Doji ledger</div>
        <div style={{ fontSize: 84, lineHeight: 1.1, marginTop: 20 }}>{name}</div>
        <div style={{ fontSize: 32, color: SUMI_SOFT, marginTop: 4 }}>{meaning}</div>
        <div style={{ ...MONO, fontSize: 44, marginTop: 36 }}>{`${standing.exp.toLocaleString("en-US")} EXP`}</div>
        <div style={{ ...MONO, fontSize: 28, color: SUMI_SOFT, marginTop: 8 }}>{`${address.slice(0, 6)}...${address.slice(-4)}`}</div>
      </div>
    </Paper>
  );
}

function drawCard(card: ReactElement, art: Art, cacheControl: string): ImageResponse {
  return new ImageResponse(card, {
    ...size,
    headers: { "cache-control": cacheControl },
    fonts: [
      { name: "Doji Card Serif", data: art.serif, weight: 500, style: "normal" },
      { name: "Doji Card Mono", data: art.mono, weight: 400, style: "normal" },
    ],
  });
}

function PlainCard({ fibres }: { fibres: string }) {
  return (
    <Paper fibres={fibres}>
      <div style={{ display: "flex", flexDirection: "column" }}>
        <div style={{ ...MONO, fontSize: 26, color: SUMI_SOFT }}>Doji ledger</div>
        <div style={{ fontSize: 84, lineHeight: 1.1, marginTop: 20 }}>The merchant&apos;s ledger.</div>
        <div style={{ fontSize: 32, color: SUMI_SOFT, marginTop: 12 }}>Try Doji with free test tokens.</div>
      </div>
    </Paper>
  );
}

let plainPng: Promise<ArrayBuffer> | null = null;

// Holds no wallet and no number, so it says nothing that could be wrong (C70). Any number of made-up addresses land here,
// so the one file is drawn once.
function plainCard(art: Art, cacheControl: string): Promise<Response> {
  plainPng ??= drawCard(<PlainCard fibres={art.fibres} />, art, cacheControl).arrayBuffer();
  return plainPng.then((png) => new Response(png, { headers: { "content-type": contentType, "cache-control": cacheControl } }));
}

/** The snapshot, or null when it is incomplete or slower than a link preview will wait. */
async function readSnapshot() {
  const reading = readExpSnapshot();
  // A first scan can outlast this reply, and the next render should find it finished.
  after(() => reading.catch(() => undefined));
  let timer: ReturnType<typeof setTimeout> | undefined;
  const ceiling = new Promise<null>((resolve) => {
    timer = setTimeout(() => resolve(null), READ_CEILING_MS);
  });
  const snapshot = await Promise.race([reading.catch(() => null), ceiling]);
  clearTimeout(timer);
  return snapshot?.complete ? snapshot : null;
}

/**
 * The picture X shows for a wallet's ledger. It depends on the address in the path and the one snapshot, and on nothing
 * else in the request: there is no exp or rank parameter and a query string does nothing (C73, C77). An address that does
 * not parse has no image. A wallet with no EXP, or a read that did not finish, gets the plain card (C70).
 */
export default async function Image({ params }: { params: Promise<{ address: string }> }): Promise<Response> {
  const { address: raw } = await params;
  const address = parseAddress(raw);
  if (address === null) notFound();
  if (raw !== address) redirect(`/quests/${address}`);

  const [art, snapshot] = await Promise.all([loadArt(), readSnapshot()]);
  // An unfinished read is not cached, so a wallet with a rank gets its real card as soon as the scan lands.
  if (snapshot === null) return plainCard(art, "no-store");
  const standing = snapshot.wallets[address];
  if (standing === undefined) return plainCard(art, SHARED_CACHE);
  return drawCard(rankCard(art.fibres, address, standing), art, SHARED_CACHE);
}

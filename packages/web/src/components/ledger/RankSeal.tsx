import { useId, type ReactNode } from "react";
import { SEAL_PATHS } from "./seal-paths";

export type Rank = "decchi" | "tedai" | "banto" | "nakagai" | "ryogaesho" | "sobashi";

export const RANK_KANJI: Record<Rank, string> = {
  decchi: "丁稚",
  tedai: "手代",
  banto: "番頭",
  nakagai: "仲買",
  ryogaesho: "両替商",
  sobashi: "相場師",
};

type RankSealProps = {
  rank: Rank;
  size: number;
  /** Accessible name. Leave it out when the rank is written next to the seal. */
  title?: string;
};

// The rough edge and the missed-paper speckle only read at larger sizes, as on the Doji seal.
const DETAIL_FROM_SIZE = 48;

const INK = { fill: "var(--beni-deep)" } as const;

type Box = { w: number; h: number };

function ellipsePath(cx: number, cy: number, rx: number, ry: number): string {
  return `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0Z`;
}

function rectPath(x: number, y: number, w: number, h: number, r: number): string {
  if (r === 0) return `M${x} ${y}h${w}v${h}h${-w}Z`;
  const run = w - 2 * r;
  const rise = h - 2 * r;
  return (
    `M${x + r} ${y}h${run}a${r} ${r} 0 0 1 ${r} ${r}v${rise}a${r} ${r} 0 0 1 ${-r} ${r}` +
    `h${-run}a${r} ${r} 0 0 1 ${-r} ${-r}v${-rise}a${r} ${r} 0 0 1 ${r} ${-r}Z`
  );
}

// A border is a filled band between an outer and an inner outline, so its thickness is exact at the corners.
function Band({ d }: { d: string }) {
  return <path d={d} fillRule="evenodd" style={INK} />;
}

// A slot is a box the kanji is fitted into and the height of that box's centre.
type Slot = { box: Box; cy: number };

function evenSlots(count: number, box: Box, cy = 100): Slot[] {
  const top = cy - (count * box.h) / 2;
  return Array.from({ length: count }, (_, index) => ({ box, cy: top + (index + 0.5) * box.h }));
}

function placeKanji(chars: string, slots: Slot[], cx = 100) {
  return [...chars].flatMap((char, index) => {
    const glyph = SEAL_PATHS[char];
    const slot = slots[index];
    if (!glyph || !slot) return [];
    const scale = Math.min(slot.box.w / glyph.width, slot.box.h / glyph.height);
    const x = cx - (glyph.width * scale) / 2;
    const y = slot.cy - (glyph.height * scale) / 2;
    return [{ char, d: glyph.d, transform: `translate(${x.toFixed(2)} ${y.toFixed(2)}) scale(${scale.toFixed(5)})` }];
  });
}

function InkKanji({ chars, box }: { chars: string; box: Box }) {
  return (
    <>
      {placeKanji(chars, evenSlots([...chars].length, box)).map((kanji) => (
        <path key={kanji.char} d={kanji.d} transform={kanji.transform} style={INK} />
      ))}
    </>
  );
}

function kobanTicks(): string {
  return [60, 86, 114, 140]
    .flatMap((y) => {
      const edge = 72 * Math.sqrt(1 - ((y - 100) / 96) ** 2);
      return [100 + edge, 100 - edge].map((x) => rectPath(x - 6, y - 1.5, 12, 3, 0));
    })
    .join("");
}

// The fundo (balance weight) as a spool: full lobes top and bottom, bitten only at the sides.
const FUNDO =
  "M 38 30 Q 100 16 162 30 C 176 34 176 60 160 72 C 146 82 132 88 132 100 C 132 112 146 118 160 128 " +
  "C 176 140 176 166 162 170 Q 100 184 38 170 C 24 166 24 140 40 128 C 54 118 68 112 68 100 " +
  "C 68 88 54 82 40 72 C 24 60 24 34 38 30 Z";

const FUNDO_SLOTS: Slot[] = [
  { box: { w: 66, h: 40 }, cy: 58 },
  { box: { w: 50, h: 38 }, cy: 100 },
  { box: { w: 66, h: 40 }, cy: 142 },
];

const SOBASHI_SLOTS: Slot[] = [44, 100, 156].map((cy) => ({ box: { w: 100, h: 50 }, cy }));
const SOBASHI_KANJI_CENTRE_X = 124;

// The doji cross the project is named for: one wick and one flat body, cut out of the solid red.
function DojiCross() {
  return (
    <>
      <rect x="42.5" y="36" width="7" height="128" />
      <rect x="26" y="96" width="40" height="8" />
    </>
  );
}

// Solid seals carry large red areas, so fewer specks drop out of them than out of a line seal.
const SPECK_OFFSET_LINE = -6.1;
const SPECK_OFFSET_SOLID = -5;

type Drawing = { defs?: ReactNode; shape: ReactNode };

function drawRank(rank: Rank, maskId: string): Drawing {
  switch (rank) {
    case "decchi":
      return {
        shape: (
          <>
            <Band d={ellipsePath(100, 100, 92, 92) + ellipsePath(100, 100, 85, 85)} />
            <InkKanji chars={RANK_KANJI.decchi} box={{ w: 84, h: 66 }} />
          </>
        ),
      };
    case "tedai":
      return {
        shape: (
          <>
            <Band d={rectPath(14, 14, 172, 172, 4) + rectPath(23, 23, 154, 154, 0)} />
            <InkKanji chars={RANK_KANJI.tedai} box={{ w: 112, h: 72 }} />
          </>
        ),
      };
    case "banto":
      return {
        shape: (
          <>
            <Band d={rectPath(14, 14, 172, 172, 4) + rectPath(24, 24, 152, 152, 0)} />
            <Band d={rectPath(30, 30, 140, 140, 0) + rectPath(33, 33, 134, 134, 0)} />
            <InkKanji chars={RANK_KANJI.banto} box={{ w: 96, h: 60 }} />
          </>
        ),
      };
    case "nakagai":
      return {
        shape: (
          <>
            <Band d={ellipsePath(100, 100, 72, 96) + ellipsePath(100, 100, 62, 86)} />
            <Band d={ellipsePath(100, 100, 56, 80) + ellipsePath(100, 100, 53, 77)} />
            <path d={kobanTicks()} style={INK} />
            <InkKanji chars={RANK_KANJI.nakagai} box={{ w: 68, h: 56 }} />
          </>
        ),
      };
    case "ryogaesho":
      return {
        defs: (
          <mask id={maskId} maskUnits="userSpaceOnUse" x="0" y="0" width="200" height="200">
            <path d={FUNDO} fill="white" />
            {placeKanji(RANK_KANJI.ryogaesho, FUNDO_SLOTS).map((kanji) => (
              <path key={kanji.char} d={kanji.d} transform={kanji.transform} fill="black" />
            ))}
          </mask>
        ),
        shape: <rect x="0" y="0" width="200" height="200" mask={`url(#${maskId})`} style={INK} />,
      };
    case "sobashi":
      return {
        defs: (
          <mask id={maskId} maskUnits="userSpaceOnUse" x="0" y="0" width="200" height="200">
            <path d={rectPath(8, 8, 184, 184, 6)} fill="white" />
            <rect x="17.5" y="17.5" width="165" height="165" rx="1" fill="none" stroke="black" strokeWidth="3" />
            <g fill="black">
              {placeKanji(RANK_KANJI.sobashi, SOBASHI_SLOTS, SOBASHI_KANJI_CENTRE_X).map((kanji) => (
                <path key={kanji.char} d={kanji.d} transform={kanji.transform} />
              ))}
              <DojiCross />
            </g>
          </mask>
        ),
        shape: <rect x="0" y="0" width="200" height="200" mask={`url(#${maskId})`} style={INK} />,
      };
  }
}

export function RankSeal({ rank, size, title }: RankSealProps) {
  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const filterId = `seal-ink-${uid}`;
  const maskId = `seal-cut-${uid}`;
  const rough = size >= DETAIL_FROM_SIZE;
  const { defs, shape } = drawRank(rank, maskId);
  const speckOffset = rank === "ryogaesho" || rank === "sobashi" ? SPECK_OFFSET_SOLID : SPECK_OFFSET_LINE;

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 200 200"
      role={title ? "img" : undefined}
      aria-label={title || undefined}
      aria-hidden={title ? undefined : true}
      focusable="false"
      data-rank={rank}
    >
      <defs>
        {defs}
        {rough && (
          <filter
            id={filterId}
            filterUnits="userSpaceOnUse"
            x="0"
            y="0"
            width="200"
            height="200"
            colorInterpolationFilters="sRGB"
          >
            <feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="3" seed="4" result="edge" />
            <feDisplacementMap in="SourceGraphic" in2="edge" scale="5" xChannelSelector="R" yChannelSelector="G" result="rough" />
            <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="9" result="grain" />
            <feColorMatrix
              in="grain"
              type="matrix"
              values={`0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  20 0 0 0 ${speckOffset}`}
              result="specks"
            />
            <feComposite in="rough" in2="specks" operator="in" />
          </filter>
        )}
      </defs>
      <g filter={rough ? `url(#${filterId})` : undefined}>{shape}</g>
    </svg>
  );
}

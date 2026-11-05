// Writes public/art/washi-fibres.svg: a 640 x 640 tile of loose paper hairs and a few pulp flecks.
// A seeded generator keeps the file identical on every run. Hairs that cross a tile edge are drawn again on the
// opposite side, so the tile repeats without a seam.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SIZE = 640;
const HAIRS = 90;
const FLECKS = 12;
const SEED = 20241105;

const OUTPUT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../public/art/washi-fibres.svg");

function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const random = mulberry32(SEED);
const between = (low, high) => low + random() * (high - low);
const fixed = (value) => value.toFixed(2);

// The tile copies a shape needs: itself, plus one shifted copy for each edge its box crosses.
function wraps(box) {
  const shifts = [];
  for (const dx of [-SIZE, 0, SIZE]) {
    for (const dy of [-SIZE, 0, SIZE]) {
      const hitsX = box.right + dx > 0 && box.left + dx < SIZE;
      const hitsY = box.bottom + dy > 0 && box.top + dy < SIZE;
      if (hitsX && hitsY) shifts.push([dx, dy]);
    }
  }
  return shifts;
}

const shapes = [];

for (let index = 0; index < HAIRS; index++) {
  const length = between(40, 180);
  const angle = between(0, Math.PI);
  const x1 = between(0, SIZE);
  const y1 = between(0, SIZE);
  const x2 = x1 + Math.cos(angle) * length;
  const y2 = y1 + Math.sin(angle) * length;
  // The control point bows the hair to one side by up to a fifth of its length.
  const bow = between(-0.2, 0.2) * length;
  const cx = (x1 + x2) / 2 - Math.sin(angle) * bow;
  const cy = (y1 + y2) / 2 + Math.cos(angle) * bow;
  const width = between(0.4, 1.1);
  const opacity = between(0.1, 0.3);
  const box = {
    left: Math.min(x1, x2, cx) - width,
    right: Math.max(x1, x2, cx) + width,
    top: Math.min(y1, y2, cy) - width,
    bottom: Math.max(y1, y2, cy) + width,
  };
  for (const [dx, dy] of wraps(box)) {
    shapes.push(
      `<path d="M${fixed(x1 + dx)} ${fixed(y1 + dy)}Q${fixed(cx + dx)} ${fixed(cy + dy)} ${fixed(x2 + dx)} ${fixed(y2 + dy)}" ` +
        `fill="none" stroke="#8b7250" stroke-width="${fixed(width)}" stroke-linecap="round" opacity="${fixed(opacity)}"/>`,
    );
  }
}

for (let index = 0; index < FLECKS; index++) {
  const rx = between(1, 2.5);
  const ry = rx * between(0.5, 1);
  const x = between(0, SIZE);
  const y = between(0, SIZE);
  const turn = between(0, 180);
  const reach = rx + 1;
  const box = { left: x - reach, right: x + reach, top: y - reach, bottom: y + reach };
  for (const [dx, dy] of wraps(box)) {
    shapes.push(
      `<ellipse cx="${fixed(x + dx)}" cy="${fixed(y + dy)}" rx="${fixed(rx)}" ry="${fixed(ry)}" ` +
        `transform="rotate(${fixed(turn)} ${fixed(x + dx)} ${fixed(y + dy)})" fill="#cbb68f" opacity="0.4"/>`,
    );
  }
}

const svg =
  `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">\n` +
  `${shapes.join("\n")}\n</svg>\n`;

mkdirSync(path.dirname(OUTPUT), { recursive: true });
writeFileSync(OUTPUT, svg, "utf8");
console.log(`wrote ${OUTPUT} (${svg.length} bytes, ${HAIRS} hairs, ${FLECKS} flecks, ${shapes.length} drawn with edge copies)`);

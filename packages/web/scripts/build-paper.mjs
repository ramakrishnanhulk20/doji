// Writes public/art/washi-mottle.webp and public/art/washi-grain.webp: the two noise tiles under the paper, 640 x 640 each.
// The paper used to draw them from turbulence filters inside data URIs, which the browser redrew while the page turned.
// Here the same noise is computed once, with the reference algorithm from the SVG filter spec (fractal sum, two octaves,
// stitched so the tile repeats without a seam). Each tile is one flat colour with the noise held in its alpha, so the paper
// still multiplies a soft tint over the washi exactly as before. Lossless keeps every alpha level.
import { mkdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const SIZE = 640;
const OCTAVES = 2;
const MAX_BYTES = 60 * 1024;
// A seam shows when the jump across the tile edge is much bigger than the jump between two neighbouring pixels, in alpha levels.
const MAX_SEAM_RATIO = 1.5;
const SEAM_FLOOR = 0.5;

const OUTPUT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../public/art");

const TILES = [
  // Slow mottling: wide soft blotches in a warm brown, 12 percent at its strongest.
  { name: "washi-mottle", frequency: 0.009, seed: 11, colour: [0.643, 0.541, 0.388], opacity: 0.12 },
  // Fine grain: pixel-scale speckle in a darker brown, 5 percent at its strongest.
  { name: "washi-grain", frequency: 0.8, seed: 5, colour: [0.478, 0.392, 0.282], opacity: 0.05 },
];

const RAND_M = 2147483647;
const RAND_A = 16807;
const RAND_Q = 127773;
const RAND_R = 2836;
const LATTICE = 256;
const LATTICE_MASK = 255;
const OFFSET = 4096;

const nextRandom = (seed) => {
  const result = RAND_A * (seed % RAND_Q) - RAND_R * Math.trunc(seed / RAND_Q);
  return result <= 0 ? result + RAND_M : result;
};

// The alpha channel is the fourth of the four gradient sets the spec keeps, one per colour channel.
const ALPHA_CHANNEL = 3;

function makeLattice(startSeed) {
  let seed = startSeed;
  if (seed <= 0) seed = -(seed % (RAND_M - 1)) + 1;
  if (seed > RAND_M - 1) seed = RAND_M - 1;

  const selector = new Array(LATTICE + LATTICE + 2).fill(0);
  const gradient = Array.from({ length: 4 }, () => Array.from({ length: LATTICE + LATTICE + 2 }, () => [0, 0]));

  for (let channel = 0; channel < 4; channel++) {
    for (let index = 0; index < LATTICE; index++) {
      selector[index] = index;
      for (let axis = 0; axis < 2; axis++) {
        seed = nextRandom(seed);
        gradient[channel][index][axis] = ((seed % (LATTICE + LATTICE)) - LATTICE) / LATTICE;
      }
      const length = Math.hypot(gradient[channel][index][0], gradient[channel][index][1]);
      gradient[channel][index][0] /= length;
      gradient[channel][index][1] /= length;
    }
  }
  for (let index = LATTICE - 1; index > 0; index--) {
    const held = selector[index];
    seed = nextRandom(seed);
    const swap = seed % LATTICE;
    selector[index] = selector[swap];
    selector[swap] = held;
  }
  for (let index = 0; index < LATTICE + 2; index++) {
    selector[LATTICE + index] = selector[index];
    for (let channel = 0; channel < 4; channel++) {
      gradient[channel][LATTICE + index] = [...gradient[channel][index]];
    }
  }
  return { selector, gradient };
}

const curve = (t) => t * t * (3 - 2 * t);
const lerp = (t, from, to) => from + t * (to - from);

function noise(lattice, x, y, stitch) {
  const { selector, gradient } = lattice;
  let t = x + OFFSET;
  let x0 = Math.trunc(t);
  let x1 = x0 + 1;
  const rx0 = t - Math.trunc(t);
  const rx1 = rx0 - 1;
  t = y + OFFSET;
  let y0 = Math.trunc(t);
  let y1 = y0 + 1;
  const ry0 = t - Math.trunc(t);
  const ry1 = ry0 - 1;

  // Cells past the tile's far edge fold back to its near edge, then the lattice index wraps at 256.
  if (x0 >= stitch.wrapX) x0 -= stitch.width;
  if (x1 >= stitch.wrapX) x1 -= stitch.width;
  if (y0 >= stitch.wrapY) y0 -= stitch.height;
  if (y1 >= stitch.wrapY) y1 -= stitch.height;
  x0 &= LATTICE_MASK;
  x1 &= LATTICE_MASK;
  y0 &= LATTICE_MASK;
  y1 &= LATTICE_MASK;

  const i = selector[x0];
  const j = selector[x1];
  const b00 = selector[i + y0];
  const b10 = selector[j + y0];
  const b01 = selector[i + y1];
  const b11 = selector[j + y1];
  const sx = curve(rx0);
  const sy = curve(ry0);
  const g = gradient[ALPHA_CHANNEL];

  let u = rx0 * g[b00][0] + ry0 * g[b00][1];
  let v = rx1 * g[b10][0] + ry0 * g[b10][1];
  const a = lerp(sx, u, v);
  u = rx0 * g[b01][0] + ry1 * g[b01][1];
  v = rx1 * g[b11][0] + ry1 * g[b11][1];
  const b = lerp(sx, u, v);
  return lerp(sy, a, b);
}

// The base frequency is nudged so a whole number of noise cells fits the tile, which is what makes the edges meet.
function stitchedFrequency(frequency) {
  const low = Math.floor(SIZE * frequency) / SIZE;
  const high = Math.ceil(SIZE * frequency) / SIZE;
  return frequency / low < high / frequency ? low : high;
}

// The spec's fractal sum for the alpha channel, then the filter's colour matrix (twice the value, less one half).
function alphaAt(lattice, frequency, px, py) {
  let stitch = { width: Math.trunc(SIZE * frequency + 0.5), height: Math.trunc(SIZE * frequency + 0.5), wrapX: 0, wrapY: 0 };
  stitch.wrapX = OFFSET + stitch.width;
  stitch.wrapY = OFFSET + stitch.height;
  let x = px * frequency;
  let y = py * frequency;
  let ratio = 1;
  let sum = 0;
  for (let octave = 0; octave < OCTAVES; octave++) {
    sum += noise(lattice, x, y, stitch) / ratio;
    x *= 2;
    y *= 2;
    ratio *= 2;
    stitch = {
      width: stitch.width * 2,
      height: stitch.height * 2,
      wrapX: 2 * stitch.wrapX - OFFSET,
      wrapY: 2 * stitch.wrapY - OFFSET,
    };
  }
  const noiseAlpha = Math.min(1, Math.max(0, (sum + 1) / 2));
  return Math.min(1, Math.max(0, 2 * noiseAlpha - 0.5));
}

// Compares the average jump across the tile edge with the average jump between neighbouring pixels everywhere else.
// The floor keeps a smooth, nearly flat tile from turning a one-level step into a huge ratio.
function seamRatio(alpha) {
  let across = 0;
  let inside = 0;
  for (let line = 0; line < SIZE; line++) {
    across += Math.abs(alpha[line * SIZE + SIZE - 1] - alpha[line * SIZE]);
    across += Math.abs(alpha[(SIZE - 1) * SIZE + line] - alpha[line]);
    for (let step = 0; step < SIZE - 1; step++) {
      inside += Math.abs(alpha[line * SIZE + step] - alpha[line * SIZE + step + 1]);
      inside += Math.abs(alpha[step * SIZE + line] - alpha[(step + 1) * SIZE + line]);
    }
  }
  return across / (2 * SIZE) / Math.max(inside / (2 * SIZE * (SIZE - 1)), SEAM_FLOOR);
}

mkdirSync(OUTPUT_DIR, { recursive: true });

for (const tile of TILES) {
  const lattice = makeLattice(tile.seed);
  const frequency = stitchedFrequency(tile.frequency);
  const [red, green, blue] = tile.colour.map((channel) => Math.round(channel * 255));

  const alpha = new Uint8Array(SIZE * SIZE);
  const rgba = Buffer.alloc(SIZE * SIZE * 4);
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const pixel = y * SIZE + x;
      alpha[pixel] = Math.round(alphaAt(lattice, frequency, x, y) * 255 * tile.opacity);
      rgba[pixel * 4] = red;
      rgba[pixel * 4 + 1] = green;
      rgba[pixel * 4 + 2] = blue;
      rgba[pixel * 4 + 3] = alpha[pixel];
    }
  }

  const ratio = seamRatio(alpha);
  if (ratio > MAX_SEAM_RATIO) throw new Error(`${tile.name} shows a seam at its edge (ratio ${ratio.toFixed(2)})`);

  const file = path.join(OUTPUT_DIR, `${tile.name}.webp`);
  await sharp(rgba, { raw: { width: SIZE, height: SIZE, channels: 4 } })
    .webp({ lossless: true, effort: 6 })
    .toFile(file);

  const bytes = statSync(file).size;
  if (bytes > MAX_BYTES) throw new Error(`${tile.name}.webp is ${bytes} bytes, over the ${MAX_BYTES} byte limit`);
  console.log(`${tile.name}.webp ${bytes} bytes, seam ratio ${ratio.toFixed(2)}`);
}

export type Token = {
  name: string;
  hex: string;
  use: string;
  /** What the contrast ratio is measured against: text of this token on `ink`, or paper text on this token. */
  measure: "on-ink" | "paper-on-token";
};

// Hex values mirror :root in globals.css. The lab computes every contrast ratio from them.
export const TOKENS: readonly Token[] = [
  { name: "--ink", hex: "#0E0C0B", use: "Page background", measure: "paper-on-token" },
  { name: "--ink-2", hex: "#171412", use: "Surfaces, cards", measure: "paper-on-token" },
  { name: "--ink-3", hex: "#221E1B", use: "Raised surfaces, inputs", measure: "paper-on-token" },
  { name: "--line", hex: "#2E2925", use: "Hairlines, borders", measure: "on-ink" },
  { name: "--line-strong", hex: "#4A423C", use: "Network tag and strong borders", measure: "on-ink" },
  { name: "--paper", hex: "#F1E6D2", use: "Primary text", measure: "on-ink" },
  { name: "--paper-dim", hex: "#B9AE9C", use: "Secondary text", measure: "on-ink" },
  { name: "--beni", hex: "#C43646", use: "The accent: seal, rules, display accents", measure: "on-ink" },
  { name: "--beni-deep", hex: "#B52533", use: "Primary button fill", measure: "paper-on-token" },
  { name: "--beni-hover", hex: "#CF4252", use: "Primary button hover", measure: "paper-on-token" },
  { name: "--beni-text", hex: "#E35D68", use: "Small accent text, focus ring", measure: "on-ink" },
  { name: "--safe", hex: "#7FB3B5", use: "Status: safe", measure: "on-ink" },
  { name: "--watch", hex: "#A9B8D6", use: "Status: close to the limit", measure: "on-ink" },
  { name: "--auction", hex: "#B7A6E6", use: "Status: in auction", measure: "on-ink" },
];

export const PAPER_HEX = "#F1E6D2";
export const INK_HEX = "#0E0C0B";

function channel(value: number): number {
  const unit = value / 255;
  return unit <= 0.03928 ? unit / 12.92 : Math.pow((unit + 0.055) / 1.055, 2.4);
}

function luminance(hex: string): number {
  const red = parseInt(hex.slice(1, 3), 16);
  const green = parseInt(hex.slice(3, 5), 16);
  const blue = parseInt(hex.slice(5, 7), 16);
  return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue);
}

/** WCAG 2 contrast ratio between two hex colours. */
export function contrastRatio(a: string, b: string): number {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (light + 0.05) / (dark + 0.05);
}

/** One plain sentence for a swatch, with the ratio worked out from the hex values. */
export function contrastNote(token: Token): string {
  const ratio =
    token.measure === "on-ink" ? contrastRatio(token.hex, INK_HEX) : contrastRatio(PAPER_HEX, token.hex);
  const shown = `${ratio.toFixed(1)}:1`;
  const subject = token.measure === "on-ink" ? "On ink" : "Paper text on it";

  if (ratio >= 4.5) return `${subject}: ${shown}, passes for body text`;
  if (ratio >= 3) return `${subject}: ${shown}, large text and lines only`;
  return `${subject}: ${shown}, decoration only`;
}

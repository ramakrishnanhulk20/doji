import { useId, type CSSProperties } from "react";

type SealProps = {
  size: number;
  /** Accessible name. Pass an empty string when a visible "Doji" sits next to the seal. */
  title?: string;
  className?: string;
  /** Loading mark: the doji's wick breathes between 40 and 100 percent of its height. */
  busy?: boolean;
  /** When set, the candles draw in as this turns true. Left unset, the seal is simply drawn. */
  drawn?: boolean;
};

// The inner border and the rough stamped edge only read at larger sizes.
const DETAIL_FROM_SIZE = 48;

const paper = { fill: "var(--paper)" } as const;

export function Seal({ size, title = "Doji", className, busy = false, drawn }: SealProps) {
  const filterId = useId();
  const detailed = size >= DETAIL_FROM_SIZE;

  // Each candle's wick and body share a delay: left first, then right, then the doji.
  const part = (delayMs: number, extra = ""): { className?: string; style: CSSProperties } => ({
    className: drawn === undefined ? extra || undefined : `seal-part ${extra}`.trim(),
    style: drawn === undefined ? paper : ({ ...paper, "--candle-delay": `${delayMs}ms` } as CSSProperties),
  });

  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 64 64"
      className={className}
      role={title ? "img" : undefined}
      aria-label={title || undefined}
      aria-hidden={title ? undefined : true}
      focusable="false"
      data-drawn={drawn === undefined ? undefined : drawn}
    >
      {detailed && (
        <filter id={filterId}>
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7" result="noise" />
          <feDisplacementMap in="SourceGraphic" in2="noise" scale="1.4" xChannelSelector="R" yChannelSelector="G" />
        </filter>
      )}
      <g filter={detailed ? `url(#${filterId})` : undefined}>
        <rect x="4" y="4" width="56" height="56" rx="6" style={{ fill: "var(--beni)" }} />
        {detailed && (
          <rect
            x="9"
            y="9"
            width="46"
            height="46"
            rx="3"
            fill="none"
            strokeWidth="1.6"
            style={{ stroke: "var(--paper)" }}
          />
        )}
        <rect x="17" y="18" width="2" height="28" rx="1" {...part(0)} />
        <rect x="14" y="24" width="8" height="14" rx="1" {...part(0)} />
        <rect
          x="31"
          y="15"
          width="2"
          height="34"
          rx="1"
          {...part(300, busy ? "seal-wick seal-wick-busy" : "seal-wick")}
        />
        <rect x="25" y="30.75" width="14" height="2.5" rx="1" {...part(300)} />
        {/* A hollow candle's wick stops at its body, as on a real chart. */}
        <rect x="45" y="19" width="2" height="8" rx="1" {...part(150)} />
        <rect x="45" y="39" width="2" height="8" rx="1" {...part(150)} />
        <rect
          x="42"
          y="27"
          width="8"
          height="12"
          rx="1"
          fill="none"
          strokeWidth="1.6"
          className={drawn === undefined ? undefined : "seal-part"}
          style={
            drawn === undefined
              ? { stroke: "var(--paper)" }
              : ({ stroke: "var(--paper)", "--candle-delay": "150ms" } as CSSProperties)
          }
        />
      </g>
    </svg>
  );
}

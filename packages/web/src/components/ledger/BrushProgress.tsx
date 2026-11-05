"use client";

import { useId } from "react";
import { motion } from "motion/react";

type BrushProgressProps = {
  /** From 0 to 1. */
  value: number;
  reduced: boolean;
  /** "ink" sits on the dark page, "paper" sits on washi. */
  tone: "ink" | "paper";
};

const WIDTH = 640;
const FILL_SECONDS = 1.2;
const EASE_SETTLE = [0.22, 1, 0.36, 1] as const;

// The ink thins out over this many units before the fill's end.
const FEATHER = 36;
// How far each streak row may run ahead of or behind the end, before the feather.
const END_RAGGEDNESS = 120;
// Parked well left of the stroke, so no ragged row can leak in while the fill is empty.
const PARKED_END = -120;
// A full bar pushes the feather past the stroke's tail, so 100 percent never looks unfinished.
const COMPLETE_END = WIDTH + 100;

const TONES = {
  ink: { track: "var(--ink-3)", fill: "var(--beni)" },
  paper: { track: "var(--sumi-ghost)", fill: "var(--sumi)" },
} as const;

// One long dry-brush stroke: heavy and blunt at the left, rising and tapering to a fine tail on the right.
const STROKE =
  "M 14 19.5 C 150 18.5, 400 11.5, 630 9.5 C 634 10, 636 15, 631 18.5 C 420 23, 190 32, 98 38.5 " +
  "C 60 40.5, 30 42, 14 40 C 4 38, 3 24, 14 19.5 Z";

export function BrushProgress({ value, reduced, tone }: BrushProgressProps) {
  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const filterId = `brush-${uid}`;
  const endFilterId = `brush-end-${uid}`;
  const fadeId = `brush-fade-${uid}`;
  const maskId = `brush-mask-${uid}`;
  const colours = TONES[tone];
  const clamped = Math.min(1, Math.max(0, value));
  const endX = clamped >= 1 ? COMPLETE_END : clamped * WIDTH;

  const brushed = <path d={STROKE} filter={`url(#${filterId})`} />;

  // Everything left of the end is solid, the last FEATHER units fade to nothing. It is drawn at x = 0 and moved.
  const endShape = (
    <>
      <rect x={-1400} y={-200} width={1400 - FEATHER} height={500} fill="white" />
      <rect x={-FEATHER} y={-200} width={FEATHER} height={500} fill={`url(#${fadeId})`} />
    </>
  );

  return (
    <motion.svg
      viewBox={`0 0 ${WIDTH} 44`}
      style={{ width: "100%", height: "auto", display: "block", overflow: "visible" }}
      aria-hidden="true"
      focusable="false"
      initial="empty"
      whileInView="full"
      viewport={{ once: true, amount: 0.6 }}
    >
      <defs>
        <filter id={filterId} filterUnits="userSpaceOnUse" x="-20" y="-20" width="700" height="84" colorInterpolationFilters="sRGB">
          <feTurbulence type="fractalNoise" baseFrequency="0.02 0.3" numOctaves="2" seed="6" result="rough" />
          <feDisplacementMap in="SourceGraphic" in2="rough" scale="7" xChannelSelector="R" yChannelSelector="G" result="edged" />
          <feTurbulence type="fractalNoise" baseFrequency="0.004 0.5" numOctaves="2" seed="3" result="streaks" />
          <feColorMatrix
            in="streaks"
            type="matrix"
            values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  14 0 0 0 -3.9"
            result="gaps"
          />
          <feComposite in="edged" in2="gaps" operator="in" />
        </filter>
        {/* The end of the fill: a horizontal fade whose rows are pushed forward or back by streak noise, then cut by the
            same streak gaps as the stroke, so the ink breaks into streaks instead of stopping at a line. */}
        <linearGradient id={fadeId} gradientUnits="userSpaceOnUse" x1={-FEATHER} y1="0" x2="0" y2="0">
          <stop offset="0" stopColor="white" />
          <stop offset="1" stopColor="black" />
        </linearGradient>
        <filter id={endFilterId} filterUnits="userSpaceOnUse" x="-200" y="-20" width="1100" height="84" colorInterpolationFilters="sRGB">
          <feTurbulence type="fractalNoise" baseFrequency="0.004 0.5" numOctaves="2" seed="8" result="rows" />
          <feDisplacementMap in="SourceGraphic" in2="rows" scale={END_RAGGEDNESS} xChannelSelector="R" yChannelSelector="B" result="ragged" />
          <feTurbulence type="fractalNoise" baseFrequency="0.004 0.5" numOctaves="2" seed="3" result="streaks" />
          <feColorMatrix
            in="streaks"
            type="matrix"
            values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  14 0 0 0 -3.9"
            result="gaps"
          />
          <feComposite in="ragged" in2="gaps" operator="in" />
        </filter>
        <mask id={maskId} maskUnits="userSpaceOnUse" x="-200" y="-20" width="1100" height="84">
          <g filter={`url(#${endFilterId})`}>
            {reduced ? (
              <g transform={`translate(${endX} 0)`}>{endShape}</g>
            ) : (
              <motion.g
                variants={{
                  empty: { x: PARKED_END },
                  full: { x: endX, transition: { duration: FILL_SECONDS, ease: EASE_SETTLE } },
                }}
              >
                {endShape}
              </motion.g>
            )}
          </g>
        </mask>
      </defs>
      <g style={{ fill: colours.track }}>{brushed}</g>
      <g mask={`url(#${maskId})`}>
        <g style={{ fill: colours.fill }}>{brushed}</g>
      </g>
    </motion.svg>
  );
}

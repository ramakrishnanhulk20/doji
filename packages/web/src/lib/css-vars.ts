import type { CSSProperties } from "react";

/** Passes custom properties through React's style prop, which only types known CSS names. */
export function cssVars(vars: Record<`--${string}`, string | number>): CSSProperties {
  return vars as CSSProperties;
}

import type { HeadlineChoice } from "../components/hero/copy";
import type { MotionMode } from "./motion-mode";

export type LabState = {
  type: "a" | "b";
  headline: HeadlineChoice;
  motion: MotionMode;
};

type RawParams = Record<string, string | string[] | undefined>;

function first(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

/** Reads ?type=b&h=1&motion=full. Anything unrecognised falls back to Ram's pick: Fraunces and headline 1. */
export function parseLabState(params: RawParams): LabState {
  const type = first(params.type) === "a" ? "a" : "b";
  const h = first(params.h);
  const headline: HeadlineChoice = h === "2" ? 2 : h === "3" ? 3 : 1;
  const motion: MotionMode = first(params.motion) === "reduced" ? "reduced" : "full";
  return { type, headline, motion };
}

export function labStateToSearch(state: LabState): string {
  const params = new URLSearchParams({ type: state.type, h: String(state.headline), motion: state.motion });
  return `?${params.toString()}`;
}

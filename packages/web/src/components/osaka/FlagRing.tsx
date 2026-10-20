import { FLAG_LABEL } from "./copy";

type FlagRingProps = {
  /** Anchor point as a percentage of the box the ring sits in. */
  x: number;
  y: number;
};

export function FlagRing({ x, y }: FlagRingProps) {
  return (
    <div className="flag-ring" style={{ left: `${x}%`, top: `${y}%` }} aria-hidden="true">
      <span className="flag-ring-circle" />
      <span className="flag-ring-leader" />
      <span className="flag-ring-label">{FLAG_LABEL}</span>
    </div>
  );
}

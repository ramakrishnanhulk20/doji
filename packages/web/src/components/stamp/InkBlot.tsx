import { useId } from "react";

// The viewBox matches the largest blot (1.6 times a 300px seal), so the noise and the 18px displacement are
// true pixels there and scale down with the seal on narrower screens.
export function InkBlot({ className }: { className?: string }) {
  const filterId = useId();

  return (
    <svg className={className} viewBox="0 0 480 480" aria-hidden="true" focusable="false">
      <filter id={filterId} x="-25%" y="-25%" width="150%" height="150%">
        <feTurbulence type="fractalNoise" baseFrequency="0.04" numOctaves="2" seed="5" result="noise" />
        <feDisplacementMap in="SourceGraphic" in2="noise" scale="18" xChannelSelector="R" yChannelSelector="G" />
      </filter>
      <circle cx="240" cy="240" r="190" filter={`url(#${filterId})`} style={{ fill: "var(--beni)" }} />
    </svg>
  );
}

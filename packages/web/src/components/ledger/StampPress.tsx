"use client";

import { useEffect, useRef, type ReactNode } from "react";
import "./ledger.css";

type StampPressProps = {
  /** The seal. It is drawn three times: the stamp, its shadow and its ink bleed. */
  children: ReactNode;
  stamped: boolean;
  onLanded?: () => void;
  reduced: boolean;
};

const FALL_MS = 170;
const SETTLE_MS = 250;
const TOTAL_MS = FALL_MS + SETTLE_MS;
const SHEET_DOWN_MS = 70;
const SHEET_BACK_MS = 180;
const EASE_PRESS = "cubic-bezier(0.55, 0, 1, 0.45)";
const EASE_SETTLE = "cubic-bezier(0.22, 1, 0.36, 1)";

export function StampPress({ children, stamped, onLanded, reduced }: StampPressProps) {
  const rootRef = useRef<HTMLDivElement>(null);
  const sealRef = useRef<HTMLDivElement>(null);
  const shadowRef = useRef<HTMLDivElement>(null);
  const bleedRef = useRef<HTMLDivElement>(null);
  const landedRef = useRef(onLanded);

  useEffect(() => {
    landedRef.current = onLanded;
  }, [onLanded]);

  useEffect(() => {
    if (!stamped) return;
    if (reduced) {
      landedRef.current?.();
      return;
    }

    const root = rootRef.current;
    const seal = sealRef.current;
    const shadow = shadowRef.current;
    const bleed = bleedRef.current;
    if (!root || !seal || !shadow || !bleed) return;

    // The caller sets --tilt on an ancestor. WAAPI keyframes get the resolved value so no variable lookup is needed.
    const tilt = getComputedStyle(root).getPropertyValue("--tilt").trim() || "0deg";
    const rest = `rotate(${tilt})`;
    const impact = FALL_MS / TOTAL_MS;

    const animations: Animation[] = [
      seal.animate(
        [
          {
            transform: `translateY(-90px) scale(1.45) rotate(calc(${tilt} + 2deg))`,
            opacity: 0.4,
            easing: EASE_PRESS,
            offset: 0,
          },
          { transform: `translateY(0px) scale(0.97) ${rest}`, opacity: 1, easing: EASE_SETTLE, offset: impact },
          { transform: `translateY(0px) scale(1) ${rest}`, opacity: 1, offset: 1 },
        ],
        { duration: TOTAL_MS },
      ),
      // The shadow tightens and darkens as the seal comes down, then is gone once ink is on the paper.
      shadow.animate(
        [
          { transform: `translateY(14px) scale(1.4) ${rest}`, opacity: 0.1, filter: "brightness(0) blur(12px)", easing: EASE_PRESS, offset: 0 },
          { transform: `translateY(2px) scale(1) ${rest}`, opacity: 0.38, filter: "brightness(0) blur(4px)", offset: impact },
          { transform: `translateY(2px) scale(1) ${rest}`, opacity: 0, filter: "brightness(0) blur(4px)", offset: 1 },
        ],
        { duration: TOTAL_MS },
      ),
      // The ink ring only exists after impact, so the layer stays hidden by its own style until the delay ends.
      bleed.animate(
        [
          { transform: `scale(1) ${rest}`, opacity: 0.35 },
          { transform: `scale(1.06) ${rest}`, opacity: 0 },
        ],
        { delay: FALL_MS, duration: SETTLE_MS, easing: EASE_SETTLE },
      ),
    ];

    // The page the seal lands on gives a little under the hit.
    const sheet = root.closest(".ledger-sheet");
    if (sheet) {
      const total = SHEET_DOWN_MS + SHEET_BACK_MS;
      animations.push(
        sheet.animate(
          [
            { transform: "translateY(0px)", easing: "ease-out", offset: 0 },
            { transform: "translateY(2px)", easing: EASE_SETTLE, offset: SHEET_DOWN_MS / total },
            { transform: "translateY(0px)", offset: 1 },
          ],
          { delay: FALL_MS, duration: total },
        ),
      );
    }

    const timer = window.setTimeout(() => landedRef.current?.(), FALL_MS);
    return () => {
      window.clearTimeout(timer);
      animations.forEach((animation) => animation.cancel());
    };
  }, [stamped, reduced]);

  return (
    <div ref={rootRef} className="ledger-press" data-stamped={stamped}>
      <div ref={shadowRef} className="ledger-press-shadow" aria-hidden="true">
        {children}
      </div>
      <div ref={bleedRef} className="ledger-press-bleed" aria-hidden="true">
        {children}
      </div>
      <div ref={sealRef} className="ledger-press-seal">
        {children}
      </div>
    </div>
  );
}

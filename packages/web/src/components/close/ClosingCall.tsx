"use client";

import { useEffect, useRef } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { usePrefersReducedMotion } from "../../lib/motion-mode";
import { Button } from "../Button";
import { HEADLINES, PRINT_SOURCES } from "../hero/copy";
import { Seal } from "../Seal";

// The background moves at 0.3 of the page's speed, so it lags by the rest of what is scrolled.
const PARALLAX_SHARE = 0.3;
const PARALLAX_MIN_WIDTH = 768;
const CLOSING_SIZES = "100vw";

export function ClosingCall() {
  const rootRef = useRef<HTMLElement>(null);
  const reduced = usePrefersReducedMotion();

  useEffect(() => {
    const root = rootRef.current;
    if (!root || reduced) return;

    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();

    mm.add(`(min-width: ${PARALLAX_MIN_WIDTH}px)`, () => {
      const travel = () => window.innerHeight + root.offsetHeight;

      const trigger = ScrollTrigger.create({
        trigger: root,
        start: "top bottom",
        end: "bottom top",
        onRefresh: () => root.style.setProperty("--over", `${(travel() * PARALLAX_SHARE) / 2}px`),
        onUpdate: (self) =>
          root.style.setProperty("--bg-y", `${(self.progress - 0.5) * travel() * PARALLAX_SHARE}px`),
      });

      return () => {
        trigger.kill();
        root.style.removeProperty("--over");
        root.style.removeProperty("--bg-y");
      };
    });

    return () => mm.revert();
  }, [reduced]);

  return (
    <section id="close" ref={rootRef} className="closing">
      <div className="closing-bg" aria-hidden="true">
        <picture>
          <source type="image/avif" srcSet={PRINT_SOURCES.avif} sizes={CLOSING_SIZES} />
          <source type="image/webp" srcSet={PRINT_SOURCES.webp} sizes={CLOSING_SIZES} />
          <img src="/art/dojima-1600.jpg" alt="" width={2400} height={1004} loading="lazy" decoding="async" />
        </picture>
      </div>
      <div className="closing-overlay" aria-hidden="true" />
      <div className="closing-grain grain" aria-hidden="true" />

      <div className="closing-content">
        <Seal size={72} title="" />
        <h2 className="closing-title display-face">{HEADLINES[1].join(" ")}</h2>
        <div className="closing-actions">
          <Button href="/borrow" arrow>
            Borrow MUSD
          </Button>
          <Button href="/lend" variant="secondary">
            Lend MUSD
          </Button>
        </div>
        <a
          className="link-draw closing-note"
          href="https://faucet.test.mezo.org"
          target="_blank"
          rel="noopener noreferrer"
        >
          Mezo testnet · test BTC from faucet.test.mezo.org
        </a>
      </div>
    </section>
  );
}

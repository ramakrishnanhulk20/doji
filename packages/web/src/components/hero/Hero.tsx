"use client";

import { useEffect, useRef } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { usePrefersReducedMotion, type MotionMode } from "../../lib/motion-mode";
import { CreditsRow } from "./CreditsRow";
import type { HeadlineChoice } from "./copy";
import { HeroNav } from "./HeroNav";
import { PrintStage } from "./PrintStage";
import { TitleBlock } from "./TitleBlock";
import "./hero.css";

export type HeroProps = {
  type: "a" | "b";
  headline: HeadlineChoice;
  motion: MotionMode;
  /** Changing this number plays the entrance again. */
  replayKey?: number;
};

export function Hero({ type, headline, motion, replayKey = 0 }: HeroProps) {
  const rootRef = useRef<HTMLElement>(null);
  const prefersReduced = usePrefersReducedMotion();
  const reduced = motion === "reduced" || prefersReduced;

  // Scroll progress goes into a CSS variable, so the parallax, the pan and the fades never re-render React.
  useEffect(() => {
    const root = rootRef.current;
    if (!root || reduced) return;

    gsap.registerPlugin(ScrollTrigger);
    const trigger = ScrollTrigger.create({
      trigger: root,
      start: "top top",
      end: "bottom top",
      scrub: true,
      onUpdate: (self) => root.style.setProperty("--p", self.progress.toFixed(4)),
    });

    return () => {
      trigger.kill();
      root.style.removeProperty("--p");
    };
  }, [reduced]);

  return (
    <section
      ref={rootRef}
      className="hero"
      data-type={type}
      data-motion={motion === "reduced" ? "reduced" : "auto"}
    >
      <div key={replayKey} className="hero-replay">
        <PrintStage />
        <HeroNav />
        <TitleBlock headline={headline} />
        <CreditsRow reduced={reduced} />
      </div>
      <div className="layer layer-bottom" aria-hidden="true" />
      <div className="layer layer-left" aria-hidden="true" />
      <div className="layer layer-vignette" aria-hidden="true" />
      <div className="layer layer-top" aria-hidden="true" />
      <div className="layer layer-grain grain" aria-hidden="true" />
    </section>
  );
}

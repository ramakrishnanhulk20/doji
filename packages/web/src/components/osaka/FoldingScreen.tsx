"use client";

import { useEffect, useRef } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { usePrefersReducedMotion, type MotionMode } from "../../lib/motion-mode";
import { PRINT_ALT, PRINT_SOURCES } from "../hero/copy";
import {
  FLAG_ANCHOR,
  FLAG_LABEL,
  FLAG_PANEL_ANCHOR,
  FLAT_SIZES,
  FOLD_CLOSE,
  FOLD_KANJI,
  FOLD_LABEL,
  FOLD_LEFT,
  FOLD_RIGHT,
  FOLD_TITLE,
} from "./copy";
import { FlagRing } from "./FlagRing";
import "./osaka.css";

const PANEL_COUNT = 6;
const FOLD_ANGLE = 62;

// The pinned 3D screen needs this much width; narrower screens get the flat, stacked version.
const PINNED_FROM = 1100;
const SCROLL_VARS = ["--theta", "--fade", "--s", "--ring", "--cols", "--close"] as const;

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));
const span = (value: number, from: number, to: number) => clamp01((value - from) / (to - from));

type PanelProps = { index: number };

// Each panel holds the next one at its right edge, so one angle per panel folds the whole screen like an accordion.
function Panel({ index }: PanelProps) {
  const parity = index % 2 === 0 ? "even" : "odd";
  return (
    <div className={`fold-panel fold-panel-${parity}${index === 0 ? " fold-panel-first" : ""}`}>
      <div className="fold-face">
        <div className="fold-art" style={{ backgroundPositionX: `${index * 20}%` }} />
        <div className="fold-shade" />
      </div>
      {index < PANEL_COUNT - 1 && <Panel index={index + 1} />}
      {index === 4 && <FlagRing x={FLAG_PANEL_ANCHOR.x} y={FLAG_PANEL_ANCHOR.y} />}
    </div>
  );
}

export function FoldingScreen({ motion }: { motion: MotionMode }) {
  const rootRef = useRef<HTMLElement>(null);
  const prefersReduced = usePrefersReducedMotion();
  const reduced = motion === "reduced" || prefersReduced;

  useEffect(() => {
    const root = rootRef.current;
    if (!root || reduced) return;

    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();

    mm.add(`(min-width: ${PINNED_FROM}px)`, () => {
      const ease = gsap.parseEase("power2.inOut");

      // Progress goes into CSS variables, so the fold never re-renders React.
      const apply = (p: number) => {
        let theta = 0;
        if (p >= 0.14 && p < 0.5) theta = FOLD_ANGLE * ease(span(p, 0.14, 0.5));
        else if (p >= 0.5 && p < 0.75) theta = FOLD_ANGLE;
        else if (p >= 0.75 && p < 0.95) theta = FOLD_ANGLE * (1 - ease(span(p, 0.75, 0.95)));

        const ring = span(p, 0.04, 0.07) * (1 - span(p, 0.13, 0.16));
        const cols = span(p, 0.4, 0.55) * (1 - span(p, 0.75, 0.85));

        root.style.setProperty("--theta", theta.toFixed(3));
        root.style.setProperty("--fade", span(p, 0, 0.12).toFixed(4));
        root.style.setProperty("--s", (0.94 + 0.06 * span(p, 0, 0.12)).toFixed(4));
        root.style.setProperty("--ring", ring.toFixed(4));
        root.style.setProperty("--cols", cols.toFixed(4));
        root.style.setProperty("--close", span(p, 0.85, 1).toFixed(4));
      };

      const trigger = ScrollTrigger.create({
        trigger: root,
        start: "top top",
        end: "bottom bottom",
        onUpdate: (self) => apply(self.progress),
        onRefresh: (self) => apply(self.progress),
      });

      return () => {
        trigger.kill();
        SCROLL_VARS.forEach((name) => root.style.removeProperty(name));
      };
    });

    mm.add(`(max-width: ${PINNED_FROM - 1}px)`, () => {
      const blocks = root.querySelectorAll<HTMLElement>(".reveal");
      const observer = new IntersectionObserver(
        (entries) => {
          for (const entry of entries) {
            if (!entry.isIntersecting) continue;
            entry.target.classList.add("is-in");
            observer.unobserve(entry.target);
          }
        },
        { threshold: 0.2 },
      );
      blocks.forEach((block) => observer.observe(block));

      return () => {
        observer.disconnect();
        blocks.forEach((block) => block.classList.remove("is-in"));
      };
    });

    return () => mm.revert();
  }, [reduced]);

  return (
    <section id="osaka" ref={rootRef} className="fold" data-motion={motion === "reduced" ? "reduced" : "auto"}>
      <div className="fold-frame">
        <header className="fold-heading">
          <p className="fold-label">{FOLD_LABEL}</p>
          <h2 className="fold-title display-face">
            {FOLD_TITLE}{" "}
            <span className="fold-kanji" lang="ja">
              {FOLD_KANJI}
            </span>
          </h2>
        </header>

        <div className="fold-stage">
          <div className="fold-screen" role="img" aria-label={PRINT_ALT}>
            <Panel index={0} />
          </div>
          <div className="fold-floor" aria-hidden="true" />
        </div>

        <figure className="fold-flat">
          <div className="fold-flat-picture">
            <picture>
              <source type="image/avif" srcSet={PRINT_SOURCES.avif} sizes={FLAT_SIZES} />
              <source type="image/webp" srcSet={PRINT_SOURCES.webp} sizes={FLAT_SIZES} />
              <img
                className="fold-flat-image"
                src="/art/dojima-1600.jpg"
                alt={PRINT_ALT}
                width={2400}
                height={1004}
                loading="lazy"
                decoding="async"
              />
            </picture>
            <FlagRing x={FLAG_ANCHOR.x} y={FLAG_ANCHOR.y} />
          </div>
          <figcaption className="fold-flag-caption">{FLAG_LABEL}</figcaption>
        </figure>

        <div className="fold-cols">
          <div className="fold-col fold-col-left reveal">
            <h3 className="fold-col-heading display-face">{FOLD_LEFT.heading}</h3>
            <p className="fold-col-body">{FOLD_LEFT.body}</p>
          </div>
          <div className="fold-col fold-col-right reveal">
            <h3 className="fold-col-heading display-face">{FOLD_RIGHT.heading}</h3>
            <p className="fold-col-body">{FOLD_RIGHT.body}</p>
          </div>
        </div>

        <p className="fold-close display-face reveal">{FOLD_CLOSE}</p>
      </div>
    </section>
  );
}

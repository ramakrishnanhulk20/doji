"use client";

import { useInViewOnce } from "../../hooks/useInViewOnce";
import { useReducedMotion } from "../../lib/motion-mode";
import { Reveal } from "../landing/Reveal";
import { Seal } from "../Seal";

export function NameBand() {
  const reduced = useReducedMotion();
  const [ref, seen] = useInViewOnce<HTMLDivElement>(0.4);

  return (
    <section id="name" className="section">
      <div ref={ref} className="section-inner name-grid">
        <div className="name-seal">
          <Seal size={160} title="" drawn={reduced || seen} />
        </div>
        <Reveal className="name-copy">
          <p className="label-mono">Why the name</p>
          <h2 className="section-title display-face">
            Doji,{" "}
            <span className="section-kanji" lang="ja">
              同時
            </span>
            : at the same time.
          </h2>
          <p className="section-body">
            Dōji means at the same time. Your Bitcoin stays locked and earning while you borrow against it.
          </p>
          <p className="section-body">
            A doji is also a candlestick: the day the price opens and closes at the same level. The candlestick chart is
            credited to the rice traders of Dōjima, where this story starts.
          </p>
        </Reveal>
      </div>
    </section>
  );
}

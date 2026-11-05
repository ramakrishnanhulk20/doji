"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { useReducedMotion } from "../../lib/motion-mode";
import { Button } from "../Button";
import { Seal } from "../Seal";
import { BrushProgress } from "./BrushProgress";
import { PaperSheet } from "./PaperSheet";
import { RANK_KANJI, RankSeal, type Rank } from "./RankSeal";
import { StampPress } from "./StampPress";
import "./ledger.css";

const RANKS: { rank: Rank; name: string; meaning: string; exp: string; tilt: number }[] = [
  { rank: "decchi", name: "Decchi", meaning: "the apprentice", exp: "0 EXP", tilt: -2 },
  { rank: "tedai", name: "Tedai", meaning: "the clerk", exp: "300 EXP", tilt: 1 },
  { rank: "banto", name: "Banto", meaning: "the head clerk", exp: "800 EXP", tilt: -1 },
  { rank: "nakagai", name: "Nakagai", meaning: "the broker", exp: "1,400 EXP", tilt: 2 },
  { rank: "ryogaesho", name: "Ryogaesho", meaning: "the money changer", exp: "2,000 EXP", tilt: -1 },
  { rank: "sobashi", name: "Sobashi", meaning: "the market master", exp: "2,500 EXP", tilt: 1 },
];

const REPLAY_GAP_MS = 140;

type PressDemoProps = {
  buttonLabel: string;
  size: number;
  /** Where the visible seal shape sits inside its square, so the empty outline hugs it. */
  outline: { inset: number; side: number; radius: number };
  reduced: boolean;
  children: ReactNode;
};

function PressDemo({ buttonLabel, size, outline, reduced, children }: PressDemoProps) {
  const [stamped, setStamped] = useState(false);
  const timer = useRef(0);

  useEffect(() => () => window.clearTimeout(timer.current), []);

  // A second press lifts the seal first, so the fall plays from the start again.
  const press = () => {
    window.clearTimeout(timer.current);
    if (!stamped) {
      setStamped(true);
      return;
    }
    setStamped(false);
    timer.current = window.setTimeout(() => setStamped(true), REPLAY_GAP_MS);
  };

  return (
    <PaperSheet className="ledger-sheet ledger-press-sheet">
      <div className="ledger-press-stage">
        <span className="ledger-brush-kanji" lang="ja">
          借
        </span>
        <div className="ledger-press-spot" style={{ width: size, height: size, "--tilt": "-3deg" } as CSSProperties}>
          <span
            className="ledger-press-outline"
            aria-hidden="true"
            style={{
              left: outline.inset,
              top: outline.inset,
              width: outline.side,
              height: outline.side,
              borderRadius: outline.radius,
              transform: "rotate(-3deg)",
            }}
          />
          <div className="ledger-press-seat">
            <StampPress stamped={stamped} reduced={reduced}>
              {children}
            </StampPress>
          </div>
        </div>
      </div>
      <Button onClick={press}>{buttonLabel}</Button>
    </PaperSheet>
  );
}

export function LabLedger() {
  const reduced = useReducedMotion();

  return (
    <main className="ledger ledger-lab">
      <div className="ledger-lab-inner">
        <h1 className="display-face ledger-lab-title">The ledger: materials</h1>

        <section className="ledger-lab-section">
          <h2 className="label-mono ledger-lab-label">Rank seals</h2>
          <PaperSheet>
            <div className="ledger-seal-grid">
              {RANKS.map(({ rank, name, meaning, exp, tilt }) => (
                <div key={rank} className="ledger-seal-cell">
                  <span className="ledger-seal-tilt" style={{ transform: `rotate(${tilt}deg)` }}>
                    <RankSeal rank={rank} size={148} title={name} />
                  </span>
                  <span className="ledger-seal-kanji" lang="ja">
                    {RANK_KANJI[rank]}
                  </span>
                  <span className="ledger-seal-name">{name}</span>
                  <span className="ledger-seal-meaning">{meaning}</span>
                  <span className="ledger-seal-exp">{exp}</span>
                </div>
              ))}
            </div>
          </PaperSheet>
        </section>

        <section className="ledger-lab-section">
          <h2 className="label-mono ledger-lab-label">Sizes</h2>
          <PaperSheet>
            <div className="ledger-size-row">
              {RANKS.map(({ rank, name }) => (
                <RankSeal key={rank} rank={rank} size={64} title={name} />
              ))}
            </div>
            <div className="ledger-size-row">
              {RANKS.map(({ rank, name }) => (
                <RankSeal key={rank} rank={rank} size={28} title={name} />
              ))}
            </div>
          </PaperSheet>
          <div className="ledger-size-row ledger-size-bare">
            {RANKS.map(({ rank, name }) => (
              <RankSeal key={rank} rank={rank} size={64} title={name} />
            ))}
          </div>
        </section>

        <section className="ledger-lab-section">
          <h2 className="label-mono ledger-lab-label">The press</h2>
          <div className="ledger-press-row">
            <PressDemo
              buttonLabel="Press the seal"
              size={72}
              outline={{ inset: 4.5, side: 63, radius: 6.75 }}
              reduced={reduced}
            >
              <Seal size={72} title="Doji" />
            </PressDemo>
            <PressDemo
              buttonLabel="Rank up"
              size={148}
              outline={{ inset: 10.4, side: 127.3, radius: 3 }}
              reduced={reduced}
            >
              <RankSeal rank="banto" size={148} title="Banto" />
            </PressDemo>
          </div>
        </section>

        <section className="ledger-lab-section">
          <h2 className="label-mono ledger-lab-label">The stroke</h2>
          <div className="ledger-stroke-list">
            <BrushProgress value={0.15} reduced={reduced} tone="ink" />
            <BrushProgress value={0.6} reduced={reduced} tone="ink" />
            <BrushProgress value={1} reduced={reduced} tone="ink" />
          </div>
          <PaperSheet className="ledger-stroke-paper">
            <BrushProgress value={0.6} reduced={reduced} tone="paper" />
          </PaperSheet>
        </section>
      </div>
    </main>
  );
}

"use client";

import { useEffect, useRef, useState } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { usePrefersReducedMotion, type MotionMode } from "../../lib/motion-mode";
import { ArrowOut } from "../ArrowOut";
import { Seal } from "../Seal";
import {
  FAQ_URL,
  STAMP_BODY_AFTER,
  STAMP_BODY_BEFORE,
  STAMP_LABEL,
  STAMP_QUESTION,
  STAMP_TIME,
} from "./copy";
import { InkBlot } from "./InkBlot";
import { LoanCard } from "./LoanCard";
import "./stamp.css";

// Scroll progress at which the seal lands, and the lower edge that arms it again on the way back up.
const IMPACT_AT = 0.32;
const RESET_BELOW = 0.28;
const PHONE_DROP_MS = 260;

// The stacked layout (no pin) takes over below this width.
const PINNED_FROM = 1180;

// The seal's centre sits this far in from the answer's right edge and down from its top, as a share of the seal.
const SEAL_INSET_X = 0.1;
const SEAL_DROP_Y = 0.3;

const clamp01 = (value: number) => Math.min(1, Math.max(0, value));

export function StampMoment({ motion }: { motion: MotionMode }) {
  const rootRef = useRef<HTMLElement>(null);
  const frameRef = useRef<HTMLDivElement>(null);
  const answerRef = useRef<HTMLDivElement>(null);
  const noRef = useRef<HTMLSpanElement>(null);
  const yesRef = useRef<HTMLSpanElement>(null);
  const sealRef = useRef<HTMLDivElement>(null);
  const prefersReduced = usePrefersReducedMotion();
  const reduced = motion === "reduced" || prefersReduced;
  const [struck, setStruck] = useState(false);
  const [dropped, setDropped] = useState(false);

  // The seal lands on the answer's top-right corner. The answer cell is as wide as the wider of "No." and "Yes.",
  // so the corner is measured again whenever the words move or resize.
  useEffect(() => {
    const root = rootRef.current;
    const frame = frameRef.current;
    const answer = answerRef.current;
    const no = noRef.current;
    const yes = yesRef.current;
    const seal = sealRef.current;
    if (!root || !frame || !answer || !no || !yes || !seal) return;

    const measure = () => {
      const frameBox = frame.getBoundingClientRect();
      const answerBox = answer.getBoundingClientRect();
      const right = Math.max(no.getBoundingClientRect().right, yes.getBoundingClientRect().right);
      const size = seal.offsetWidth;
      root.style.setProperty("--seal-x", `${right - SEAL_INSET_X * size - frameBox.left}px`);
      root.style.setProperty("--seal-y", `${answerBox.top + SEAL_DROP_Y * size - frameBox.top}px`);
    };

    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(frame);
    observer.observe(answer);
    observer.observe(no);
    observer.observe(yes);
    void document.fonts.ready.then(measure);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || reduced) return;

    gsap.registerPlugin(ScrollTrigger);
    const mm = gsap.matchMedia();

    mm.add(`(min-width: ${PINNED_FROM}px)`, () => {
      let hit = false;

      // Progress goes into CSS variables, so the descent and the card never re-render React.
      const apply = (progress: number) => {
        root.style.setProperty("--d", clamp01((progress - 0.1) / 0.22).toFixed(4));
        root.style.setProperty("--g", clamp01((progress - 0.2) / 0.15).toFixed(4));
        root.style.setProperty("--c", clamp01((progress - 0.36) / 0.1).toFixed(4));
        if (!hit && progress >= IMPACT_AT) {
          hit = true;
          setStruck(true);
        } else if (hit && progress < RESET_BELOW) {
          hit = false;
          setStruck(false);
        }
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
        ["--d", "--g", "--c"].forEach((name) => root.style.removeProperty(name));
        setStruck(false);
      };
    });

    mm.add(`(max-width: ${PINNED_FROM - 1}px)`, () => {
      let hit = false;
      let timer = 0;

      const check = () => {
        const word = noRef.current;
        if (!word) return;
        const box = word.getBoundingClientRect();
        const centre = box.top + box.height / 2;
        const height = window.innerHeight;

        if (!hit && centre <= height * 0.45) {
          hit = true;
          setDropped(true);
          timer = window.setTimeout(() => setStruck(true), PHONE_DROP_MS);
        } else if (hit && centre > height * 0.6) {
          hit = false;
          window.clearTimeout(timer);
          setDropped(false);
          setStruck(false);
        }
      };

      const trigger = ScrollTrigger.create({
        trigger: root,
        start: "top bottom",
        end: "bottom top",
        onUpdate: check,
        onRefresh: check,
      });

      // The card loads after the page, so the stacked layout grows and the trigger needs its new bounds.
      const resize = new ResizeObserver(() => ScrollTrigger.refresh());
      resize.observe(root);

      return () => {
        resize.disconnect();
        trigger.kill();
        window.clearTimeout(timer);
        setDropped(false);
        setStruck(false);
      };
    });

    return () => mm.revert();
  }, [reduced]);

  return (
    <section
      id="stamp"
      ref={rootRef}
      className="stamp"
      data-motion={motion === "reduced" ? "reduced" : "auto"}
      data-struck={struck}
      data-dropped={dropped}
    >
      <div ref={frameRef} className="stamp-frame">
        <div className="stamp-glow" aria-hidden="true" />

        <div className="stamp-left">
          <a className="stamp-label link-draw" href={FAQ_URL} target="_blank" rel="noopener noreferrer">
            {STAMP_LABEL}
            <ArrowOut />
          </a>
          <h2 className="stamp-question display-face">{STAMP_QUESTION}</h2>
          <div ref={answerRef} className="stamp-answer display-face">
            <span ref={noRef} className="stamp-no">
              No.
            </span>
            <span ref={yesRef} className="stamp-yes">
              Yes.
            </span>
          </div>
          <p className="stamp-time display-face">
            <span className="stamp-time-text">{STAMP_TIME}</span>{" "}
            <span className="stamp-kanji" lang="ja">
              同時
            </span>
          </p>
          <div className="stamp-body">
            <p className="stamp-body-before">{STAMP_BODY_BEFORE}</p>
            <p className="stamp-body-after">{STAMP_BODY_AFTER}</p>
          </div>
        </div>

        <div className="stamp-blot" aria-hidden="true">
          <InkBlot className="stamp-blot-svg" />
        </div>
        <div ref={sealRef} className="stamp-seal" aria-hidden="true">
          <div className="stamp-seal-squash">
            <Seal size={200} title="" className="stamp-seal-svg" />
          </div>
        </div>

        <LoanCard struck={struck || reduced} reduced={reduced} />
      </div>
    </section>
  );
}

"use client";

import { useCallback, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useMatchMedia } from "../../hooks/useMatchMedia";
import type { WalletProgress } from "../../lib/quests/exp";
import type { QuestId } from "../../lib/quests/table";
import { useReducedMotion } from "../../lib/motion-mode";
import { CHAPTERS, entriesOf, type ChapterInfo, type Entry } from "./chapters";
import { InstructionSlip } from "./InstructionSlip";
import { LedgerCover, ThreadBinding } from "./LedgerCover";
import { LedgerPage, LedgerSpread } from "./LedgerSpread";
import { PaperSheet } from "./PaperSheet";
import type { Rank } from "./RankSeal";
import "./ledger.css";

// The book needs a laptop: wide enough for two 560px pages and tall enough that 680px still fits with its margins.
const ROOMY = "(min-width: 1024px) and (min-height: 680px)";

const BOOK_WIDTH = 1120;
const BOOK_HEIGHT = 680;
const BOOK_MARGIN = 40;

// All times below are in screen heights of scroll: 1 is one 100vh.
const OPEN_LENGTH = 1;
const HEAD_FADE = 0.3;
const COVER_START = 0.3;
const COVER_LANDS_AT = 178;
const FADE_IN_LENGTH = 0.12;
const SETTLE_LENGTH = 0.04;

// The book stands still for a tenth of a turn at each end of every turn and after the cover lands, so a reader who stops
// near a spread rests on it.
const HOLD = 0.1;
const COVER_END = OPEN_LENGTH - HOLD;
const TURN_LENGTH = 1 - 2 * HOLD;

// At rest the closed book's right edge sits 8vw from the screen edge, so the box centre is 42vw right of the screen centre.
const REST_SHIFT = 0.42;
const REST_TILT = -3;

const SCRUB = 0.6;
const SHADE_PEAK = 0.35;
const LIGHT_PEAK = 0.22;

// How long the book must hold still before its pages take clicks again.
const IDLE_MS = 160;

// The right page on the cover's inside face only takes clicks once it has faded in.
const RIGHT_ONE_LIVE_AT = COVER_END - 0.01;

const HEADLINE = "The merchant's ledger.";
const HEADLINE_LABEL = "Doji quests";
const HEADLINE_BODY =
  "Try Doji with free test tokens. Every quest you finish earns a red seal in your ledger, and seals earn EXP that raises your rank.";
const SCROLL_HINT = "Scroll to turn the page";

type ChapterEntries = { chapter: ChapterInfo; entries: Entry[] };
type OpenEntry = (id: QuestId) => void;

function Headline() {
  return (
    <>
      <p className="ledger-stage-label">{HEADLINE_LABEL}</p>
      <h2 className="ledger-stage-title display-face">{HEADLINE}</h2>
      <p className="ledger-stage-body">{HEADLINE_BODY}</p>
    </>
  );
}

type StagePageProps = {
  side: "left" | "right";
  /** The chapter's number from 1. It names the page for the click and focus switch. */
  index: number;
  chapter: ChapterEntries;
  onOpen: OpenEntry;
};

function StagePage({ side, index, chapter, onOpen }: StagePageProps) {
  const name = `${side}-${index}`;
  return (
    <div className="ledger-stage-page" data-page={name}>
      <LedgerPage side={side} chapter={chapter.chapter} entries={chapter.entries} onOpen={onOpen} />
      <span className="ledger-stage-shade" data-side={side} data-shade={name} aria-hidden="true" />
    </div>
  );
}

type StageProps = { rank: Rank; chapters: ChapterEntries[]; onOpen: OpenEntry };

const subscribeToNothing = () => () => {};

/** False on the server and on the first client render, true once the page has hydrated. */
function useHydrated(): boolean {
  return useSyncExternalStore(subscribeToNothing, () => true, () => false);
}

// With no script the flat pages must show even on a laptop, where the stylesheet hides them until the script has chosen.
const SHOW_FLAT_WITHOUT_SCRIPT = "<style>.ledger-stage-flat{visibility:visible!important;min-height:0!important}</style>";

// The book. A leaf is the cover or one page: it hangs on the spine and turns about it. Its front is what shows on the left,
// its back is what shows once it has landed on the right.
function PinnedStage({ rank, chapters, onOpen }: StageProps) {
  const rootRef = useRef<HTMLElement>(null);
  const count = chapters.length;

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    gsap.registerPlugin(ScrollTrigger);

    const pick = (selector: string): HTMLElement => {
      const found = root.querySelector<HTMLElement>(selector);
      if (!found) throw new Error(`The ledger stage is missing ${selector}`);
      return found;
    };
    const pickAll = (selector: string) => Array.from(root.querySelectorAll<HTMLElement>(selector));

    const frame = pick("[data-stage-frame]");
    const head = pick("[data-stage-head]");
    const headInner = pick("[data-stage-head-inner]");
    const drop = pick("[data-stage-drop]");
    const book = pick("[data-stage-book]");
    const groundRight = pick("[data-stage-ground-right]");
    const hint = pick("[data-stage-hint]");
    const cord = pick(".ledger-cover-cord");
    const pages = pickAll("[data-page]");
    const leaves = Array.from({ length: count }, (_, k) => pick(`[data-leaf="${k}"]`));
    const cover = leaves[0];
    if (!cover) return;
    const lightOf = (k: number) => pickAll(`[data-light="${k}"]`);
    const shadeOf = (name: string) => pick(`[data-shade="${name}"]`);

    // The 680px book scales as one piece to leave 40px around it, so every inner length stays in book pixels.
    const fit = () => {
      const scale = Math.min(
        1,
        (frame.clientWidth - 2 * BOOK_MARGIN) / BOOK_WIDTH,
        (frame.clientHeight - 2 * BOOK_MARGIN) / BOOK_HEIGHT,
      );
      frame.style.setProperty("--ledger-fit", scale.toFixed(4));
    };
    fit();
    const watch = new ResizeObserver(fit);
    watch.observe(frame);

    // The page spread on show is the number of leaves past the halfway turn. Only its two pages take focus and clicks.
    const flips = [COVER_START + (COVER_END - COVER_START) / 2, ...Array.from({ length: count - 1 }, (_, i) => i + 1.5)];
    let lastKey = -1;
    let idle = 0;
    const track = (time: number) => {
      const spread = flips.filter((at) => time >= at).length;
      const rightOneLive = time >= RIGHT_ONE_LIVE_AT;
      const key = spread * 2 + (rightOneLive ? 1 : 0);
      if (key !== lastKey) {
        lastKey = key;
        for (const page of pages) {
          const [side, index] = (page.dataset.page ?? "").split("-");
          const waiting = side === "right" && Number(index) === 1 && !rightOneLive;
          page.inert = Number(index) !== spread || waiting;
        }
      }
      book.dataset.moving = "true";
      window.clearTimeout(idle);
      idle = window.setTimeout(() => {
        delete book.dataset.moving;
      }, IDLE_MS);
    };

    let intro: gsap.core.Timeline | undefined;
    const ctx = gsap.context(() => {
      const tl = gsap.timeline({
        defaults: { ease: "none" },
        onUpdate: () => track(tl.time()),
        scrollTrigger: {
          trigger: root,
          start: "top top",
          end: "bottom bottom",
          scrub: SCRUB,
          invalidateOnRefresh: true,
        },
      });

      // A soft shadow that grows to its peak and fades again as a leaf passes, with the same shape for the light on the leaf.
      const pulse = (targets: HTMLElement | HTMLElement[], at: number, length: number, peak: number) => {
        tl.fromTo(targets, { opacity: 0 }, { opacity: peak, duration: length / 2, ease: "sine.out" }, at).to(
          targets,
          { opacity: 0, duration: length / 2, ease: "sine.in" },
          at + length / 2,
        );
      };

      tl.fromTo(head, { opacity: 1, y: 0 }, { opacity: 0, y: -32, duration: HEAD_FADE }, 0);
      tl.fromTo(
        book,
        { x: () => frame.clientWidth * REST_SHIFT, rotation: REST_TILT },
        { x: 0, rotation: 0, duration: HEAD_FADE, ease: "power2.inOut" },
        0,
      );

      const coverLength = COVER_END - COVER_START;
      tl.fromTo(
        cover,
        { rotationY: 0, z: count },
        { rotationY: COVER_LANDS_AT, z: 0, duration: coverLength, ease: "power2.inOut" },
        COVER_START,
      );
      // The cover lands a little short of flat. It straightens in the hold that follows, so the page landing beside it
      // is never hidden behind its raised edge.
      tl.to(cover, { rotationY: 180, duration: SETTLE_LENGTH, ease: "power1.out" }, COVER_END);
      pulse(lightOf(0), COVER_START, coverLength, LIGHT_PEAK);
      pulse(shadeOf("left-1"), COVER_START, coverLength, SHADE_PEAK);
      tl.fromTo(groundRight, { opacity: 0 }, { opacity: 1, duration: COVER_END - 0.6 }, 0.6);
      tl.fromTo(
        pick('[data-page="right-1"]'),
        { opacity: 0 },
        { opacity: 1, duration: FADE_IN_LENGTH },
        COVER_END - FADE_IN_LENGTH,
      );

      // One page turn per screen, with a hold at each end. A leaf rises a hair as it turns so the ones already landed stay
      // under it.
      for (let k = 1; k < count; k += 1) {
        const at = OPEN_LENGTH + (k - 1) + HOLD;
        const leaf = leaves[k];
        if (!leaf) continue;
        tl.fromTo(
          leaf,
          { rotationY: 0, z: count - k },
          { rotationY: 180, z: k, duration: TURN_LENGTH, ease: "power2.inOut" },
          at,
        );
        pulse(lightOf(k), at, TURN_LENGTH, LIGHT_PEAK);
        pulse(shadeOf(`left-${k + 1}`), at, TURN_LENGTH, SHADE_PEAK);
        pulse(shadeOf(`right-${k}`), at, TURN_LENGTH, SHADE_PEAK);
      }

      tl.fromTo(hint, { opacity: 1 }, { opacity: 0, duration: 0.3 }, 0);

      intro = gsap
        .timeline({ paused: true, defaults: { ease: "power3.out" } })
        .fromTo(drop, { y: -40 }, { y: 0, duration: 0.9 }, 0)
        .fromTo(drop, { rotation: -1.5 }, { rotation: 0, duration: 0.9, ease: "elastic.out(1, 0.5)" }, 0)
        .fromTo(
          cord,
          { rotation: 6, transformOrigin: "50% 98%" },
          { rotation: 0, duration: 0.9, ease: "elastic.out(1, 0.35)" },
          0,
        )
        .fromTo(headInner, { y: 24, opacity: 0 }, { y: 0, opacity: 1, duration: 0.7 }, 0.12);
    }, root);

    track(0);

    // The first paint of the whole book is heavy and can block the page for a few hundred milliseconds, which would play
    // the drop-in unseen. The book waits at its start pose and the drop begins on the second frame.
    let raf = window.requestAnimationFrame(() => {
      raf = window.requestAnimationFrame(() => intro?.play());
    });

    return () => {
      window.cancelAnimationFrame(raf);
      ctx.revert();
      watch.disconnect();
      window.clearTimeout(idle);
      delete book.dataset.moving;
      frame.style.removeProperty("--ledger-fit");
    };
  }, [count]);

  const [first] = chapters;
  const last = chapters[count - 1];
  if (!first || !last) return null;
  // Bottom of the pile first, so the leaf on top comes last in the page.
  const turning = Array.from({ length: count - 1 }, (_, i) => count - 1 - i);

  return (
    <section ref={rootRef} className="ledger ledger-stage ledger-stage-pinned" style={{ height: `${(count + 1) * 100}vh` }}>
      <div className="ledger-stage-frame" data-stage-frame>
        <div className="ledger-stage-head" data-stage-head>
          <div className="ledger-stage-head-inner" data-stage-head-inner>
            <Headline />
          </div>
        </div>

        <div className="ledger-stage-drop" data-stage-drop>
          <div className="ledger-stage-book" data-stage-book>
            <div className="ledger-stage-box">
              <span className="ledger-stage-ground ledger-stage-ground-left" aria-hidden="true" />
              <span className="ledger-stage-ground ledger-stage-ground-right" data-stage-ground-right aria-hidden="true" />

              <div className="ledger-stage-base">
                <StagePage side="left" index={count} chapter={last} onOpen={onOpen} />
              </div>

              {turning.map((k) => {
                const own = chapters[k - 1];
                const next = chapters[k];
                if (!own || !next) return null;
                return (
                  <div key={k} className="ledger-stage-leaf" data-leaf={k}>
                    <div className="ledger-stage-face ledger-stage-front">
                      <StagePage side="left" index={k} chapter={own} onOpen={onOpen} />
                      <span className="ledger-stage-light" data-light={k} data-edge="left" aria-hidden="true" />
                    </div>
                    <div className="ledger-stage-face ledger-stage-back">
                      <StagePage side="right" index={k + 1} chapter={next} onOpen={onOpen} />
                      <span className="ledger-stage-light" data-light={k} data-edge="right" aria-hidden="true" />
                    </div>
                  </div>
                );
              })}

              <div className="ledger-stage-leaf" data-leaf={0}>
                <div className="ledger-stage-face ledger-stage-front">
                  <LedgerCover rank={rank} />
                  <span className="ledger-stage-light" data-light={0} data-edge="left" aria-hidden="true" />
                </div>
                <div className="ledger-stage-face ledger-stage-back">
                  <PaperSheet className="ledger-stage-inside">
                    <ThreadBinding ticks={false} />
                  </PaperSheet>
                  <StagePage side="right" index={1} chapter={first} onOpen={onOpen} />
                  <span className="ledger-stage-light" data-light={0} data-edge="right" aria-hidden="true" />
                </div>
              </div>
            </div>
          </div>
        </div>

        <p className="ledger-stage-hint" data-stage-hint>
          {SCROLL_HINT}
        </p>
      </div>
    </section>
  );
}

// The same content as plain flow: the cover, then every chapter. Small screens, short windows and reduced motion get this,
// and so does the server, so the page reads with no script.
function FlatStage({ rank, chapters, onOpen, ready }: StageProps & { ready: boolean }) {
  return (
    <section className="ledger ledger-stage ledger-stage-flat" data-ready={ready}>
      <div className="ledger-stage-flat-inner">
        <header className="ledger-stage-flat-head">
          <Headline />
        </header>
        <div className="ledger-stage-flat-cover">
          <LedgerCover rank={rank} />
        </div>
        <div className="ledger-stage-flat-pages">
          {chapters.map(({ chapter, entries }) => (
            <LedgerSpread key={chapter.id} chapter={chapter} entries={entries} onOpen={onOpen} />
          ))}
        </div>
      </div>
    </section>
  );
}

export function LedgerStage({ progress }: { progress: WalletProgress }) {
  const reduced = useReducedMotion();
  const roomy = useMatchMedia(ROOMY);
  const pinned = roomy && !reduced;

  const entries = useMemo(() => entriesOf(progress), [progress]);
  const chapters = useMemo<ChapterEntries[]>(
    () => CHAPTERS.map((chapter) => ({ chapter, entries: entries.filter((entry) => entry.chapter === chapter.id) })),
    [entries],
  );

  const [slipId, setSlipId] = useState<QuestId | null>(null);
  const [slipOpen, setSlipOpen] = useState(false);
  const openSlip = useCallback((id: QuestId) => {
    setSlipId(id);
    setSlipOpen(true);
  }, []);
  const closeSlip = useCallback(() => setSlipOpen(false), []);
  const slipEntry = entries.find((entry) => entry.id === slipId);

  const hydrated = useHydrated();

  return (
    <>
      <noscript dangerouslySetInnerHTML={{ __html: SHOW_FLAT_WITHOUT_SCRIPT }} suppressHydrationWarning />
      {pinned ? (
        <PinnedStage rank={progress.rank.id} chapters={chapters} onOpen={openSlip} />
      ) : (
        <FlatStage rank={progress.rank.id} chapters={chapters} onOpen={openSlip} ready={hydrated} />
      )}
      {slipEntry && (
        <InstructionSlip
          id={slipEntry.id}
          open={slipOpen}
          onClose={closeSlip}
          done={slipEntry.done}
          at={slipEntry.at}
          hash={slipEntry.hash}
        />
      )}
    </>
  );
}

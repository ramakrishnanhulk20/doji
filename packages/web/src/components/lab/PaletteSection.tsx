"use client";

import type { CSSProperties, ReactNode } from "react";
import { useLiveStats } from "../../hooks/useLiveStats";
import { cssVars } from "../../lib/css-vars";
import { formatApr, formatBlock, formatBtc, formatMusd } from "../../lib/stats";
import { TOKENS, contrastNote } from "../../lib/tokens";
import { Button } from "../Button";
import { HEADLINES, IMAGE_CREDIT, IMAGE_CREDIT_URL, type HeadlineChoice } from "../hero/copy";
import { Seal } from "../Seal";
import "./lab.css";

const SEAL_SIZES = [16, 24, 48, 120] as const;

function Block({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="mt-16">
      <h3 className="label-mono mb-5">{title}</h3>
      {children}
    </div>
  );
}

function Chip({ tone, mark, children }: { tone: string; mark: "circle" | "diamond" | "square"; children: ReactNode }) {
  return (
    <span className="chip" style={cssVars({ "--chip": `var(${tone})` })}>
      <span className={`chip-mark chip-mark-${mark}`} aria-hidden="true" />
      {children}
    </span>
  );
}

function StateCell({ caption, children }: { caption: string; children: ReactNode }) {
  return (
    <div className="flex flex-col items-start gap-3">
      <span className="font-mono text-[12px] uppercase text-paper-dim">{caption}</span>
      {children}
    </div>
  );
}

function ButtonStates() {
  return (
    <div className="flex flex-col gap-10">
      {(["primary", "secondary"] as const).map((variant) => {
        const label = variant === "primary" ? "Borrow MUSD" : "Lend MUSD";
        const arrow = variant === "primary";
        return (
          <div key={variant}>
            <p className="mb-4 font-mono text-[12px] uppercase text-paper-dim">{variant}</p>
            <div className="flex flex-wrap gap-x-10 gap-y-8">
              <StateCell caption="Default">
                <Button variant={variant} arrow={arrow}>
                  {label}
                </Button>
              </StateCell>
              <StateCell caption="Hover">
                <Button variant={variant} arrow={arrow} forceState="hover">
                  {label}
                </Button>
              </StateCell>
              <StateCell caption="Focus">
                <Button variant={variant} arrow={arrow} forceState="focus">
                  {label}
                </Button>
              </StateCell>
              <StateCell caption="Disabled">
                <Button variant={variant} arrow={arrow} disabled>
                  {label}
                </Button>
              </StateCell>
              <StateCell caption="Loading">
                <Button variant={variant} arrow={arrow} loading>
                  {label}
                </Button>
              </StateCell>
            </div>
          </div>
        );
      })}
    </div>
  );
}

function LiveNumbers() {
  const { locked, offers, block } = useLiveStats();
  const best = offers.data?.best;

  const cells: { label: string; value: string }[] = [
    { label: "BTC locked", value: locked.data ? formatBtc(locked.data.btc) : "unavailable" },
    { label: "MUSD on offer", value: offers.data ? formatMusd(offers.data.musdOnOffer) : "unavailable" },
    { label: "Best rate", value: best ? formatApr(best.aprBps / 100) : offers.data ? "none" : "unavailable" },
    { label: "Block", value: block.data !== undefined ? formatBlock(block.data) : "unavailable" },
  ];

  return (
    <div className="flex flex-wrap gap-x-12 gap-y-4 font-mono text-[1.375rem] font-medium tabular-nums">
      {cells.map((cell) => (
        <div key={cell.label}>
          <div className={cell.value === "unavailable" ? "text-watch" : "text-paper"}>{cell.value}</div>
          <div className="label-mono mt-1">{cell.label}</div>
        </div>
      ))}
    </div>
  );
}

function TypeSpecimen({ headline }: { headline: HeadlineChoice }) {
  const row = "grid gap-3 border-t border-line py-6 md:grid-cols-[160px_1fr] md:gap-8";
  const caption = "label-mono pt-2";
  const wordmarkStyle: CSSProperties = {
    fontSize: "clamp(4.5rem, 13.5vw, 12rem)",
    fontWeight: "var(--display-wordmark-weight)",
    lineHeight: 0.88,
    letterSpacing: "-0.035em",
  };
  return (
    <div>
      <div className={row}>
        <span className={caption}>Wordmark</span>
        <p className="display-face" style={wordmarkStyle}>
          Doji
        </p>
      </div>
      <div className={row}>
        <span className={caption}>Headline</span>
        <p
          className="display-face max-w-[20ch]"
          style={{
            fontSize: "clamp(1.625rem, 2.7vw, 2.625rem)",
            fontWeight: "var(--display-headline-weight)",
            lineHeight: 1.08,
            letterSpacing: "-0.015em",
          }}
        >
          {HEADLINES[headline].join(" ")}
        </p>
      </div>
      <div className={row}>
        <span className={caption}>H2</span>
        <p
          className="display-face"
          style={{
            fontSize: "clamp(1.75rem, 3.5vw, 3rem)",
            fontWeight: "var(--display-headline-weight)",
            lineHeight: 1.1,
          }}
        >
          Fixed rate, fixed date.
        </p>
      </div>
      <div className={row}>
        <span className={caption}>Body</span>
        <p className="max-w-[65ch]">
          Osaka&rsquo;s Dōjima rice traders bought and sold fixed-date claims and sent prices across the city by
          flag. Doji does the same for MUSD on Mezo: one market per Thursday, prices straight from the oracle, and
          your Bitcoin stays locked the whole time.
        </p>
      </div>
      <div className={row}>
        <span className={caption}>Label</span>
        <p className="label-mono">Locked as veBTC on Mezo</p>
      </div>
      <div className={`${row} border-b`}>
        <span className={caption}>Numbers</span>
        <LiveNumbers />
      </div>
    </div>
  );
}

export function PaletteSection({ headline }: { headline: HeadlineChoice }) {
  return (
    <section className="border-t border-line" aria-labelledby="palette-heading">
      <div className="mx-auto max-w-[1200px] px-5 py-16 md:px-16 md:py-24">
        <h2
          id="palette-heading"
          className="display-face"
          style={{
            fontSize: "clamp(1.75rem, 3.5vw, 3rem)",
            fontWeight: "var(--display-headline-weight)",
            lineHeight: 1.1,
          }}
        >
          Palette, type and states
        </h2>

        <Block title="Colour tokens">
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            {TOKENS.map((token) => (
              <div key={token.name} className="overflow-hidden rounded-ui bg-ink-2">
                <div
                  className="h-24"
                  style={{ background: `var(${token.name})`, boxShadow: "inset 0 0 0 1px var(--line)" }}
                />
                <div className="p-3">
                  <p className="font-mono text-[12px] leading-5 text-paper">{token.name}</p>
                  <p className="font-mono text-[12px] leading-5 text-paper-dim">{token.hex}</p>
                  <p className="font-mono text-[12px] leading-5 text-paper-dim">{token.use}</p>
                  <p className="mt-2 text-[13px] leading-snug text-paper-dim">{contrastNote(token)}</p>
                </div>
              </div>
            ))}
          </div>
        </Block>

        <Block title="Status chips">
          <div className="flex flex-wrap gap-3">
            <Chip tone="--safe" mark="circle">
              Safe
            </Chip>
            <Chip tone="--watch" mark="diamond">
              Close to the limit
            </Chip>
            <Chip tone="--auction" mark="square">
              In auction
            </Chip>
          </div>
        </Block>

        <Block title="Buttons">
          <ButtonStates />
        </Block>

        <Block title="Type">
          <TypeSpecimen headline={headline} />
        </Block>

        <Block title="Seal">
          <div className="flex flex-wrap items-end gap-x-12 gap-y-6">
            {SEAL_SIZES.map((size) => (
              <div key={size} className="flex flex-col items-start gap-3">
                <Seal size={size} title="Doji" />
                <span className="font-mono text-[12px] uppercase text-paper-dim">{size}px</span>
              </div>
            ))}
          </div>
        </Block>

        <p className="mt-16 text-[13px] leading-relaxed text-paper-dim">
          <a
            className="image-credit-link"
            href={IMAGE_CREDIT_URL}
            target="_blank"
            rel="noopener noreferrer"
          >
            {IMAGE_CREDIT}
          </a>
        </p>
      </div>
    </section>
  );
}

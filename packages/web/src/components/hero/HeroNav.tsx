"use client";

import type { MouseEvent } from "react";
import { cssVars } from "../../lib/css-vars";
import { Seal } from "../Seal";

const LINKS = ["How it works", "Lend", "Docs"] as const;

// The lab has no pages to open, so every link is an anchor to "#" that stays put.
const stay = (event: MouseEvent<HTMLAnchorElement>) => event.preventDefault();

export function HeroNav() {
  return (
    <nav className="hero-nav enter" style={cssVars({ "--delay": "300ms", "--rise": "-8px" })} aria-label="Primary">
      <div className="hero-brand">
        <Seal size={28} title="" className="hero-brand-seal" />
        <span className="hero-brand-name display-face">Doji</span>
      </div>
      <ul className="hero-links">
        {LINKS.map((label) => (
          <li key={label}>
            <a className="hero-link" href="#" onClick={stay}>
              {label}
            </a>
          </li>
        ))}
      </ul>
      <span className="net-tag">
        <span className="net-dot" aria-hidden="true" />
        Mezo testnet
      </span>
    </nav>
  );
}

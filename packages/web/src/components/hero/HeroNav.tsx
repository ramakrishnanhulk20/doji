"use client";

import Link from "next/link";
import { cssVars } from "../../lib/css-vars";
import { Seal } from "../Seal";

const LINKS = [
  { label: "How it works", href: "#how" },
  { label: "Lend", href: "/lend" },
  { label: "Docs", href: "/docs" },
] as const;

export function HeroNav() {
  return (
    <nav className="hero-nav enter" style={cssVars({ "--delay": "300ms", "--rise": "-8px" })} aria-label="Primary">
      <div className="hero-brand">
        <Seal size={28} title="" className="hero-brand-seal" />
        <span className="hero-brand-name display-face">Doji</span>
      </div>
      <ul className="hero-links">
        {LINKS.map((link) => (
          <li key={link.label}>
            {link.href.startsWith("/") ? (
              <Link className="hero-link" href={link.href}>
                {link.label}
              </Link>
            ) : (
              <a className="hero-link" href={link.href}>
                {link.label}
              </a>
            )}
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

"use client";

import { useEffect, useRef, useState } from "react";
import Link from "next/link";
import { cssVars } from "../../lib/css-vars";
import { Seal } from "../Seal";

const LINKS = [
  { label: "How it works", href: "#how" },
  { label: "Borrow", href: "/borrow" },
  { label: "Lend", href: "/lend" },
  { label: "Try to break it", href: "/break" },
  { label: "Docs", href: "/docs" },
] as const;

export function HeroNav() {
  const [open, setOpen] = useState(false);
  const navRef = useRef<HTMLElement>(null);

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    const onPointer = (event: PointerEvent) => {
      if (navRef.current && !navRef.current.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    return () => {
      window.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
    };
  }, [open]);

  return (
    <nav
      ref={navRef}
      className="hero-nav enter"
      style={cssVars({ "--delay": "300ms", "--rise": "-8px" })}
      aria-label="Primary"
    >
      <div className="hero-brand">
        <Seal size={28} title="" className="hero-brand-seal" />
        <span className="hero-brand-name display-face">Doji</span>
      </div>
      <button
        type="button"
        className="hero-menu-button"
        aria-expanded={open}
        aria-controls="hero-menu"
        onClick={() => setOpen((value) => !value)}
      >
        Menu
      </button>
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
      {open && (
        <ul id="hero-menu" className="hero-menu">
          {LINKS.map((link) => (
            <li key={link.label}>
              {link.href.startsWith("/") ? (
                <Link href={link.href} onClick={() => setOpen(false)}>
                  {link.label}
                </Link>
              ) : (
                <a href={link.href} onClick={() => setOpen(false)}>
                  {link.label}
                </a>
              )}
            </li>
          ))}
        </ul>
      )}
    </nav>
  );
}

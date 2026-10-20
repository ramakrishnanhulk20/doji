"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { Seal } from "../Seal";
import { WalletButton } from "./WalletButton";

const LINKS = [
  { label: "Borrow", href: "/borrow" },
  { label: "Lend", href: "/lend" },
  { label: "My loans", href: "/loans" },
  { label: "Try to break it", href: "/break" },
  { label: "Docs", href: "/docs" },
] as const;

export function TopBar() {
  const pathname = usePathname();
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    setMenuOpen(false);
  }, [pathname]);

  useEffect(() => {
    if (!menuOpen) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setMenuOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [menuOpen]);

  const active = (href: string) => pathname === href || pathname.startsWith(`${href}/`);

  return (
    <header className="topbar">
      <div className="topbar-row">
        <Link href="/" className="topbar-brand">
          <Seal size={24} title="" />
          <span className="topbar-name display-face">Doji</span>
        </Link>

        <nav className="topbar-links" aria-label="App">
          {LINKS.map((link) => (
            <Link key={link.href} href={link.href} className="topbar-link" aria-current={active(link.href) ? "page" : undefined}>
              {link.label}
            </Link>
          ))}
        </nav>

        <div className="topbar-right">
          <span className="app-net-tag">
            <span className="net-dot" aria-hidden="true" />
            Mezo testnet
          </span>
          <WalletButton />
          <button
            type="button"
            className="topbar-menu-button"
            aria-label="Menu"
            aria-expanded={menuOpen}
            onClick={() => setMenuOpen((value) => !value)}
          >
            <span />
            <span />
            <span />
          </button>
        </div>
      </div>

      {menuOpen && (
        <nav className="topbar-sheet" aria-label="App menu">
          {LINKS.map((link) => (
            <Link key={link.href} href={link.href} className="topbar-sheet-link" aria-current={active(link.href) ? "page" : undefined}>
              {link.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}

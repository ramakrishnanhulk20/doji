import Link from "next/link";
import { IMAGE_CREDIT, IMAGE_CREDIT_URL } from "./hero/copy";
import { Seal } from "./Seal";

const INTERNAL = [
  { label: "Borrow", href: "/borrow" },
  { label: "Lend", href: "/lend" },
  { label: "Docs", href: "/docs" },
] as const;

const EXTERNAL = [
  { label: "GitHub", href: "https://github.com/ramakrishnanhulk20/doji" },
  { label: "Mezo", href: "https://mezo.org" },
] as const;

export function Footer() {
  return (
    <footer className="site-footer">
      <div className="footer-inner">
        <div className="footer-row">
          <div className="footer-brand">
            <Seal size={24} title="" />
            <span className="footer-brand-name display-face">Doji</span>
          </div>
          <ul className="footer-links">
            {INTERNAL.map((link) => (
              <li key={link.label}>
                <Link className="link-draw footer-link" href={link.href}>
                  {link.label}
                </Link>
              </li>
            ))}
            {EXTERNAL.map((link) => (
              <li key={link.label}>
                <a className="link-draw footer-link" href={link.href} target="_blank" rel="noopener noreferrer">
                  {link.label}
                </a>
              </li>
            ))}
          </ul>
        </div>
        <p className="footer-note">
          Built on Mezo. Testnet only: test BTC and test MUSD have no value.
        </p>
        <p className="footer-credit">
          <a className="link-draw" href={IMAGE_CREDIT_URL} target="_blank" rel="noopener noreferrer">
            {IMAGE_CREDIT}
          </a>
        </p>
      </div>
    </footer>
  );
}

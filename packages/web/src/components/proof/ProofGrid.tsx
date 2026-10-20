"use client";

import type { CSSProperties, ReactNode } from "react";
import type { Address } from "viem";
import { useVerified } from "../../hooks/useChainReads";
import { useLiveStats } from "../../hooks/useLiveStats";
import { deployment } from "../../generated/deployment";
import { addressBook } from "../../lib/addresses";
import { formatBlock } from "../../lib/stats";
import { ArrowOut } from "../ArrowOut";
import { SectionHeading } from "../landing/SectionHeading";

const REPO = "https://github.com/ramakrishnanhulk20/doji";
const EXPLORER_ADDRESS = "https://explorer.test.mezo.org/address/";

const shortAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;

type VerifiedTagProps = { address: Address };

function VerifiedTag({ address }: VerifiedTagProps) {
  const check = useVerified(address);
  const [text, tone] =
    check.data === true
      ? ["verified", "var(--safe)"]
      : check.data === false
        ? ["not verified", "var(--watch)"]
        : check.isError
          ? ["unavailable", "var(--watch)"]
          : ["checking", "var(--paper-dim)"];
  return (
    <span className="proof-tag" style={{ "--tag": tone } as CSSProperties}>
      {text}
    </span>
  );
}

type ProofLinkProps = { href: string; children: ReactNode };

function ProofLink({ href, children }: ProofLinkProps) {
  return (
    <a className="link-draw proof-link" href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <ArrowOut />
    </a>
  );
}

const CONTRACTS = [
  { name: "LoanManager", address: addressBook[31611].loanManager },
  { name: "CreditMarkets", address: addressBook[31611].creditMarkets },
  { name: "PassThrough", address: addressBook[31611].passThrough },
] as const;

const CARDS = [
  {
    title: "Proven live, 8 of 8",
    body: "One command locks test Bitcoin, borrows, tries three attacks as a stranger, repays and takes the position back on Mezo testnet.",
    link: "Read the run",
    href: `${REPO}/blob/main/docs/proof/prove-it-2026-10-20.md`,
  },
  {
    title: "Audited and fixed",
    body: "An independent review found no critical or high issues. Every finding was fixed with a test that failed before the fix.",
    link: "Read the findings",
    href: `${REPO}/blob/main/docs/audit/findings-2026-10-20.md`,
  },
  {
    title: "Tested against Mezo mainnet",
    body: "Fork tests run Doji against real veBTC positions, the real voters and the real oracle on Mezo mainnet.",
    link: "See the tests",
    href: `${REPO}/tree/main/packages/contracts/test`,
  },
  {
    title: "A written rulebook",
    body: "Every rule the contracts must keep is written down first, from custody to payouts, and each one points to the code that keeps it.",
    link: "Read the threat model",
    href: `${REPO}/blob/main/docs/security/threat-model.md`,
  },
  {
    title: "A keeper anyone can run",
    body: "A small bot starts auctions and settles loans every 30 minutes on GitHub. Anyone can call the same functions; the contracts check every condition.",
    link: "See the keeper",
    href: `${REPO}/tree/main/packages/keeper`,
  },
] as const;

export function ProofGrid() {
  const { block } = useLiveStats();

  return (
    <section id="proof" className="section">
      <div className="section-inner">
        <SectionHeading label="Proof, not promises" title="Check every claim yourself." />

        <ul className="proof-grid">
          <li className="proof-card">
            <h3 className="proof-title">Verified contracts</h3>
            <p className="proof-body">
              LoanManager, CreditMarkets and PassThrough are verified on Mezo&apos;s explorer. The contracts cannot be
              upgraded.
            </p>
            <ul className="proof-addresses">
              {CONTRACTS.map((contract) => (
                <li key={contract.name}>
                  <a
                    className="proof-address"
                    href={`${EXPLORER_ADDRESS}${contract.address}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <span>{contract.name}</span>
                    <span className="proof-address-short">{shortAddress(contract.address)}</span>
                    <VerifiedTag address={contract.address} />
                  </a>
                </li>
              ))}
            </ul>
          </li>

          {CARDS.map((card) => (
            <li key={card.title} className="proof-card">
              <h3 className="proof-title">{card.title}</h3>
              <p className="proof-body">{card.body}</p>
              <ProofLink href={card.href}>{card.link}</ProofLink>
            </li>
          ))}
        </ul>

        <p className="proof-strip">
          <span className="net-dot" aria-hidden="true" />
          Mezo testnet · block {block.data !== undefined ? formatBlock(block.data) : "..."} · chain {deployment.chainId}
        </p>
      </div>
    </section>
  );
}

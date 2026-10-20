"use client";

import { useState } from "react";
import Link from "next/link";
import { motion } from "motion/react";
import type { Hex } from "viem";
import { useLoan } from "../../hooks/useLoan";
import { useLoanClock } from "../../hooks/useLoanClock";
import { useLoanWrite } from "../../hooks/useLoanWrite";
import { EXPLORER, STATE_AUCTION, STATE_NONE, anyoneActions, describeLoan, musdText } from "../../lib/loans";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatDate } from "../../lib/stats";
import { Seal } from "../Seal";
import "../borrow/borrow.css";
import "./loans.css";
import { AnyoneActions } from "./AnyoneActions";
import { BuyCard } from "./BuyCard";
import { Facts } from "./Facts";

export function LoanPage({ id }: { id: string }) {
  const tokenId = BigInt(id);
  const reduced = useReducedMotion();
  const now = useLoanClock(15_000);
  const { view, opened, market, musd } = useLoan(tokenId);
  const { send, busy } = useLoanWrite();
  const [boughtHash, setBoughtHash] = useState<Hex | null>(null);

  const loan = view.data;
  const failed = view.isError || (view.isSuccess && loan === null);

  const subtitle = (() => {
    if (failed) return <span className="loan-unavailable">This loan could not be read right now. Doji is trying again.</span>;
    if (!loan) return <span className="loan-subtitle-bar shimmer" aria-hidden="true" />;
    if (loan.loan.state === STATE_NONE && opened.isPending) return <span className="loan-subtitle-bar shimmer" aria-hidden="true" />;
    return describeLoan(loan, now, opened.data != null);
  })();

  const rise = reduced ? { initial: false as const } : { initial: { opacity: 0, y: 16 }, animate: { opacity: 1, y: 0 } };

  return (
    <div className="app-page">
      <motion.div {...rise} transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
        <h1 className="app-page-title display-face">Loan on veBTC #{String(tokenId)}</h1>
        <p className="app-page-subtitle">{subtitle}</p>
      </motion.div>

      <div className="app-page-body loan-stack">
        {loan ? (
          <>
            <Facts view={loan} opened={opened} />

            {boughtHash !== null ? (
              <section className="success-card">
                <div className="success-seal">
                  <Seal size={96} title="Doji" />
                </div>
                <h2 className="success-title display-face">veBTC #{String(tokenId)} is yours.</h2>
                <div className="success-actions">
                  <a className="btn btn-secondary" href={`${EXPLORER}/tx/${boughtHash}`} target="_blank" rel="noopener noreferrer">
                    <span className="btn-label">View transaction</span>
                  </a>
                </div>
              </section>
            ) : (
              <>
                {loan.loan.state === STATE_AUCTION && (
                  <BuyCard view={loan} now={now} wallet={musd.data} send={send} busy={busy} onBought={setBoughtHash} />
                )}
                <AnyoneActions actions={anyoneActions(loan, now)} tokenId={tokenId} send={send} busy={busy} />
              </>
            )}

            {loan.loan.state !== STATE_NONE && market.data && (
              <Link className="link-draw market-link" href="/lend">
                {formatDate(loan.loan.maturity)} market: {musdText(market.data.lent)} MUSD due to lenders, {market.data.openLoans} open loan
                {market.data.openLoans === 1 ? "" : "s"}
              </Link>
            )}
          </>
        ) : failed ? null : (
          <div className="loan-skeleton shimmer" aria-busy="true">
            <span className="sr-only">Loading</span>
          </div>
        )}
      </div>
    </div>
  );
}

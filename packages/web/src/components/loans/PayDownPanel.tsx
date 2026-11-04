"use client";

import { useState, type ReactNode } from "react";
import { motion } from "motion/react";
import type { PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { useLoanGate } from "../../hooks/useLoanGate";
import { usePayDown } from "../../hooks/usePayDown";
import { useWrite } from "../../hooks/useWrite";
import { addressBook } from "../../lib/addresses";
import { EXPLORER, STATE_ACTIVE, STATE_AUCTION, musdText, shortAddress, toMusdNumber, type PositionView } from "../../lib/loans";
import { useReducedMotion } from "../../lib/motion-mode";
import {
  buildPayDownPlan,
  fixedText,
  harvestCall,
  harvestedLine,
  ledgerShares,
  nextThursday,
  parseHarvested,
  slippageText,
  sumRepaid,
  turnOffCall,
  turnOnCall,
} from "../../lib/paydown";
import { formatDate, formatMusd } from "../../lib/stats";
import { APP_CHAIN_ID } from "../../lib/wagmi";
import { showToast } from "../app/toast-store";
import { ArrowOut } from "../ArrowOut";
import { Button } from "../Button";
import { CountValue } from "../CountValue";

type PayDownPanelProps = {
  view: PositionView;
  /** The loan page's clock, in unix seconds. */
  now: number;
  /** The loan page's other writes are running or waiting for a confirmation. */
  busy: boolean;
};

const book = addressBook[31611];
const EASE = [0.22, 1, 0.36, 1] as const;
const unavailable = <span className="loan-unavailable">unavailable</span>;

const NOTHING_LINE = "Nothing to claim for this position yet. Rewards arrive after the week they were earned ends.";

const listVariants = { hidden: {}, show: { transition: { staggerChildren: 0.06 } } };
const rowVariants = { hidden: { opacity: 0, y: 8 }, show: { opacity: 1, y: 0, transition: { duration: 0.3, ease: EASE } } };

let noteCounter = 0;

const sameAddress = (a: string, b: string): boolean => a.toLowerCase() === b.toLowerCase();

/** The 20 October contracts have no reward operator, so a loan there has no pay-down. */
function LegacyCard() {
  return (
    <section className="paydown-card paydown-legacy">
      <p>
        Rewards pay-down works on loans opened since 4 November. This loan is on Doji&apos;s 20 October contracts, so its rewards are
        claimed by hand above.
      </p>
    </section>
  );
}

/** Rewards pay the loan down: the borrower's switch, the running total and every harvest, and a button anyone can press. */
export function PayDownPanel(props: PayDownPanelProps) {
  return props.view.pair === "legacy" ? <LegacyCard /> : <LivePanel {...props} />;
}

function LivePanel({ view, now, busy }: PayDownPanelProps) {
  const id = view.id;
  const reduced = useReducedMotion();
  const gate = useLoanGate();
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { write, busy: writing } = useWrite();
  const [acting, setActing] = useState<"toggle" | "harvest" | null>(null);
  const [seen, setSeen] = useState(false);

  const loanOpen = view.loan.state === STATE_ACTIVE || view.loan.state === STATE_AUCTION;
  const { state, harvests, quote, refresh } = usePayDown(id, true, loanOpen);
  const current = state.data;
  const on = current?.isPayDown === true;
  const shown = reduced || seen;
  const off = busy || writing;
  const isBorrower = gate.address !== undefined && view.borrower !== null && sameAddress(gate.address, view.borrower);

  const stop = (detail: string) => {
    showToast({ id: `paydown-note-${(noteCounter += 1)}`, kind: "problem", title: "Not sent", detail });
  };

  const toggle = async (turnOn: boolean) => {
    setActing("toggle");
    try {
      const call = turnOn ? turnOnCall(id) : turnOffCall(id);
      const result = await write({
        ...call,
        successLine: turnOn
          ? `Pay-down is on. Rewards now go to loan #${id} first.`
          : "Pay-down is off. Rewards go to your wallet when you claim them.",
      });
      if (result.ok) await refresh();
    } finally {
      setActing(null);
    }
  };

  const harvest = async () => {
    if (client === undefined) return;
    setActing("harvest");
    try {
      let plan;
      try {
        plan = await buildPayDownPlan(client, id);
      } catch {
        stop("Doji could not read the voter right now. Try again in a moment.");
        return;
      }
      if (plan.gauges.length === 0) {
        stop(NOTHING_LINE);
        return;
      }
      const result = await write({
        ...harvestCall(id, plan),
        successLine: (receipt) => {
          const found = parseHarvested(receipt, id);
          return found === null ? "Confirmed on Mezo." : harvestedLine(id, found);
        },
      });
      if (result.ok) await refresh();
    } finally {
      setActing(null);
    }
  };

  // While the switch is unread the title is a bar, and when the read fails it falls back to the invitation, which
  // claims nothing about the switch.
  const title = (() => {
    if (current !== undefined) return on ? "Rewards pay this loan" : "Let rewards pay this loan";
    if (state.isError) return "Let rewards pay this loan";
    return (
      <>
        <span className="shimmer paydown-title-skeleton" aria-hidden="true" />
        <span className="sr-only">Loading</span>
      </>
    );
  })();

  const slippage: ReactNode = current ? (
    slippageText(current.slippageBps)
  ) : state.isError ? (
    unavailable
  ) : (
    <span className="shimmer paydown-inline-skeleton" aria-hidden="true" />
  );

  const controls = (() => {
    if (state.isError) return <p className="paydown-note">{unavailable}</p>;
    if (current === undefined) return <span className="shimmer paydown-button-skeleton" aria-hidden="true" />;
    if (!isBorrower) {
      return <p className="paydown-note">{on ? "The borrower has turned pay-down on." : "The borrower has not turned pay-down on."}</p>;
    }
    if (gate.wrongChain) return null;
    return (
      <div className="paydown-controls">
        {current.operator !== null && !on && (
          <div className="paused-strip paydown-strip">
            Another address, {shortAddress(current.operator)}, can claim this position&apos;s rewards. Turning on pay-down replaces it.
          </div>
        )}
        {current.paused && (
          <div className="paused-strip paydown-strip">
            Harvests are paused by Doji&apos;s guardian. Turning pay-down on still works; harvests resume when the pause ends.
          </div>
        )}
        {on ? (
          <Button variant="secondary" disabled={off} loading={acting === "toggle"} onClick={() => void toggle(false)}>
            Turn off pay-down
          </Button>
        ) : (
          <Button variant="primary" disabled={off} loading={acting === "toggle"} onClick={() => void toggle(true)}>
            Turn on pay-down
          </Button>
        )}
      </div>
    );
  })();

  const list = harvests.data;
  const byRewards = list === undefined ? null : sumRepaid(list);
  const shares = byRewards === null ? null : ledgerShares(view.loan.face, view.loan.repaid, byRewards);

  const estimate = (() => {
    if (quote.isError) return <p className="paydown-estimate">{unavailable}</p>;
    const answer = quote.data;
    if (answer === undefined) return <p className="paydown-estimate paydown-dim">Checking what a harvest would repay.</p>;
    if (answer.kind === "ready") {
      return <p className="paydown-estimate">Claiming now would repay about {fixedText(answer.repaid, 4)} MUSD.</p>;
    }
    return <p className="paydown-estimate paydown-dim">{answer.kind === "nothing" ? NOTHING_LINE : answer.reason}</p>;
  })();

  const action = (() => {
    if (state.isError) return <p className="paydown-note">{unavailable}</p>;
    if (current === undefined) return null;
    if (!on) return <p className="paydown-note">Turn on pay-down and this space shows what each harvest repaid.</p>;
    if (!loanOpen) return null;
    return (
      <div className="paydown-action">
        {estimate}
        <Button
          variant="primary"
          arrow
          disabled={quote.data?.kind !== "ready" || !gate.ready || off}
          loading={acting === "harvest"}
          onClick={() => void harvest()}
        >
          Pay down now
        </Button>
      </div>
    );
  })();

  const rowMotion = reduced ? {} : { variants: rowVariants };
  const listMotion = reduced
    ? {}
    : { variants: listVariants, initial: "hidden", whileInView: "show", viewport: { once: true, amount: "some" as const } };

  const history = (() => {
    if (harvests.isError) return <p className="paydown-note">{unavailable}</p>;
    if (list === undefined) return <span className="shimmer paydown-row-skeleton" aria-hidden="true" />;
    if (list.length === 0) return <p className="paydown-note">No harvest has run for this loan yet.</p>;
    return (
      <motion.ul className="paydown-rows" {...listMotion}>
        {list.map((item) => (
          <motion.li className="paydown-row" key={`${item.hash}-${item.musdRepaid}`} {...rowMotion}>
            <span className="paydown-date">{formatDate(item.timestamp)}</span>
            <span className="paydown-what">
              {fixedText(item.musdRepaid, 4)} MUSD repaid
              {item.btcSold > 0n && (
                <span className="paydown-sold">
                  {" "}
                  · {fixedText(item.btcSold, 8)} BTC sold for {fixedText(item.musdFromBtc, 4)} MUSD
                </span>
              )}
            </span>
            <a className="link-draw paydown-link" href={`${EXPLORER}/tx/${item.hash}`} target="_blank" rel="noreferrer">
              tx
              <ArrowOut />
            </a>
          </motion.li>
        ))}
      </motion.ul>
    );
  })();

  const body = (
    <>
      <header>
        <h2 id="paydown-title" className="paydown-title display-face">
          {title}
        </h2>
        <p className="paydown-sub">
          PayDown{" "}
          <a className="link-draw" href={`${EXPLORER}/address/${book.payDown}`} target="_blank" rel="noreferrer">
            {shortAddress(book.payDown)}
          </a>
        </p>
      </header>

      <div className="paydown-cols">
        <div className="paydown-left">
          <p className="paydown-text">
            Every week the keeper claims this position&apos;s pool fees and incentives. MUSD goes straight to the loan. BTC is sold for
            MUSD only as far as the debt needs, never below Mezo&apos;s oracle price less {slippage}%. Everything else goes to the
            borrower.
          </p>
          <p className="paydown-text paydown-text-next">Other reward tokens are sold only when the borrower asks.</p>
          {controls}
        </div>

        <div className="paydown-right">
          <h3 className="fact-label">Repaid by rewards</h3>
          <p className="paydown-value display-face">
            {harvests.isError ? (
              unavailable
            ) : byRewards === null ? (
              <span className="shimmer paydown-value-skeleton" aria-hidden="true" />
            ) : (
              <>
                <CountValue value={toMusdNumber(byRewards)} format={formatMusd} reduced={reduced} active={shown} /> MUSD
              </>
            )}
          </p>

          {shares !== null && (
            <>
              <div className="paydown-track" aria-hidden="true">
                <motion.span
                  className="paydown-seg paydown-seg-rewards"
                  initial={reduced ? false : { width: "0%" }}
                  animate={{ width: shown ? `${shares.rewards}%` : "0%" }}
                  transition={{ duration: reduced ? 0 : 0.9, ease: EASE }}
                />
                <motion.span
                  className="paydown-seg paydown-seg-borrower"
                  initial={reduced ? false : { width: "0%" }}
                  animate={{ width: shown ? `${shares.borrower}%` : "0%" }}
                  transition={{ duration: reduced ? 0 : 0.9, ease: EASE, delay: reduced ? 0 : 0.15 }}
                />
              </div>
              <div className="paydown-legend">
                <span className="paydown-key">
                  <i className="paydown-swatch paydown-swatch-rewards" aria-hidden="true" />
                  rewards
                </span>
                <span className="paydown-key">
                  <i className="paydown-swatch paydown-swatch-borrower" aria-hidden="true" />
                  the borrower
                </span>
                <span>of {musdText(view.loan.face)} MUSD owed</span>
              </div>
            </>
          )}

          <p className="paydown-next">
            Rewards can be claimed after each week ends on Thursday 00:00 UTC. Next: {formatDate(nextThursday(now))}.
          </p>

          {action}
        </div>
      </div>

      <section className="paydown-history" aria-label="Harvests">
        <h3 className="fact-label">Harvests</h3>
        {history}
      </section>
    </>
  );

  if (reduced) {
    return (
      <section className="paydown-card" data-on={on || undefined} aria-labelledby="paydown-title">
        {body}
      </section>
    );
  }

  return (
    <motion.section
      className="paydown-card"
      data-on={on || undefined}
      aria-labelledby="paydown-title"
      initial={{ opacity: 0, y: 16 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.3 }}
      transition={{ duration: 0.5, ease: EASE }}
      onViewportEnter={() => setSeen(true)}
    >
      {body}
    </motion.section>
  );
}

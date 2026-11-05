"use client";

import { useState, type ReactNode } from "react";
import { motion } from "motion/react";
import { zeroAddress, type PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { useLoanGate } from "../../hooks/useLoanGate";
import { usePayDown } from "../../hooks/usePayDown";
import { useWrite } from "../../hooks/useWrite";
import { addressBook } from "../../lib/addresses";
import { EXPLORER, STATE_ACTIVE, STATE_AUCTION, musdText, shortAddress, toMusdNumber, type PositionView } from "../../lib/loans";
import { useReducedMotion } from "../../lib/motion-mode";
import {
  buildPayDownPlan,
  estimateLine,
  fixedText,
  harvestAndSwapCall,
  harvestCall,
  harvestedLine,
  ledgerShares,
  nextThursday,
  parseHarvested,
  parseSwapped,
  quotePlan,
  quoteSale,
  readOtherRewards,
  saleSwaps,
  setRewardOperatorCall,
  slippageText,
  soldLine,
  sumRepaid,
  tokenFixedText,
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
const VOTER_LINE = "Doji could not read the voter right now. Try again in a moment.";
const NO_QUOTE_LINE = "Mezo's pools do not quote those rewards right now. Try again in a moment.";
const SALE_NOTE =
  "Each sale accepts at most 1% below what Mezo's pools pay now. If the price moves further before the transaction lands, nothing is sold and nothing changes.";
const OFF_LINE = "Pay-down is off. Rewards go to your wallet when you claim them.";
const REMOVED_LINE = "Removed. Only you can claim this position's rewards now.";

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

/**
 * C50 with no loan open: a Wave 2 position Doji holds keeps its reward claimer after a repay, so the page still says
 * who it is, and the borrower can clear it. Renders nothing when no claimer is named.
 */
export function RewardOperatorCard({ view, busy }: { view: PositionView; busy: boolean }) {
  const gate = useLoanGate();
  const { write, busy: writing } = useWrite();
  const [acting, setActing] = useState(false);
  const operator = view.rewardOperator;
  if (operator === null) return null;

  const isBorrower = gate.address !== undefined && view.borrower !== null && sameAddress(gate.address, view.borrower);
  const canAct = isBorrower && !gate.wrongChain;
  const off = busy || writing;

  const clear = async (successLine: string) => {
    setActing(true);
    try {
      await write({ ...setRewardOperatorCall(view.id, zeroAddress), successLine });
    } finally {
      setActing(false);
    }
  };

  if (sameAddress(operator, book.payDown)) {
    return (
      <section className="paydown-card paydown-slim" data-on aria-labelledby="operator-title">
        <h2 id="operator-title" className="paydown-slim-title display-face">
          Pay-down is on
        </h2>
        <p className="paydown-slim-text">
          PayDown can claim this position&apos;s pool rewards. With no loan open, a harvest sends all of them to you.
        </p>
        {canAct && (
          <div className="paydown-slim-action">
            <Button variant="secondary" disabled={off} loading={acting} onClick={() => void clear(OFF_LINE)}>
              Turn off pay-down
            </Button>
          </div>
        )}
      </section>
    );
  }

  return (
    <section className="paydown-card paydown-slim" aria-label="Who can claim this position's rewards">
      <div className="paused-strip paydown-strip">
        Another address, {shortAddress(operator)}, can claim this position&apos;s rewards.
      </div>
      {canAct && (
        <div className="paydown-slim-action">
          <Button variant="primary" disabled={off} loading={acting} onClick={() => void clear(REMOVED_LINE)}>
            Remove it
          </Button>
        </div>
      )}
    </section>
  );
}

function LivePanel({ view, now, busy }: PayDownPanelProps) {
  const id = view.id;
  const reduced = useReducedMotion();
  const gate = useLoanGate();
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { write, busy: writing } = useWrite();
  const [acting, setActing] = useState<"toggle" | "remove" | "harvest" | "sell" | null>(null);
  const [seen, setSeen] = useState(false);
  // Tokens the borrower has unticked. A token with a quote is ticked until it is listed here, so a quote that appears
  // on a later refresh starts ticked too.
  const [unticked, setUnticked] = useState<ReadonlySet<string>>(new Set());

  const loanOpen = view.loan.state === STATE_ACTIVE || view.loan.state === STATE_AUCTION;
  const isBorrower = gate.address !== undefined && view.borrower !== null && sameAddress(gate.address, view.borrower);
  const { state, harvests, quote, others, refresh } = usePayDown(id, true, loanOpen, isBorrower);
  const current = state.data;
  const on = current?.isPayDown === true;
  const shown = reduced || seen;
  const off = busy || writing;

  const stop = (detail: string) => {
    showToast({ id: `paydown-note-${(noteCounter += 1)}`, kind: "problem", title: "Not sent", detail });
  };

  const toggle = async (turnOn: boolean) => {
    setActing("toggle");
    try {
      const call = turnOn ? turnOnCall(id) : turnOffCall(id);
      const result = await write({
        ...call,
        successLine: turnOn ? `Pay-down is on. Rewards now go to loan #${id} first.` : OFF_LINE,
      });
      if (result.ok) await refresh();
    } finally {
      setActing(null);
    }
  };

  const removeOperator = async () => {
    setActing("remove");
    try {
      const result = await write({ ...setRewardOperatorCall(id, zeroAddress), successLine: REMOVED_LINE });
      if (result.ok) await refresh();
    } finally {
      setActing(null);
    }
  };

  // The estimate on screen may have left BTC out, so the button sends the plan that was quoted. useWrite dry runs it
  // again at the press, so a plan the chain no longer accepts stops there.
  const harvest = async () => {
    const quoted = quote.data;
    if (quoted?.kind !== "ready") return;
    setActing("harvest");
    try {
      const result = await write({
        ...harvestCall(id, quoted.plan),
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

  const flipTick = (token: string) => {
    setUnticked((before) => {
      const next = new Set(before);
      if (!next.delete(token)) next.add(token);
      return next;
    });
  };

  const otherRows = others.data ?? [];
  const tickedTokens = otherRows
    .filter((row) => row.quote !== null && !unticked.has(row.reward.token.toLowerCase()))
    .map((row) => row.reward.token.toLowerCase());
  const showOthers = isBorrower && !gate.wrongChain && on && loanOpen && otherRows.length > 0;

  // The quotes on screen can be 30 seconds old, so the sale asks Mezo's pools again for the ticked tokens. Each minimum
  // sent is never below the one on screen at the press, so a pool that fell meanwhile makes the dry run refuse rather
  // than sell for less. A ticked token that lost its quote is left out and stays with the wallet. A sale refused over
  // BTC goes out without BTC, as a harvest does, with its swaps and minimums unchanged; any other refusal is left to
  // useWrite's own dry run to report.
  const sell = async () => {
    const account = gate.address;
    if (client === undefined || account === undefined) return;
    const shownMinimums = new Map(
      otherRows.flatMap((row) => {
        const key = row.reward.token.toLowerCase();
        return row.quote !== null && tickedTokens.includes(key) ? [[key, row.quote.amountOutMin] as const] : [];
      }),
    );
    setActing("sell");
    try {
      let plan;
      let fresh;
      try {
        plan = await buildPayDownPlan(client, id);
        const pending = (await readOtherRewards(client, id, plan)).filter((reward) => shownMinimums.has(reward.token.toLowerCase()));
        fresh = await Promise.all(
          pending.map(async (reward) => ({ reward, quote: await quoteSale(client, reward.token, reward.amount) })),
        );
      } catch {
        stop(VOTER_LINE);
        return;
      }
      const swaps = saleSwaps(
        fresh.map((row) => row.quote),
        shownMinimums,
      );
      if (swaps.length === 0) {
        stop(NO_QUOTE_LINE);
        return;
      }
      let quoted;
      try {
        quoted = await quotePlan(client, id, plan, account, swaps);
      } catch {
        stop(VOTER_LINE);
        return;
      }
      const labels = fresh.map((row) => row.reward);
      const result = await write({
        ...harvestAndSwapCall(id, quoted.kind === "ready" ? quoted.plan : plan, swaps),
        successLine: (receipt) => {
          const found = parseHarvested(receipt, id);
          return found === null ? "Confirmed on Mezo." : soldLine(id, found, parseSwapped(receipt, id, labels));
        },
      });
      if (result.ok) await refresh();
    } finally {
      setActing(null);
    }
  };

  const othersSection = showOthers ? (
    <section className="paydown-others" aria-labelledby="paydown-others-title">
      <h3 id="paydown-others-title" className="fact-label">
        Other rewards waiting
      </h3>
      <ul className="paydown-other-rows">
        {otherRows.map(({ reward, quote: sale }) => {
          const key = reward.token.toLowerCase();
          const amount = (
            <span className="paydown-other-amount">
              {tokenFixedText(reward.amount, reward.decimals, 4)} {reward.symbol}
            </span>
          );
          if (sale === null) {
            return (
              <li key={key}>
                <div className="paydown-other-row">
                  <span aria-hidden="true" />
                  {amount}
                  <span className="paydown-other-out">no Mezo pool to MUSD, goes to your wallet</span>
                </div>
              </li>
            );
          }
          return (
            <li key={key}>
              <label className="paydown-other-row" data-pick>
                <input
                  type="checkbox"
                  className="paydown-check"
                  checked={!unticked.has(key)}
                  onChange={() => flipTick(key)}
                />
                {amount}
                <span className="paydown-other-out">at least {fixedText(sale.amountOutMin, 4)} MUSD</span>
              </label>
            </li>
          );
        })}
      </ul>
      <div className="paydown-other-action">
        <Button
          variant="secondary"
          disabled={tickedTokens.length === 0 || !gate.ready || off || acting !== null}
          loading={acting === "sell"}
          onClick={() => void sell()}
        >
          Pay down and sell
        </Button>
      </div>
      <p className="paydown-other-note">{SALE_NOTE}</p>
    </section>
  ) : null;

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
      // C50: anyone looking at the position learns that another address can take its rewards, not only the borrower.
      if (current.operator !== null && !on) {
        return (
          <div className="paused-strip paydown-strip">
            Another address, {shortAddress(current.operator)}, can claim this position&apos;s rewards.
          </div>
        );
      }
      return <p className="paydown-note">{on ? "The borrower has turned pay-down on." : "The borrower has not turned pay-down on."}</p>;
    }
    if (gate.wrongChain) {
      // C50 holds on any network: the borrower still learns about another claimer, only the buttons wait for Mezo.
      if (current.operator !== null && !on) {
        return (
          <div className="paused-strip paydown-strip">
            Another address, {shortAddress(current.operator)}, can claim this position&apos;s rewards.
          </div>
        );
      }
      return null;
    }
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
          <div className="paydown-buttons">
            <Button variant="primary" disabled={off} loading={acting === "toggle"} onClick={() => void toggle(true)}>
              Turn on pay-down
            </Button>
            {current.operator !== null && (
              <Button variant="secondary" disabled={off} loading={acting === "remove"} onClick={() => void removeOperator()}>
                Remove it
              </Button>
            )}
          </div>
        )}
      </div>
    );
  })();

  const list = harvests.data;
  const byRewards = list === undefined ? null : sumRepaid(list);
  const shares = byRewards === null ? null : ledgerShares(view.loan.face, view.loan.repaid, byRewards);

  const estimate = (slippageBps: number) => {
    if (quote.isError) return <p className="paydown-estimate">{unavailable}</p>;
    const answer = quote.data;
    if (answer === undefined) return <p className="paydown-estimate paydown-dim">Checking what a harvest would repay.</p>;
    if (answer.kind === "ready") {
      return <p className="paydown-estimate">{estimateLine(answer.repaid, answer.withoutBtc, slippageBps)}</p>;
    }
    return <p className="paydown-estimate paydown-dim">{answer.kind === "nothing" ? NOTHING_LINE : answer.reason}</p>;
  };

  const action = (() => {
    if (state.isError) return <p className="paydown-note">{unavailable}</p>;
    if (current === undefined) return null;
    if (!on) return <p className="paydown-note">Turn on pay-down and this space shows what each harvest repaid.</p>;
    if (!loanOpen) return null;
    return (
      <div className="paydown-action">
        {estimate(current.slippageBps)}
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
          {othersSection}
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

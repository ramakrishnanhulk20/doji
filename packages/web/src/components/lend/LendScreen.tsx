"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { motion } from "motion/react";
import { parseEventLogs, type Abi, type PublicClient } from "viem";
import { useSwitchChain } from "wagmi";
import { creditMarketsAbi } from "../../abi/creditMarkets";
import { useLendData, useLendNow } from "../../hooks/useLendData";
import { useLendWrite } from "../../hooks/useLendWrite";
import type { WriteResult } from "../../hooks/useWrite";
import { roundDownToCent } from "../../lib/borrow";
import {
  approveMusdCall,
  buildLendSteps,
  cancelOfferCall,
  fitsOffer,
  lendProblemText,
  parseRateBps,
  postOfferCall,
  quoteOffer,
  type LendStep,
  type MyOffer,
  type OfferQuote,
} from "../../lib/lend";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatApr, formatDate, type ThursdayCard } from "../../lib/stats";
import { APP_CHAIN_ID } from "../../lib/wagmi";
import type { StepperStep } from "../app/Stepper";
import { openConnectModal } from "../app/connect-modal-store";
import { fmtMusd, musdFieldText, parseAmount } from "../borrow/format";
import { LendAmountStep, LendDateStep, RateStep } from "./OfferSteps";
import { OfferSummary, type ConfirmButton, type OfferSummaryData } from "./OfferSummary";
import { OffersTable, type ListState } from "./OffersTable";
import { PostedCard, type Posted } from "./PostedCard";
import { UnitsCards, type Act } from "./UnitsCards";
import "../borrow/borrow.css";
import "./lend.css";

type Flow = {
  steps: LendStep[];
  /** Steps finished so far. */
  done: number;
  running: boolean;
  failedAt: number | null;
};

const NO_DATES: ThursdayCard[] = [];

export function LendScreen({ initialDate }: { initialDate: number | null }) {
  const data = useLendData();
  const { send, busy } = useLendWrite();
  const { switchChain } = useSwitchChain();
  const reduced = useReducedMotion();
  const now = useLendNow();

  const [maturityPick, setMaturityPick] = useState<number | null>(initialDate);
  const [rateText, setRateText] = useState("");
  const [amountText, setAmountText] = useState("");
  const [flow, setFlow] = useState<Flow | null>(null);
  const [result, setResult] = useState<Posted | null>(null);
  const [sheetOpen, setSheetOpen] = useState(false);
  const [runningKey, setRunningKey] = useState<string | null>(null);

  const settings = data.settings.data;
  const dates = data.dates.data ?? NO_DATES;

  // The default is the earliest Thursday that already has offers, as on Borrow. With no offers anywhere, the earliest Thursday.
  const defaultDate = dates.find((card) => card.bestAprBps !== null)?.maturity ?? dates[0]?.maturity ?? null;
  const picked = maturityPick !== null && dates.some((card) => card.maturity === maturityPick);
  const maturity = picked ? maturityPick : defaultDate;
  const card = maturity === null ? undefined : dates.find((candidate) => candidate.maturity === maturity);

  const aprBps = parseRateBps(rateText);
  const maxAprBps = settings?.maxAprBps;
  const rateInRange = aprBps !== null && aprBps >= 1 && (maxAprBps === undefined || aprBps <= maxAprBps);
  const amountWei = roundDownToCent(parseAmount(amountText));

  const quoteWanted =
    data.client !== undefined && maturity !== null && aprBps !== null && rateInRange && fitsOffer(amountWei);
  const quote = useQuery({
    queryKey: ["offer-quote", maturity, aprBps, amountWei.toString()],
    queryFn: () => quoteOffer(data.client as PublicClient, amountWei, aprBps as number, maturity as number),
    enabled: quoteWanted,
    staleTime: 10_000,
    retry: false,
  });
  const quoted = quoteWanted ? quote.data : undefined;

  // The summary keeps the last quote while the next one loads, so its numbers tween instead of dropping to a dash.
  const [shownQuote, setShownQuote] = useState<OfferQuote | null>(null);
  useEffect(() => {
    if (!quoteWanted) setShownQuote(null);
    else if (quote.data) setShownQuote(quote.data);
  }, [quoteWanted, quote.data]);

  const balanceWei = data.musd.data?.balance;
  const allowanceWei = data.musd.data?.allowance;
  const connected = data.walletReady;

  const plannedSteps = useMemo<LendStep[]>(
    () =>
      buildLendSteps({
        amountText: fmtMusd(amountWei),
        allowanceCovers: allowanceWei !== undefined && allowanceWei >= amountWei,
      }),
    [amountWei, allowanceWei],
  );

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    setFlow((current) => (current && current.running ? current : null));
  }, [maturity, rateText, amountText]);

  const paused = settings?.offersPaused === true;

  const emptyReason = (() => {
    if (maturity === null) return "Pick a due date";
    if (aprBps === null) return "Enter a rate";
    if (amountWei === 0n) return "Enter an amount";
    return null;
  })();

  const checkReason = (() => {
    if (!settings) return "Checking the numbers";
    if (aprBps !== null && aprBps < 1) return lendProblemText({ kind: "rateLow" });
    if (aprBps !== null && aprBps > settings.maxAprBps) return lendProblemText({ kind: "rateHigh", maxAprBps: settings.maxAprBps });
    if (amountWei < settings.minOffer) return lendProblemText({ kind: "belowMin", minOffer: settings.minOffer });
    if (balanceWei !== undefined && amountWei > balanceWei) return lendProblemText({ kind: "overBalance", balance: balanceWei });
    if (quote.isError) return "Pick a due date";
    if (quoted === undefined) return "Checking the numbers";
    return null;
  })();

  const runSteps = async (steps: LendStep[], from: number) => {
    if (maturity === null || aprBps === null) return;
    setFlow({ steps, done: from, running: true, failedAt: null });
    let outcome: WriteResult | null = null;

    for (let index = from; index < steps.length; index++) {
      const step = steps[index] as LendStep;
      outcome =
        step.id === "approve-musd"
          ? await send(approveMusdCall(amountWei), `Approved ${fmtMusd(amountWei)} MUSD for Doji.`)
          : await send(postOfferCall(maturity, aprBps, amountWei), "Your offer is live.");

      if (!outcome.ok) {
        setFlow({ steps, done: index, running: false, failedAt: index });
        return;
      }
      setFlow({ steps, done: index + 1, running: index + 1 < steps.length, failedAt: null });
    }

    if (outcome?.ok) {
      const [log] = parseEventLogs({ abi: creditMarketsAbi as Abi, eventName: "OfferPosted", logs: outcome.receipt.logs });
      const args = (log?.args ?? {}) as { offerId?: bigint };
      setResult({ offerId: args.offerId ?? 0n, amount: amountWei, aprBps, maturity, hash: outcome.hash });
      setFlow(null);
      setSheetOpen(false);
    }
  };

  const onConfirm = () => {
    if (flow && flow.failedAt !== null) void runSteps(flow.steps, flow.failedAt);
    else void runSteps(plannedSteps, 0);
  };

  const running = flow?.running === true || busy;

  const confirm: ConfirmButton = (() => {
    if (paused) return { label: lendProblemText({ kind: "paused" }), disabled: true, loading: false, onClick: () => undefined };
    if (!data.isConnected) return { label: "Connect wallet to lend", disabled: false, loading: false, onClick: openConnectModal };
    if (data.chainId !== APP_CHAIN_ID) {
      return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: () => switchChain({ chainId: APP_CHAIN_ID }) };
    }
    if (emptyReason) return { label: emptyReason, disabled: true, loading: false, onClick: () => undefined };
    if (checkReason) return { label: checkReason, disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow && flow.failedAt !== null) {
      return { label: `Try again from step ${flow.failedAt + 1}`, disabled: false, loading: false, onClick: onConfirm };
    }
    return {
      label: `Post offer: ${fmtMusd(amountWei)} MUSD at ${formatApr((aprBps as number) / 100)} until ${formatDate(maturity as number)}`,
      disabled: false,
      loading: false,
      onClick: onConfirm,
    };
  })();

  const stepperSteps: StepperStep[] = (flow ? flow.steps : amountWei > 0n && !emptyReason ? plannedSteps : []).map((step, index) => ({
    id: step.id,
    label: step.label,
    state:
      flow && index < flow.done
        ? "done"
        : flow && flow.failedAt === index
          ? "failed"
          : flow && flow.running && index === flow.done
            ? "current"
            : "pending",
  }));

  const summary: OfferSummaryData = {
    amount: amountWei,
    maturity,
    aprBps: rateInRange ? aprBps : null,
    makerUnits: shownQuote?.makerUnits ?? null,
    treasuryUnits: shownQuote?.treasuryUnits ?? null,
    feeShareBps: settings?.feeShareBps ?? null,
  };

  const act: Act = async (key, call, successLine) => {
    setRunningKey(key);
    const outcome = await send(call, successLine);
    setRunningKey(null);
    return outcome.ok;
  };

  const cancelOffer = (offer: MyOffer) =>
    void act(
      `cancel:${offer.id}`,
      cancelOfferCall(offer.id),
      `Offer #${offer.id} cancelled. ${fmtMusd(offer.remaining)} MUSD is back in your wallet.`,
    );

  const datesStatus = data.dates.isError ? "error" : data.dates.data ? "ready" : "loading";
  const balanceView = !connected
    ? ({ kind: "connect" } as const)
    : data.musd.isError
      ? ({ kind: "error" } as const)
      : balanceWei === undefined
        ? ({ kind: "loading" } as const)
        : ({ kind: "ready", wei: balanceWei } as const);

  const offersState: ListState = !connected ? "connect" : data.offers.isError ? "error" : data.offers.data ? "ready" : "loading";
  const unitsState: ListState = !connected ? "connect" : data.units.isError ? "error" : data.units.data ? "ready" : "loading";

  const rise = reduced ? { initial: false as const } : { initial: { opacity: 0, y: 16 }, animate: { opacity: 1, y: 0 } };
  const stepMotion = (index: number) => ({
    initial: reduced ? (false as const) : { opacity: 0, y: 12 },
    animate: { opacity: 1, y: 0 },
    transition: { duration: 0.45, delay: reduced ? 0 : 0.18 + index * 0.06, ease: [0.22, 1, 0.36, 1] as [number, number, number, number] },
  });

  return (
    <div className="app-page">
      <motion.div {...rise} transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
        <h1 className="app-page-title display-face">Lend MUSD</h1>
        <p className="app-page-subtitle">
          Post an offer for a Thursday at your rate. Your MUSD waits in the contract until a borrower takes it, you can
          cancel whatever is not taken, and you are paid back on that date.
        </p>
      </motion.div>

      <div className="app-page-body borrow-layout" data-done={result !== null}>
        <div className="borrow-form">
          {paused && <p className="paused-strip">New offers are paused right now. Cancelling still works.</p>}

          {result ? (
            <PostedCard
              result={result}
              onAgain={() => {
                setResult(null);
                setRateText("");
                setAmountText("");
                setMaturityPick(null);
              }}
            />
          ) : (
            <>
              <motion.div {...stepMotion(0)}>
                <LendDateStep dates={dates} selected={maturity} onSelect={setMaturityPick} status={datesStatus} />
              </motion.div>
              <motion.div {...stepMotion(1)}>
                <RateStep
                  rateText={rateText}
                  onRateText={setRateText}
                  date={card ? { maturity: card.maturity, bestAprBps: card.bestAprBps } : null}
                />
              </motion.div>
              <motion.div {...stepMotion(2)}>
                <LendAmountStep
                  amountText={amountText}
                  onAmountText={setAmountText}
                  onMax={() => setAmountText(balanceWei ? musdFieldText(roundDownToCent(balanceWei)) : "")}
                  maxDisabled={!connected || balanceWei === undefined || balanceWei === 0n}
                  balance={balanceView}
                  minOffer={settings?.minOffer}
                />
              </motion.div>
            </>
          )}
        </div>

        {!result && (
          <aside className="borrow-summary">
            <OfferSummary data={summary} steps={stepperSteps} confirm={confirm} />
          </aside>
        )}
      </div>

      <div className="lend-lists">
        <motion.section {...stepMotion(3)} aria-labelledby="your-offers-title">
          <h2 id="your-offers-title" className="lend-list-title display-face">
            Your offers
          </h2>
          <OffersTable
            state={offersState}
            offers={data.offers.data ?? []}
            now={now}
            runningKey={runningKey}
            busy={busy}
            onCancel={cancelOffer}
          />
        </motion.section>

        <motion.section {...stepMotion(4)} aria-labelledby="your-units-title">
          <h2 id="your-units-title" className="lend-list-title display-face">
            Your credit units
          </h2>
          <UnitsCards
            state={unitsState}
            rows={data.units.data ?? []}
            now={now}
            address={data.address}
            runningKey={runningKey}
            busy={busy}
            act={act}
          />
        </motion.section>
      </div>

      {!result && (
        <div className="summary-bar">
          <div className="summary-bar-text">
            <p className="summary-bar-receive">You lend {amountWei > 0n ? fmtMusd(amountWei) : "0.00"} MUSD</p>
            <p className="summary-bar-owe">
              {shownQuote && maturity !== null ? `owed ${fmtMusd(shownQuote.makerUnits)} on ${formatDate(maturity)}` : "owed -"}
            </p>
          </div>
          <button type="button" className="summary-bar-button" onClick={() => setSheetOpen(true)}>
            Review
          </button>
        </div>
      )}

      {sheetOpen && !result && (
        <div className="sheet-overlay" onMouseDown={(event) => event.target === event.currentTarget && setSheetOpen(false)}>
          <div className="sheet" data-lenis-prevent role="dialog" aria-modal="true" aria-label="Your offer">
            <button type="button" className="sheet-close" aria-label="Close" onClick={() => setSheetOpen(false)}>
              Close
            </button>
            <OfferSummary data={summary} steps={stepperSteps} confirm={confirm} />
          </div>
        </div>
      )}
    </div>
  );
}

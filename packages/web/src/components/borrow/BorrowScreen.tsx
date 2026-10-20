"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { motion } from "motion/react";
import { formatUnits, parseEventLogs, parseUnits, type Abi } from "viem";
import { useSwitchChain } from "wagmi";
import { erc20Abi, veBtcAbi } from "../../abi/external";
import { loanManagerAbi } from "../../abi/loanManager";
import { useBorrowData } from "../../hooks/useBorrowData";
import { useWrite, type WriteResult } from "../../hooks/useWrite";
import { addressBook } from "../../lib/addresses";
import {
  CENT,
  auctionLinePrice,
  buildBorrowSteps,
  groupOffersByDate,
  limitUsedBps,
  lockDurationFor,
  maxPrincipal,
  roundDownToCent,
  selectOffers,
  thursdaysWithin,
  weightedAprBps,
  type BorrowStep,
} from "../../lib/borrow";
import { confirmMaxPrincipal, quoteFaces } from "../../lib/borrow-reads";
import { explainProblem } from "../../lib/errors";
import { useReducedMotion } from "../../lib/motion-mode";
import { formatDate } from "../../lib/stats";
import { APP_CHAIN_ID } from "../../lib/wagmi";
import type { StepperStep } from "../app/Stepper";
import { openConnectModal } from "../app/connect-modal-store";
import { fmtExact, fmtMusd, mulDivWei, musdFieldText, parseAmount } from "./format";
import { AmountStep, CollateralStep, DateStep } from "./Steps";
import { SuccessCard, type Borrowed } from "./SuccessCard";
import { SummaryCard, type ConfirmButton, type SummaryData } from "./SummaryCard";
import "./borrow.css";

const BOOK = addressBook[APP_CHAIN_ID];
/** BTC kept back by Max so the wallet can still pay for gas. */
const GAS_RESERVE = parseUnits("0.0002", 18);

type Flow = {
  steps: BorrowStep[];
  /** Steps finished so far. */
  done: number;
  running: boolean;
  failedAt: number | null;
};

const nowSeconds = () => Math.floor(Date.now() / 1000);

function useNow(): number {
  const [now, setNow] = useState(nowSeconds);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(nowSeconds()), 30_000);
    return () => window.clearInterval(timer);
  }, []);
  return now;
}

export function BorrowScreen() {
  const data = useBorrowData();
  const { write, busy } = useWrite();
  const { switchChain } = useSwitchChain();
  const reduced = useReducedMotion();
  const now = useNow();

  const [tab, setTab] = useState<"lock" | "position">("lock");
  const [btcText, setBtcText] = useState("");
  const [positionId, setPositionId] = useState<bigint | null>(null);
  const [maturityPick, setMaturityPick] = useState<number | null>(null);
  const [principalText, setPrincipalText] = useState("");
  const [flow, setFlow] = useState<Flow | null>(null);
  const [result, setResult] = useState<Borrowed | null>(null);
  const [sheetOpen, setSheetOpen] = useState(false);

  const settings = data.settings.data;
  const price = data.price.data;
  const positionList = data.positions.data;
  const position = tab === "position" && positionId !== null ? positionList?.find((item) => item.id === positionId) : undefined;

  const groups = useMemo(() => groupOffersByDate(data.offers.data ?? []), [data.offers.data]);

  // Dates: the next Thursdays within the longest term, and for a normal lock only those on or before its end.
  const dates = useMemo(() => {
    if (!settings) return [];
    const all = thursdaysWithin(now, settings.maxTermSeconds);
    return position && !position.isPermanent ? all.filter((date) => date <= position.end) : all;
  }, [settings, now, position]);

  // The default is the earliest Thursday whose offers can fill the minimum loan. If none can, the earliest with any offer.
  const minLoan = settings?.minLoan ?? 0n;
  const defaultDate =
    dates.find((date) => groups.some((group) => group.maturity === date && group.available >= minLoan)) ??
    dates.find((date) => groups.some((group) => group.maturity === date)) ??
    null;
  const picked = maturityPick !== null && dates.includes(maturityPick) && groups.some((g) => g.maturity === maturityPick);
  const maturity = picked ? maturityPick : defaultDate;
  const group = maturity === null ? undefined : groups.find((candidate) => candidate.maturity === maturity);

  const btcWei = tab === "lock" ? parseAmount(btcText) : (position?.amount ?? 0n);
  const valueWei = price === undefined ? undefined : tab === "lock" ? mulDivWei(btcWei, price) : (position?.value ?? 0n);
  const maxFace = valueWei !== undefined && settings ? (valueWei * BigInt(settings.maxLtvBps)) / 10_000n : undefined;

  const principalWei = roundDownToCent(parseAmount(principalText));
  const selection = useMemo(() => selectOffers(principalWei, group?.offers ?? []), [principalWei, group]);
  const selectionKey = `${selection.offerIds.join(",")}:${selection.amounts.join(",")}`;
  const offersKey = (group?.offers ?? []).map((offer) => `${offer.id}:${offer.remaining}`).join(",");

  const localMax =
    group && maturity !== null && maxFace !== undefined && maxFace > 0n
      ? roundDownToCent(maxPrincipal({ offers: group.offers, maxFace, secondsToMaturity: maturity - now }))
      : 0n;

  const confirmedMax = useQuery({
    queryKey: ["max-principal", maturity, valueWei?.toString(), settings?.maxLtvBps, offersKey],
    queryFn: () =>
      confirmMaxPrincipal(data.client as NonNullable<typeof data.client>, {
        maturity: maturity as number,
        start: localMax,
        maxFace: maxFace as bigint,
        pick: (principal) => selectOffers(principal, group?.offers ?? []),
        step: CENT,
      }),
    enabled: data.client !== undefined && localMax > 0n && maxFace !== undefined && maturity !== null,
    staleTime: 10_000,
    retry: false,
  });
  const maxWei = localMax === 0n ? 0n : (confirmedMax.data?.principal ?? undefined);

  const quote = useQuery({
    queryKey: ["quote", maturity, selectionKey],
    queryFn: () => quoteFaces(data.client as NonNullable<typeof data.client>, maturity as number, selection),
    enabled: data.client !== undefined && maturity !== null && principalWei > 0n && selection.filled === principalWei,
    staleTime: 10_000,
    retry: false,
  });
  const face = quote.data ? quote.data.reduce((sum, value) => sum + value, 0n) : null;

  const usedBps = face !== null && valueWei !== undefined && settings ? limitUsedBps(face, valueWei, settings.maxLtvBps) : null;
  const auctionPriceWei = face !== null && settings && btcWei > 0n ? auctionLinePrice(face, settings.liqLtvBps, btcWei) : null;
  const aprBps = principalWei > 0n && selection.filled === principalWei ? weightedAprBps(selection.amounts, selection.aprs) : null;

  const balanceWei = data.balance.data?.value;
  const allowanceWei = data.allowance.data;
  const connected = data.walletReady;

  // The steps the confirm button will walk through, with what is already done on chain left out.
  const plannedSteps = useMemo<BorrowStep[]>(() => {
    if (tab === "lock") {
      return buildBorrowSteps({
        path: "lock",
        btcText: fmtExact(btcWei),
        allowanceCovers: allowanceWei !== undefined && allowanceWei >= btcWei,
      });
    }
    return position ? buildBorrowSteps({ path: "position", tokenId: position.id, alreadyApproved: position.approved }) : [];
  }, [tab, btcWei, allowanceWei, position]);

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    setFlow((current) => (current && current.running ? current : null));
  }, [tab, btcText, positionId, maturity, principalText]);

  const problem = (() => {
    if (settings?.borrowsPaused) return explainProblem({ kind: "paused" });
    if (data.price.isError) return explainProblem({ kind: "noPrice" });
    return null;
  })();

  const emptyReason = (() => {
    if (tab === "lock" && btcWei === 0n) return "Enter an amount";
    if (tab === "position" && !position) return "Pick a veBTC position";
    if (principalWei === 0n) return "Enter an amount";
    if (maturity === null || !group) return "Pick a due date";
    return null;
  })();

  const checkReason = (() => {
    if (!settings || valueWei === undefined || !group) return null;
    if (tab === "lock" && balanceWei !== undefined && btcWei > balanceWei) {
      return explainProblem({ kind: "noBalance", balance: balanceWei });
    }
    if (principalWei < settings.minLoan) return explainProblem({ kind: "belowMin", minLoan: settings.minLoan });
    if (selection.filled < principalWei) {
      return selection.offerIds.length >= 8
        ? explainProblem({ kind: "tooManyOffers" })
        : explainProblem({ kind: "overOffers", most: group.available });
    }
    if (quote.isLoading || face === null) return "Checking the numbers";
    if (maxFace !== undefined && face > maxFace) return explainProblem({ kind: "overLimit", maxFace });
    return null;
  })();

  const runSteps = async (steps: BorrowStep[], from: number) => {
    if (maturity === null) return;
    setFlow({ steps, done: from, running: true, failedAt: null });
    let outcome: WriteResult | null = null;

    for (let index = from; index < steps.length; index++) {
      const step = steps[index] as BorrowStep;
      const at = nowSeconds();
      const succeeded = `${fmtMusd(principalWei)} MUSD is in your wallet.`;

      switch (step.id) {
        case "approve-btc":
          outcome = await write({
            target: "btc",
            abi: erc20Abi as Abi,
            functionName: "approve",
            args: [BOOK.loanManager, btcWei],
            successLine: `Approved ${fmtExact(btcWei)} BTC for Doji.`,
          });
          break;
        case "lock-and-borrow":
          outcome = await write({
            target: "loanManager",
            abi: loanManagerAbi as Abi,
            functionName: "lockAndBorrow",
            args: [btcWei, lockDurationFor(maturity, at), BigInt(maturity), selection.offerIds, selection.amounts, selection.maxAprBps],
            successLine: succeeded,
            action: "lock",
          });
          break;
        case "approve-position":
          outcome = await write({
            target: "veBTC",
            abi: veBtcAbi as Abi,
            functionName: "approve",
            args: [BOOK.loanManager, position?.id ?? 0n],
            successLine: `veBTC #${position?.id} approved for Doji.`,
          });
          break;
        case "deposit":
          outcome = await write({
            target: "loanManager",
            abi: loanManagerAbi as Abi,
            functionName: "deposit",
            args: [position?.id ?? 0n],
            successLine: `veBTC #${position?.id} is with Doji.`,
          });
          break;
        case "borrow":
          outcome = await write({
            target: "loanManager",
            abi: loanManagerAbi as Abi,
            functionName: "borrow",
            args: [position?.id ?? 0n, BigInt(maturity), selection.offerIds, selection.amounts, selection.maxAprBps],
            successLine: succeeded,
          });
          break;
      }

      if (!outcome || !outcome.ok) {
        setFlow({ steps, done: index, running: false, failedAt: index });
        return;
      }
      setFlow({ steps, done: index + 1, running: index + 1 < steps.length, failedAt: null });
    }

    if (outcome?.ok) {
      const [log] = parseEventLogs({ abi: loanManagerAbi as Abi, eventName: "Borrowed", logs: outcome.receipt.logs });
      const args = (log?.args ?? {}) as { tokenId?: bigint; principal?: bigint; face?: bigint };
      setResult({
        tokenId: args.tokenId ?? position?.id ?? 0n,
        principal: args.principal ?? principalWei,
        face: args.face ?? face ?? 0n,
        maturity,
        hash: outcome.hash,
      });
      setFlow(null);
      setSheetOpen(false);
    }
  };

  const onConfirm = () => {
    if (flow && flow.failedAt !== null) {
      void runSteps(flow.steps, flow.failedAt);
    } else {
      void runSteps(plannedSteps, 0);
    }
  };

  const running = flow?.running === true || busy;

  const confirm: ConfirmButton = (() => {
    if (problem) return { label: problem, disabled: true, loading: false, onClick: () => undefined };
    if (!data.isConnected) return { label: "Connect wallet to borrow", disabled: false, loading: false, onClick: openConnectModal };
    if (data.chainId !== APP_CHAIN_ID) {
      return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: () => switchChain({ chainId: APP_CHAIN_ID }) };
    }
    if (emptyReason) return { label: emptyReason, disabled: true, loading: false, onClick: () => undefined };
    if (checkReason) return { label: checkReason, disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow && flow.failedAt !== null) {
      return { label: `Try again from step ${flow.failedAt + 1}`, disabled: false, loading: false, onClick: onConfirm };
    }
    const label =
      tab === "lock"
        ? `Lock ${fmtExact(btcWei)} BTC and borrow ${fmtMusd(principalWei)} MUSD`
        : `Borrow ${fmtMusd(principalWei)} MUSD against veBTC #${position?.id}`;
    return { label, disabled: false, loading: false, onClick: onConfirm };
  })();

  const stepperSteps: StepperStep[] = (flow ? flow.steps : principalWei > 0n && !emptyReason ? plannedSteps : []).map(
    (step, index) => ({
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
    }),
  );

  const summary: SummaryData = {
    collateralText: tab === "lock" ? (btcWei > 0n ? `${fmtExact(btcWei)} BTC` : null) : position ? `veBTC #${position.id}` : null,
    valueWei: valueWei !== undefined && valueWei > 0n ? valueWei : null,
    maturity,
    principal: principalWei,
    face,
    aprBps,
    usedBps,
    auctionPriceWei,
  };

  const cents = Number(principalWei / CENT);
  const maxCents = maxWei === undefined ? 0 : Number(maxWei / CENT);

  const offersStatus = data.offers.isError || data.settings.isError ? "error" : data.offers.data && settings ? "ready" : "loading";

  const amountNote =
    valueWei === undefined || valueWei === 0n
      ? "Add collateral to see how much you can borrow."
      : maxWei === undefined
        ? "Working out the most you can borrow..."
        : maxWei === 0n
          ? "No offers at this date can lend against this collateral."
          : `You can borrow up to ${fmtMusd(maxWei)} MUSD against this collateral on this date.`;

  const maxBtc = balanceWei !== undefined && balanceWei > GAS_RESERVE ? balanceWei - GAS_RESERVE : 0n;

  const rise = reduced ? { initial: false as const } : { initial: { opacity: 0, y: 16 }, animate: { opacity: 1, y: 0 } };

  return (
    <div className="app-page">
      <motion.div {...rise} transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
        <h1 className="app-page-title display-face">Borrow MUSD</h1>
        <p className="app-page-subtitle">
          Lock Bitcoin, or use a veBTC position you already have, and borrow MUSD at a fixed rate until a Thursday you
          choose. Your votes and rewards stay yours.
        </p>
      </motion.div>

      <div className="app-page-body borrow-layout" data-done={result !== null}>
        <div className="borrow-form">
          {settings?.borrowsPaused && (
            <p className="paused-strip">New loans are paused right now. Repaying and rolling still work.</p>
          )}

          {result ? (
            <SuccessCard
              result={result}
              onAgain={() => {
                setResult(null);
                setPrincipalText("");
                setBtcText("");
                setPositionId(null);
              }}
            />
          ) : (
            <>
              {[0, 1, 2].map((index) => (
                <motion.div
                  key={index}
                  initial={reduced ? false : { opacity: 0, y: 12 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ duration: 0.45, delay: reduced ? 0 : 0.18 + index * 0.06, ease: [0.22, 1, 0.36, 1] }}
                >
                  {index === 0 && (
                    <CollateralStep
                      tab={tab}
                      onTab={setTab}
                      btcText={btcText}
                      onBtcText={setBtcText}
                      onMaxBtc={() => setBtcText(maxBtc > 0n ? formatUnits(maxBtc, 18) : "")}
                      connected={connected}
                      balance={balanceWei}
                      balanceValue={balanceWei !== undefined && price !== undefined ? mulDivWei(balanceWei, price) : undefined}
                      maturity={maturity}
                      positions={{
                        loading: data.positions.isLoading || (price === undefined && !data.price.isError),
                        error: data.positions.isError,
                        list: positionList,
                      }}
                      selectedId={positionId}
                      onSelectPosition={setPositionId}
                      onConnect={openConnectModal}
                    />
                  )}
                  {index === 1 && (
                    <DateStep
                      dates={dates}
                      groups={groups}
                      selected={maturity}
                      onSelect={setMaturityPick}
                      status={offersStatus}
                      minLoan={minLoan}
                    />
                  )}
                  {index === 2 && (
                    <AmountStep
                      principalText={principalText}
                      onPrincipalText={setPrincipalText}
                      maxCents={maxCents}
                      cents={cents}
                      onSlide={(value) => setPrincipalText(musdFieldText(BigInt(value) * CENT))}
                      onMax={() => setPrincipalText(maxWei ? musdFieldText(maxWei) : "")}
                      maxDisabled={!maxWei}
                      note={amountNote}
                    />
                  )}
                </motion.div>
              ))}
            </>
          )}
        </div>

        {!result && (
          <aside className="borrow-summary">
            <SummaryCard data={summary} steps={stepperSteps} confirm={confirm} />
          </aside>
        )}
      </div>

      {!result && (
        <div className="summary-bar">
          <div className="summary-bar-text">
            <p className="summary-bar-receive">
              You receive {principalWei > 0n ? fmtMusd(principalWei) : "0.00"} MUSD
            </p>
            <p className="summary-bar-owe">
              {face !== null && maturity !== null ? `owe ${fmtMusd(face)} on ${formatDate(maturity)}` : "owe -"}
            </p>
          </div>
          <button type="button" className="summary-bar-button" onClick={() => setSheetOpen(true)}>
            Review
          </button>
        </div>
      )}

      {sheetOpen && !result && (
        <div className="sheet-overlay" onMouseDown={(event) => event.target === event.currentTarget && setSheetOpen(false)}>
          <div className="sheet" data-lenis-prevent role="dialog" aria-modal="true" aria-label="Your loan">
            <button type="button" className="sheet-close" aria-label="Close" onClick={() => setSheetOpen(false)}>
              Close
            </button>
            <SummaryCard data={summary} steps={stepperSteps} confirm={confirm} />
          </div>
        </div>
      )}
    </div>
  );
}

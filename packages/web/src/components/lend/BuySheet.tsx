"use client";

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useStepFlow, type FlowStep } from "../../hooks/useStepFlow";
import { useUnitWallet } from "../../hooks/useUnitMarket";
import { useWrite, type WriteResult } from "../../hooks/useWrite";
import { seedAuctionDates } from "../../lib/addresses";
import { formatDate } from "../../lib/stats";
import {
  MARKET_PAUSED_LINE,
  approveUnitBuyCall,
  buildBuySteps,
  buyCall,
  fmtFourDecimals,
  fmtUnitsAmount,
  listingStage,
  quoteBuy,
  unitYield,
  unitsFieldText,
  type BuyStep,
  type Listing,
} from "../../lib/units";
import { APP_CHAIN_ID } from "../../lib/wagmi";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { showToast } from "../app/toast-store";
import { parseAmount } from "../borrow/format";
import { AmountField } from "../borrow/Steps";
import { Sheet } from "../loans/Sheet";
import "../borrow/borrow.css";
import "../loans/loans.css";
import "./lend.css";

type RunStep = BuyStep & FlowStep;

const QUOTE_DELAY_MS = 300;

type BuySheetProps = {
  listing: Listing;
  now: number;
  paused: boolean;
  onClose: () => void;
};

const dash = <span className="summary-empty">-</span>;

const DATE_PASSED_LINE = "This date has passed, so the buy was not sent.";
const AUCTION_NOTE = "A Doji test loan on this date is going to auction, so payouts here can take a few extra days.";

let noteCounter = 0;

/**
 * Opens only while the listing is open: past its Thursday a unit is no longer worth 1 MUSD, so no buy is offered. A run
 * that began while it was open keeps the sheet until the run ends, so a wallet prompt or a confirmation in progress is
 * never cut off by the clock; the buy step itself refuses a date that has passed.
 */
export function BuySheet(props: BuySheetProps) {
  const open = listingStage(props.listing, props.now) === "open";
  const [running, setRunning] = useState(false);
  const { onClose } = props;
  useEffect(() => {
    if (!open && !running) onClose();
  }, [open, running, onClose]);
  return open || running ? <BuyForm {...props} onRunning={setRunning} /> : null;
}

function BuyForm({ listing, now, paused, onClose, onRunning }: BuySheetProps & { onRunning: (running: boolean) => void }) {
  const gate = useLoanGate();
  const engine = useStepFlow<RunStep>();
  const { write, busy } = useWrite();
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const wallet = useUnitWallet(gate.ready ? gate.address : undefined).data;

  const [unitsText, setUnitsText] = useState("");
  const [settledText, setSettledText] = useState("");

  // The quote waits until the field has stopped changing, so a half-typed number never costs a read.
  useEffect(() => {
    const timer = window.setTimeout(() => setSettledText(unitsText), QUOTE_DELAY_MS);
    return () => window.clearTimeout(timer);
  }, [unitsText]);

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    if (!engine.running) engine.reset();
  }, [unitsText]);

  const date = formatDate(listing.maturity);
  const unitsWei = parseAmount(unitsText);
  const settledWei = parseAmount(settledText);
  const overLeft = unitsWei > listing.unitsLeft;
  const quoteWanted = client !== undefined && settledWei > 0n && settledWei <= listing.unitsLeft && settledWei === unitsWei;

  const quote = useQuery({
    queryKey: ["units", "quote", listing.id.toString(), settledWei.toString()],
    queryFn: () => quoteBuy(client as PublicClient, listing.id, settledWei),
    enabled: quoteWanted,
    staleTime: 10_000,
    retry: false,
  });
  const quoted = quoteWanted ? quote.data : undefined;

  const overBalance = quoted !== undefined && wallet !== undefined && quoted.cost > wallet.balance;
  const earn = unitYield(listing.pricePerUnit, listing.maturity, now);
  const allowanceCovers = quoted !== undefined && wallet !== undefined && wallet.allowance >= quoted.cost;
  const plan = quoted === undefined ? [] : buildBuySteps({ cost: quoted.cost, allowanceCovers });

  const run = async (steps: RunStep[], from: number) => {
    onRunning(true);
    try {
      const { ok, last } = await engine.start(steps, from);
      if (ok && last?.ok) {
        engine.reset();
        onClose();
      }
    } finally {
      onRunning(false);
    }
  };

  // The sheet was opened before the date, but the approve before this step can take minutes to confirm, and a unit
  // bought after its Thursday is no longer worth 1 MUSD.
  const buyIfOpen = async (units: bigint, cost: bigint): Promise<WriteResult> => {
    if (listingStage(listing, Math.floor(Date.now() / 1000)) !== "open") {
      showToast({ id: `buy-note-${(noteCounter += 1)}`, kind: "problem", title: "Not sent", detail: DATE_PASSED_LINE });
      return { ok: false, refresh: false };
    }
    return write({
      ...buyCall(listing.id, units, listing.pricePerUnit),
      successLine: `Bought ${fmtUnitsAmount(units)} units of ${date} for ${fmtFourDecimals(cost)} MUSD. They are in Your credit units.`,
    });
  };

  const onConfirm = () => {
    if (engine.failedAt !== null && engine.steps) {
      void run(engine.steps, engine.failedAt);
      return;
    }
    if (quoted === undefined) return;
    // Each step carries the numbers on screen now, so a retry never repeats stale ones.
    const { cost } = quoted;
    const units = unitsWei;
    const runnable: RunStep[] = plan.map((step) => ({
      ...step,
      run: () =>
        step.id === "approve-musd"
          ? write({ ...approveUnitBuyCall(cost), successLine: `Approved ${fmtFourDecimals(cost)} MUSD for Doji.` })
          : buyIfOpen(units, cost),
    }));
    void run(runnable, 0);
  };

  const running = engine.running || busy;

  const confirm = (() => {
    const off = (label: string) => ({ label, disabled: true, loading: false, onClick: () => undefined });
    if (!gate.isConnected) return { label: "Connect wallet to buy", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (paused) return off("Buy units");
    if (wallet === undefined) return off("Checking your wallet");
    if (unitsWei === 0n) return off("Enter an amount");
    if (overLeft || overBalance) return off("Buy units");
    if (quoted === undefined) return off("Checking the numbers");
    if (engine.confirming) return off("Waiting for confirmation");
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (engine.failedAt !== null) {
      return { label: `Try again from step ${engine.failedAt + 1}`, disabled: false, loading: false, onClick: onConfirm };
    }
    return { label: "Buy units", disabled: false, loading: false, onClick: onConfirm };
  })();

  return (
    <Sheet title={`Buy units of ${date}`} locked={running} onClose={onClose}>
      {paused && <p className="paused-strip units-sheet-strip">{MARKET_PAUSED_LINE}</p>}

      <AmountField
        id="buy-units"
        label="Units to buy"
        value={unitsText}
        unit="units"
        decimals={2}
        onChange={setUnitsText}
        onMax={() => setUnitsText(unitsFieldText(listing.unitsLeft))}
        maxDisabled={running}
      />
      {overLeft && (
        <p className="field-note field-note-problem">Only {fmtUnitsAmount(listing.unitsLeft)} units are left on this listing.</p>
      )}
      {overBalance && wallet !== undefined && (
        <p className="field-note field-note-problem">You have {fmtUnitsAmount(wallet.balance)} MUSD.</p>
      )}

      <dl className="summary-rows units-rows">
        <div className="summary-row">
          <dt>You pay</dt>
          <dd>{quoted === undefined ? dash : `${fmtFourDecimals(quoted.cost)} MUSD`}</dd>
        </div>
        <div className="summary-row">
          <dt>You receive</dt>
          <dd>
            {unitsWei === 0n || overLeft
              ? dash
              : `${fmtUnitsAmount(unitsWei)} units, worth ${fmtUnitsAmount(unitsWei)} MUSD once the ${date} loans are repaid`}
          </dd>
        </div>
        <div className="summary-row">
          <dt>You earn</dt>
          <dd>
            {quoted === undefined
              ? dash
              : `${fmtFourDecimals(unitsWei > quoted.cost ? unitsWei - quoted.cost : 0n)} MUSD, ${earn.toMaturityPct.toFixed(2)}% by ${date}`}
          </dd>
        </div>
      </dl>

      {plan.length > 0 && (
        <div className="summary-steps">
          <Stepper steps={engine.rows(plan)} />
        </div>
      )}

      {seedAuctionDates.includes(listing.maturity) && <p className="field-note">{AUCTION_NOTE}</p>}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </Sheet>
  );
}

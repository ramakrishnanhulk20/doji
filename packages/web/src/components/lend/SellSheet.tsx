"use client";

import { useEffect, useState } from "react";
import type { Address } from "viem";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useStepFlow, type FlowStep } from "../../hooks/useStepFlow";
import { useUnitMarket } from "../../hooks/useUnitMarket";
import { useWrite } from "../../hooks/useWrite";
import type { DateUnits } from "../../lib/lend";
import { formatDate } from "../../lib/stats";
import {
  MARKET_PAUSED_LINE,
  expiryChoices,
  fmtFourDecimals,
  fmtPrice,
  fmtUnitsAmount,
  listUnitsCall,
  listedId,
  sellerNetPrice,
  unitYield,
  unitsFieldText,
} from "../../lib/units";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { parseAmount } from "../borrow/format";
import { AmountField } from "../borrow/Steps";
import { Sheet } from "../loans/Sheet";
import "../borrow/borrow.css";
import "../loans/loans.css";
import "./lend.css";

type RunStep = { id: string; label: string } & FlowStep;

const PAR = 10n ** 18n;

type SellSheetProps = {
  row: DateUnits;
  address: Address;
  now: number;
  onClose: () => void;
};

export function SellSheet({ row, address, now, onClose }: SellSheetProps) {
  const gate = useLoanGate();
  const engine = useStepFlow<RunStep>();
  const { write, busy } = useWrite();
  const { settings } = useUnitMarket();
  const market = settings.data;

  const [unitsText, setUnitsText] = useState("");
  const [priceText, setPriceText] = useState("");
  const [expiryPick, setExpiryPick] = useState<number | null>(null);

  const date = formatDate(row.maturity);
  const choices = expiryChoices(row.maturity, now);
  const lastChoice = choices[choices.length - 1];
  const expiry = expiryPick !== null && choices.some((choice) => choice.expiry === expiryPick) ? expiryPick : (lastChoice?.expiry ?? 0);

  // A new choice of any input clears a failed run, so "Try again" never repeats stale numbers.
  useEffect(() => {
    if (!engine.running) engine.reset();
  }, [unitsText, priceText, expiry]);

  const unitsWei = parseAmount(unitsText);
  const priceWei = parseAmount(priceText);
  const overBalance = unitsWei > row.balance;
  const priceTooHigh = priceWei > PAR;
  const priceZero = priceText !== "" && priceWei === 0n;
  const priceValid = priceWei > 0n && priceWei <= PAR;
  const formReady = unitsWei > 0n && !overBalance && priceValid;

  const paused = market?.paused === true;
  const earn = unitYield(priceWei, row.maturity, now);
  const plan = formReady ? [{ id: "list-units", label: "List units" }] : [];

  const onConfirm = async () => {
    if (engine.failedAt !== null && engine.steps) {
      const retry = await engine.start(engine.steps, engine.failedAt);
      if (retry.ok && retry.last?.ok) {
        engine.reset();
        onClose();
      }
      return;
    }
    if (!formReady) return;
    // The step carries the numbers on screen now, so a retry never repeats stale ones.
    const units = unitsWei;
    const price = priceWei;
    const until = expiry;
    const runnable: RunStep[] = plan.map((step) => ({
      ...step,
      run: () =>
        write({
          ...listUnitsCall(address, row.maturity, units, price, until),
          successLine: (receipt) => {
            const id = listedId(receipt.logs);
            if (id === null) throw new Error("UnitMarket emitted no Listed event");
            return `Listed ${fmtUnitsAmount(units)} units of ${date} at ${fmtPrice(price)} MUSD each as listing #${id}.`;
          },
        }),
    }));
    const { ok, last } = await engine.start(runnable, 0);
    if (ok && last?.ok) {
      engine.reset();
      onClose();
    }
  };

  const running = engine.running || busy;

  const confirm = (() => {
    const off = (label: string) => ({ label, disabled: true, loading: false, onClick: () => undefined });
    if (!gate.isConnected) return { label: "Connect wallet to sell", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (paused) return off("List units");
    if (market === undefined) return off("Checking the numbers");
    if (unitsWei === 0n) return off("Enter an amount");
    if (priceText === "") return off("Enter a price");
    if (!formReady) return off("List units");
    if (engine.confirming) return off("Waiting for confirmation");
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (engine.failedAt !== null) {
      return { label: `Try again from step ${engine.failedAt + 1}`, disabled: false, loading: false, onClick: () => void onConfirm() };
    }
    return { label: "List units", disabled: false, loading: false, onClick: () => void onConfirm() };
  })();

  return (
    <Sheet title={`Sell units of ${date}`} locked={running} onClose={onClose}>
      {paused && <p className="paused-strip units-sheet-strip">{MARKET_PAUSED_LINE}</p>}

      <p className="units-field-label" aria-hidden="true">
        Units to sell
      </p>
      <AmountField
        id="sell-units"
        label="Units to sell"
        value={unitsText}
        unit="units"
        decimals={2}
        onChange={setUnitsText}
        onMax={() => setUnitsText(unitsFieldText(row.balance))}
        maxDisabled={running}
      />
      {overBalance && (
        <p className="field-note field-note-problem">
          You hold {fmtUnitsAmount(row.balance)} units of {date}.
        </p>
      )}

      <p className="units-field-label" aria-hidden="true">
        Price per unit
      </p>
      <div className="units-no-max">
        <AmountField id="sell-price" label="Price per unit" value={priceText} unit="MUSD" decimals={3} onChange={setPriceText} />
      </div>
      {priceTooHigh && (
        <p className="field-note field-note-problem">A unit pays 1 MUSD at most, so the price cannot be above 1.000.</p>
      )}
      {priceZero && <p className="field-note field-note-problem">Enter a price above 0.</p>}
      {priceValid && market !== undefined && (
        <p className="units-helper">
          At {fmtPrice(priceWei)} a buyer earns {earn.toMaturityPct.toFixed(2)}% by {date}, about {earn.perYearPct.toFixed(1)}% a year.
          You receive {fmtFourDecimals(sellerNetPrice(priceWei, market.feeBps))} MUSD a unit after Doji&apos;s{" "}
          {+(market.feeBps / 100).toFixed(2)}% fee.
        </p>
      )}

      <p className="units-field-label" aria-hidden="true">
        Open until
      </p>
      <div className="units-chips" role="radiogroup" aria-label="Open until">
        {choices.map((choice) => (
          <label key={choice.expiry} className="units-chip" data-selected={expiry === choice.expiry}>
            <input
              type="radio"
              name="sell-expiry"
              className="sr-only"
              checked={expiry === choice.expiry}
              disabled={running}
              onChange={() => setExpiryPick(choice.expiry)}
            />
            {choice.label}
          </label>
        ))}
      </div>

      {plan.length > 0 && (
        <div className="summary-steps">
          <Stepper steps={engine.rows(plan)} />
        </div>
      )}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </Sheet>
  );
}

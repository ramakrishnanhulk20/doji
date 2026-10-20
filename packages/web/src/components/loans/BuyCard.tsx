"use client";

import type { Hex } from "viem";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanSteps, type FlowStep } from "../../hooks/useLoanSteps";
import {
  approveMusdCall,
  buyDeadline,
  buySteps,
  exactText,
  formatCountdown,
  maxPayFor,
  musdText,
  purchaseCall,
  splitSale,
  toMusdNumber,
  type MusdWallet,
  type PositionView,
} from "../../lib/loans";
import { formatMusd } from "../../lib/stats";
import { LoanAuctionChart } from "../risk/AuctionChart";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { TweenText } from "../borrow/TweenText";
import type { SendCall } from "./RepaySheet";

type BuyCardProps = {
  view: PositionView;
  /** Unix seconds, refreshed with the price. */
  now: number;
  wallet: MusdWallet | undefined;
  send: SendCall;
  busy: boolean;
  onBought: (hash: Hex) => void;
};

export function BuyCard({ view, now, wallet, send, busy, onBought }: BuyCardProps) {
  const gate = useLoanGate();
  const flow = useLoanSteps();
  const { id, auction, auctionPrice: price } = view;

  if (auction === null || price === null) {
    return (
      <section className="buy-card" aria-labelledby="buy-title">
        <h2 id="buy-title" className="buy-title display-face">
          Buy this position
        </h2>
        <p className="field-note field-note-problem">
          The price is unavailable right now. Mezo&apos;s price feed may be more than 60 seconds old. Doji is trying again.
        </p>
      </section>
    );
  }

  const floorTime = auction.startTime + auction.duration;
  const split = splitSale(price, view.owed, auction.penaltyBps);
  const maxPay = maxPayFor(price);
  const plan = wallet === undefined ? [] : buySteps(maxPay, wallet.allowance);

  const reason = (() => {
    if (wallet === undefined) return "Checking your wallet";
    if (wallet.balance < price) return `You don't have that much MUSD. Your balance is ${musdText(wallet.balance)} MUSD.`;
    return null;
  })();

  const run = async () => {
    if (wallet === undefined) return;
    // The cap is fixed when the button is pressed, so the approval and the purchase agree even if the price moves.
    const cap = maxPay;
    const steps: FlowStep[] = buySteps(cap, wallet.allowance).map((step) => ({
      ...step,
      run: async () => {
        if (step.id === "approve") return send(approveMusdCall(cap), `Approved ${exactText(cap)} MUSD for Doji.`);
        const result = await send(purchaseCall(id, cap, buyDeadline(Math.floor(Date.now() / 1000))), `veBTC #${id} is yours.`);
        if (result.ok) onBought(result.hash);
        return result;
      },
    }));
    await flow.start(steps);
  };

  const running = flow.running || busy;
  const confirm = (() => {
    if (!gate.isConnected) return { label: "Connect wallet to buy", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (reason) return { label: reason, disabled: true, loading: false, onClick: () => undefined };
    if (flow.confirming) return { label: "Waiting for confirmation", disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow.failedAt !== null) {
      return { label: `Try again from step ${flow.failedAt + 1}`, disabled: false, loading: false, onClick: () => void flow.retry() };
    }
    return {
      label: `Buy veBTC #${id} for up to ${musdText(maxPay)} MUSD`,
      disabled: false,
      loading: false,
      onClick: () => void run(),
    };
  })();

  return (
    <section className="buy-card" aria-labelledby="buy-title">
      <h2 id="buy-title" className="buy-title display-face">
        Buy this position
      </h2>

      <p className="buy-price" aria-live="polite">
        <TweenText value={toMusdNumber(price)} format={formatMusd} />
        <span className="buy-price-unit">MUSD</span>
      </p>

      <dl className="buy-facts">
        <div className="buy-fact">
          <dt>Floor</dt>
          <dd>{musdText(auction.floorPrice)} MUSD</dd>
        </div>
        <div className="buy-fact">
          <dt>{now >= floorTime ? "Reached the floor" : "Time to the floor"}</dt>
          <dd>{now >= floorTime ? "now holding" : formatCountdown(floorTime - now)}</dd>
        </div>
      </dl>

      <LoanAuctionChart
        curve={{
          startTime: auction.startTime,
          duration: auction.duration,
          startValue: toMusdNumber(auction.startValue),
          floorPrice: toMusdNumber(auction.floorPrice),
          price: toMusdNumber(price),
          owed: toMusdNumber(view.owed),
        }}
        now={now}
      />

      <p className="buy-split">
        Lenders get {musdText(split.toMarket)} MUSD · protocol {musdText(split.toTreasury)} MUSD · borrower keeps{" "}
        {musdText(split.toBorrower)} MUSD
      </p>

      {plan.length > 0 && (
        <div className="summary-steps">
          <Stepper steps={flow.rows(plan)} />
        </div>
      )}

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
      <p className="summary-print">
        The price can move up a little within a block (Mezo&apos;s price feed); you never pay more than{" "}
        {musdText(maxPay)} MUSD.
      </p>
    </section>
  );
}

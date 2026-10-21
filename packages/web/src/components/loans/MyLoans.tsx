"use client";

import { useState } from "react";
import { motion } from "motion/react";
import { useLoanClock } from "../../hooks/useLoanClock";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanWrite } from "../../hooks/useLoanWrite";
import { useMyLoans } from "../../hooks/useLoans";
import { useVoteActions } from "../../hooks/useVotes";
import { btcText, claimCall, musdText, withdrawCall } from "../../lib/loans";
import { useReducedMotion } from "../../lib/motion-mode";
import { Button } from "../Button";
import "../borrow/borrow.css";
import "./loans.css";
import { ClaimStrip } from "./ClaimStrip";
import { ExtendLockSheet } from "./ExtendLockSheet";
import { PositionCard } from "./PositionCard";
import { RepaySheet } from "./RepaySheet";
import { RollSheet } from "./RollSheet";
import { VoteSheet } from "./VoteSheet";

type OpenSheet =
  | { kind: "repay"; id: bigint; fullOnly: boolean }
  | { kind: "roll"; id: bigint }
  | { kind: "vote"; id: bigint }
  | { kind: "extend"; id: bigint };

export function MyLoans() {
  const reduced = useReducedMotion();
  const gate = useLoanGate();
  const data = useMyLoans();
  const { send, busy } = useLoanWrite();
  const voteActions = useVoteActions(send);
  const now = useLoanClock(30_000);
  const [sheet, setSheet] = useState<OpenSheet | null>(null);
  const [acting, setActing] = useState<string | null>(null);

  const views = data.views.data;
  const claimables = data.claimables.data;
  const hasClaim = claimables !== undefined && (claimables.musd > 0n || claimables.btc > 0n);
  const sheetView = sheet && views ? views.find((view) => view.id === sheet.id) : undefined;

  const act = async (key: string, run: () => Promise<unknown>) => {
    setActing(key);
    try {
      await run();
    } finally {
      setActing(null);
    }
  };

  const rise = reduced ? { initial: false as const } : { initial: { opacity: 0, y: 16 }, animate: { opacity: 1, y: 0 } };

  return (
    <div className="app-page">
      <motion.div {...rise} transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
        <h1 className="app-page-title display-face">My loans</h1>
        <p className="app-page-subtitle">
          Everything Doji holds for this wallet: what you owe, by when, how safe each loan is, and the votes and rewards
          that stay yours.
        </p>
      </motion.div>

      <div className="app-page-body">
        {!gate.isConnected ? (
          <section className="loans-empty">
            <p className="loans-empty-line">Connect a wallet to see your loans.</p>
            <Button variant="secondary" onClick={gate.connect}>
              Connect wallet
            </Button>
          </section>
        ) : (
          <>
            {gate.wrongChain && (
              <div className="paused-strip loans-network">
                <span>Your wallet is on another network. Switch to Mezo testnet to repay, roll, withdraw or claim.</span>
                <Button className="loan-btn" variant="secondary" onClick={gate.switchNetwork}>
                  Switch to Mezo testnet
                </Button>
              </div>
            )}

            {hasClaim && claimables && (
              <ClaimStrip
                claimables={claimables}
                disabled={gate.wrongChain || busy}
                loading={acting === "claim"}
                onClaim={() =>
                  void act("claim", () =>
                    send(claimCall(), `Collected ${musdText(claimables.musd)} MUSD and ${btcText(claimables.btc)} BTC.`),
                  )
                }
              />
            )}

            {data.ids.isError || data.views.isError ? (
              <p className="field-note field-note-problem">
                Your positions are unavailable right now. Doji is trying again every 15 seconds.
              </p>
            ) : views === undefined ? (
              <div className="loans-grid" aria-busy="true">
                {[0, 1].map((slot) => (
                  <span key={slot} className="loan-skeleton shimmer">
                    <span className="sr-only">Loading</span>
                  </span>
                ))}
              </div>
            ) : views.length === 0 ? (
              <section className="loans-empty">
                <p className="loans-empty-line">No positions in Doji for this wallet yet.</p>
                <Button href="/borrow">Borrow MUSD</Button>
              </section>
            ) : (
              <div className="loans-grid">
                {views.map((view, index) => (
                  <PositionCard
                    key={String(view.id)}
                    view={view}
                    index={index}
                    now={now}
                    locked={gate.wrongChain}
                    acting={acting}
                    busy={busy}
                    voteActions={voteActions}
                    onVote={() => setSheet({ kind: "vote", id: view.id })}
                    onExtend={() => setSheet({ kind: "extend", id: view.id })}
                    onRepay={(fullOnly) => setSheet({ kind: "repay", id: view.id, fullOnly })}
                    onRoll={() => setSheet({ kind: "roll", id: view.id })}
                    onWithdraw={() =>
                      void act(`withdraw:${view.id}`, () => send(withdrawCall(view.id), `veBTC #${view.id} is back in your wallet.`))
                    }
                  />
                ))}
              </div>
            )}
          </>
        )}
      </div>

      {sheet?.kind === "repay" && sheetView && (
        <RepaySheet
          key={`repay-${sheet.id}`}
          view={sheetView}
          wallet={data.musd.data}
          fullOnly={sheet.fullOnly}
          send={send}
          busy={busy}
          onClose={() => setSheet(null)}
        />
      )}
      {sheet?.kind === "roll" && sheetView && (
        <RollSheet
          key={`roll-${sheet.id}`}
          view={sheetView}
          client={data.client}
          settings={data.settings.data}
          offers={data.offers.data}
          wallet={data.musd.data}
          send={send}
          busy={busy}
          onClose={() => setSheet(null)}
        />
      )}
      {sheet?.kind === "vote" && sheetView && (
        <VoteSheet
          key={`vote-${sheet.id}`}
          view={sheetView}
          now={now}
          send={send}
          busy={busy}
          onClose={() => setSheet(null)}
        />
      )}
      {sheet?.kind === "extend" && sheetView && (
        <ExtendLockSheet
          key={`extend-${sheet.id}`}
          view={sheetView}
          now={now}
          send={send}
          busy={busy}
          onClose={() => setSheet(null)}
        />
      )}
    </div>
  );
}

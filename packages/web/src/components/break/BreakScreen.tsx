"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { motion } from "motion/react";
import { useAccount } from "wagmi";
import { ISSUES_URL, STRANGER, buildAttacks, runAttack, type Attack, type AttackOutcome } from "../../lib/attacks";
import { useReducedMotion } from "../../lib/motion-mode";
import { AttackCard } from "./AttackCard";
import { RunControls, type RunMode } from "./RunControls";
import { useAttackTargets } from "./useAttackTargets";
import "./break.css";

const SKELETON_COUNT = 12;

type Stored = {
  /** The call and the address a result belongs to: a result is shown only while both still match. */
  call: string;
  account: string;
  outcome: AttackOutcome;
};

export function BreakScreen() {
  const { client, targets, failed, retry } = useAttackTargets();
  const { address, isConnected } = useAccount();
  const reduced = useReducedMotion();

  const [requested, setRequested] = useState<RunMode>("stranger");
  const [results, setResults] = useState<Record<string, Stored>>({});
  const [running, setRunning] = useState<string | null>(null);
  const [progress, setProgress] = useState<{ index: number; total: number } | null>(null);
  // The address a finished Run all was for, so the tally shows only for results that are still on screen.
  const [ranFor, setRanFor] = useState<string | null>(null);
  const alive = useRef(true);
  const scrollToTally = useRef(false);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const wallet = isConnected ? address : undefined;
  const mode: RunMode = requested === "wallet" && wallet ? "wallet" : "stranger";
  const account = mode === "wallet" && wallet ? wallet : STRANGER;

  const attacks = useMemo(() => (targets ? buildAttacks(targets, account) : null), [targets, account]);
  const busy = running !== null || progress !== null;

  const simulate = useCallback(
    async (attack: Attack) => {
      if (!client) return;
      setRunning(attack.id);
      try {
        const outcome = await runAttack(client, attack, account);
        if (alive.current) setResults((current) => ({ ...current, [attack.id]: { call: attack.call, account, outcome } }));
      } finally {
        if (alive.current) setRunning(null);
      }
    },
    [client, account],
  );

  const runAll = async () => {
    if (!attacks || busy) return;
    const runnable = attacks.filter((attack) => attack.unavailable === null);
    setRanFor(null);
    try {
      for (const [index, attack] of runnable.entries()) {
        if (!alive.current) return;
        setProgress({ index, total: runnable.length });
        // The card that is running scrolls into view, so a long grid never runs out of sight.
        document
          .getElementById(`attack-${attack.id}`)
          ?.scrollIntoView({ block: "nearest", behavior: reduced ? "auto" : "smooth" });
        await simulate(attack);
      }
      if (alive.current) {
        scrollToTally.current = true;
        setRanFor(account);
      }
    } finally {
      if (alive.current) setProgress(null);
    }
  };

  const outcomes = (attacks ?? []).map((attack) => {
    const stored = results[attack.id];
    return stored && stored.call === attack.call && stored.account === account ? stored.outcome : null;
  });
  const refused = outcomes.filter((outcome) => outcome?.kind === "refused" && outcome.matches).length;
  const unexpected = outcomes.filter((outcome) => outcome !== null && !(outcome.kind === "refused" && outcome.matches)).length;
  const notRunnable = (attacks ?? []).filter((attack) => attack.unavailable !== null).length;
  const showTally = attacks !== null && ranFor === account && !busy;

  // Run all ends on the last card, so the page comes back up to the tally once it is on screen.
  useEffect(() => {
    if (!showTally || !scrollToTally.current) return;
    scrollToTally.current = false;
    document.getElementById("break-tally")?.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
  }, [showTally, reduced]);

  const rise = reduced ? { initial: false as const } : { initial: { opacity: 0, y: 16 }, animate: { opacity: 1, y: 0 } };

  return (
    <div className="app-page">
      <motion.div {...rise} transition={{ duration: 0.5, ease: [0.22, 1, 0.36, 1] }}>
        <h1 className="app-page-title display-face">Try to break it</h1>
        <p className="app-page-subtitle">
          Every rule in Doji is enforced by the contracts. Run these attacks yourself. Nothing is sent: each one is
          simulated against the live contracts on Mezo testnet, and you see exactly how the contract refuses it.
        </p>
      </motion.div>

      <div className="app-page-body">
        <RunControls
          mode={mode}
          wallet={wallet}
          busy={busy}
          progress={progress}
          ready={attacks !== null && client !== undefined}
          onMode={setRequested}
          onRunAll={() => void runAll()}
        />

        {failed && (
          <p className="break-strip">
            The live contracts did not answer, so the attacks have nothing to aim at yet.{" "}
            <button type="button" className="break-text-button" onClick={retry}>
              Try again
            </button>
          </p>
        )}

        {showTally && attacks && (
          <p id="break-tally" className="break-tally" aria-live="polite">
            <span className="break-tally-safe">
              {refused} of {attacks.length} refused
            </span>
            {unexpected > 0 && <span className="break-tally-watch"> · {unexpected} unexpected</span>}
            {notRunnable > 0 && <span className="break-tally-dim"> · {notRunnable} could not run here</span>}
          </p>
        )}

        <div className="break-grid" aria-busy={attacks === null && !failed}>
          {attacks
            ? attacks.map((attack, index) => {
                const stored = results[attack.id];
                const outcome = stored && stored.call === attack.call && stored.account === account ? stored.outcome : null;
                return (
                  <motion.div
                    key={attack.id}
                    id={`attack-${attack.id}`}
                    className="break-cell"
                    initial={reduced ? false : { opacity: 0, y: 12 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 0.45, delay: reduced ? 0 : 0.18 + index * 0.06, ease: [0.22, 1, 0.36, 1] }}
                  >
                    <AttackCard
                      attack={attack}
                      outcome={outcome}
                      running={running === attack.id}
                      locked={busy}
                      onRun={() => void simulate(attack)}
                    />
                  </motion.div>
                );
              })
            : !failed &&
              Array.from({ length: SKELETON_COUNT }, (_, slot) => (
                <span key={slot} className="break-skeleton shimmer" aria-hidden="true" />
              ))}
        </div>

        <p className="break-closing">
          Found a way through?{" "}
          <a className="break-link" href={ISSUES_URL} target="_blank" rel="noopener noreferrer">
            Open an issue on GitHub.
          </a>
        </p>
      </div>
    </div>
  );
}

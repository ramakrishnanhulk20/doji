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
  const alive = useRef(true);

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
    try {
      for (const [index, attack] of runnable.entries()) {
        if (!alive.current) return;
        setProgress({ index, total: runnable.length });
        await simulate(attack);
      }
    } finally {
      if (alive.current) setProgress(null);
    }
  };

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

        <div className="break-grid" aria-busy={attacks === null && !failed}>
          {attacks
            ? attacks.map((attack, index) => {
                const stored = results[attack.id];
                const outcome = stored && stored.call === attack.call && stored.account === account ? stored.outcome : null;
                return (
                  <motion.div
                    key={attack.id}
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

"use client";

import { useState } from "react";
import { useLoanGate } from "../../hooks/useLoanGate";
import { useLoanSteps, type FlowStep } from "../../hooks/useLoanSteps";
import { useVoterAddresses, useVotePools, useVotes } from "../../hooks/useVotes";
import type { PositionView } from "../../lib/loans";
import { formatDate } from "../../lib/stats";
import { buildVoteCall, evenSplit, loanAllowsVoting, voteCutoff, voterRefusal, votingClosed } from "../../lib/votes";
import { Button } from "../Button";
import { Stepper } from "../app/Stepper";
import { Sheet } from "./Sheet";
import type { SendCall } from "./RepaySheet";

type VoteSheetProps = {
  view: PositionView;
  now: number;
  send: SendCall;
  busy: boolean;
  onClose: () => void;
};

const PLAN = [{ id: "vote", label: "Vote" }];

export function VoteSheet({ view, now, send, busy, onClose }: VoteSheetProps) {
  const gate = useLoanGate();
  const flow = useLoanSteps();
  const pools = useVotePools();
  const addresses = useVoterAddresses();
  const votes = useVotes(view.id);
  const { id, lock } = view;

  const maxVotes = addresses.data?.maxVotes ?? 0;
  const list = pools.data ?? [];
  const defaults = list.filter((entry) => entry.alive).slice(0, maxVotes).map((entry) => entry.pool);

  const [picks, setPicks] = useState<string[] | null>(null);
  const [typed, setTyped] = useState<Record<string, string>>({});

  const chosen = picks ?? defaults;
  const split = evenSplit(chosen.length);
  const weightText = (pool: string): string => typed[pool] ?? String(split[chosen.indexOf(pool)] ?? "");
  const weights = chosen.map((pool) => Number(weightText(pool)) || 0);
  const total = weights.reduce((sum, weight) => sum + weight, 0);

  const toggle = (pool: string) => {
    const next = chosen.includes(pool) ? chosen.filter((entry) => entry !== pool) : [...chosen, pool];
    setPicks(list.filter((entry) => next.includes(entry.pool)).map((entry) => entry.pool));
    setTyped({});
  };

  const cutoff = voteCutoff(lock);
  const closed = votingClosed(lock, now);
  const refusal = votes.data ? voterRefusal("vote", votes.data.lastVoted, now) : null;

  const reason = (() => {
    if (pools.isPending || addresses.isPending || votes.isPending) return "Checking the pools";
    if (closed && cutoff !== null) return `Votes closed on ${formatDate(cutoff)}`;
    if (!loanAllowsVoting(view)) return "Only an on-time, safe loan can vote";
    if (refusal) return "Vote";
    if (chosen.length === 0) return "Pick at least one pool";
    if (chosen.length > maxVotes) return `Pick at most ${maxVotes} pools`;
    if (weights.some((weight) => weight < 1)) return "Each pool needs at least 1%";
    if (total !== 100) return "Total must be 100%";
    return null;
  })();

  const run = async () => {
    const call = buildVoteCall(id, chosen as `0x${string}`[], weights);
    const steps: FlowStep[] = PLAN.map((step) => ({ ...step, run: () => send(call, `Voted with veBTC #${id}.`) }));
    if (await flow.start(steps)) onClose();
  };

  const running = flow.running || busy;
  const confirm = (() => {
    if (!gate.isConnected) return { label: "Connect wallet to vote", disabled: false, loading: false, onClick: gate.connect };
    if (gate.wrongChain) return { label: "Switch to Mezo testnet", disabled: false, loading: false, onClick: gate.switchNetwork };
    if (reason) return { label: reason, disabled: true, loading: false, onClick: () => undefined };
    if (flow.confirming) return { label: "Waiting for confirmation", disabled: true, loading: false, onClick: () => undefined };
    if (running) return { label: "Working...", disabled: true, loading: true, onClick: () => undefined };
    if (flow.failedAt !== null) {
      return {
        label: `Try again from step ${flow.failedAt + 1}`,
        disabled: false,
        loading: false,
        onClick: () => void flow.retry().then((done) => done && onClose()),
      };
    }
    return { label: "Vote", disabled: false, loading: false, onClick: () => void run() };
  })();

  return (
    <Sheet title={`Vote with veBTC #${id}`} locked={running} onClose={onClose}>
      <p className="loan-sheet-lead">
        Doji holds this veBTC and casts the vote for you. Pick the pools and split the weight between them.
      </p>

      {pools.isPending ? (
        <div className="vote-pools" aria-busy="true">
          {[0, 1, 2].map((slot) => (
            <span key={slot} className="pool-skeleton shimmer" />
          ))}
        </div>
      ) : pools.isError ? (
        <p className="field-note field-note-problem">The pools could not be read right now. Doji is trying again.</p>
      ) : list.length === 0 ? (
        <p className="field-note field-note-plain">Mezo's voter lists no pools yet.</p>
      ) : (
        <div className="vote-pools" role="group" aria-label="Pools to vote for">
          {list.map((entry) => {
            const checked = chosen.includes(entry.pool);
            const overLimit = !checked && chosen.length >= maxVotes;
            const unavailable = !entry.alive || overLimit;
            return (
              <div key={entry.pool} className="pool-row" data-checked={checked} data-disabled={unavailable}>
                <label className="pool-pick">
                  <input
                    type="checkbox"
                    className="sr-only"
                    checked={checked}
                    disabled={unavailable || running}
                    onChange={() => toggle(entry.pool)}
                  />
                  <span className="pool-box" aria-hidden="true">
                    <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                      <path d="M2.5 6.5 5 9l4.5-5.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
                    </svg>
                  </span>
                  <span className="pool-text">
                    <span className="pool-name">{entry.symbol}</span>
                    <span className="pool-gauge">{entry.alive ? "gauge live" : "gauge closed"}</span>
                  </span>
                </label>
                {checked && (
                  <span className="weight-field">
                    <input
                      className="weight-input"
                      inputMode="numeric"
                      autoComplete="off"
                      aria-label={`Weight for ${entry.symbol} in percent`}
                      value={weightText(entry.pool)}
                      disabled={running}
                      onChange={(event) =>
                        setTyped((current) => ({ ...current, [entry.pool]: event.target.value.replace(/\D/g, "").slice(0, 3) }))
                      }
                    />
                    <span className="weight-unit" aria-hidden="true">
                      %
                    </span>
                  </span>
                )}
              </div>
            );
          })}
        </div>
      )}

      <p className="vote-total" data-valid={total === 100}>
        <span>Total</span>
        <span>{total}%</span>
      </p>

      <p className="field-note field-note-plain">
        {cutoff === null
          ? "Your lock is permanent, so votes never close."
          : `Votes close one week before your lock ends (${formatDate(cutoff)}).`}
      </p>
      {refusal && <p className="field-note field-note-plain">{refusal}</p>}

      <div className="summary-steps">
        <Stepper steps={flow.rows(PLAN)} />
      </div>

      <Button className="confirm-button" disabled={confirm.disabled} loading={confirm.loading} onClick={confirm.onClick}>
        {confirm.label}
      </Button>
    </Sheet>
  );
}

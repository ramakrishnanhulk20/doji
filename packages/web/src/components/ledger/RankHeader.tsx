"use client";

import { useReducedMotion } from "../../lib/motion-mode";
import type { WalletProgress } from "../../lib/quests/exp";
import { openConnectModal } from "../app/connect-modal-store";
import { Button } from "../Button";
import { CountValue } from "../CountValue";
import { BrushProgress } from "./BrushProgress";
import { PaperSheet } from "./PaperSheet";
import { RANK_TEXT } from "./rank-names";
import { RankSeal } from "./RankSeal";
import "./ledger.css";

const formatExp = (value: number) => Math.round(value).toLocaleString("en-US");

type RankHeaderProps = {
  /** True when a wallet is connected. */
  connected: boolean;
  /** Undefined while the first read for the connected wallet is still going. */
  progress: WalletProgress | undefined;
};

export function RankHeader({ connected, progress }: RankHeaderProps) {
  const reduced = useReducedMotion();

  return (
    <div className="rank-header">
      {!connected && (
        <>
          <Button variant="primary" arrow onClick={openConnectModal}>
            Connect wallet
          </Button>
          <p className="rank-header-help">Any wallet app works, on a phone or a laptop. You need no tokens to start.</p>
        </>
      )}

      {connected && progress === undefined && (
        <div className="rank-header-loading" role="status">
          <p className="rank-header-help rank-header-loading-text">Reading your ledger from the chain.</p>
          <span className="shimmer rank-header-shimmer" aria-hidden="true" />
        </div>
      )}

      {connected && progress !== undefined && <RankReading progress={progress} reduced={reduced} />}

      <p className="rank-header-rankings">
        <a className="link-draw" href="/quests#rankings">
          See the rankings
        </a>
      </p>
    </div>
  );
}

export function RankReading({ progress, reduced }: { progress: WalletProgress; reduced: boolean }) {
  const { rank, next, exp } = progress;
  const text = RANK_TEXT[rank.id];
  const fill = next === null ? 1 : (exp - rank.exp) / (next.exp - rank.exp);

  return (
    <>
      <div className="rank-header-row">
        <PaperSheet className="rank-header-chip">
          <RankSeal rank={rank.id} size={72} />
        </PaperSheet>
        <div>
          <p className="rank-header-name display-face">{text.name}</p>
          <p className="rank-header-meaning">{text.meaning}</p>
        </div>
      </div>

      <p className="rank-header-exp">
        <CountValue value={exp} format={formatExp} reduced={reduced} />
        {" EXP"}
      </p>
      {!progress.complete && <p className="rank-header-note">Still reading the chain. Your total may be higher.</p>}
      <div className="rank-header-bar">
        <BrushProgress value={fill} reduced={reduced} tone="ink" />
      </div>
      <p className="rank-header-note">
        {next === null ? "Top rank reached." : `${formatExp(next.exp - exp)} EXP to ${RANK_TEXT[next.id].name}`}
      </p>
    </>
  );
}

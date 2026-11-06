"use client";

import type { Address } from "viem";
import { useAccount } from "wagmi";
import { useQuests } from "../../hooks/useQuests";
import { parseAddress } from "../../lib/address";
import { isDojiWallet } from "../../lib/doji-wallets";
import { useReducedMotion } from "../../lib/motion-mode";
import type { WalletProgress } from "../../lib/quests/exp";
import { LedgerStage } from "./LedgerStage";
import { QuestPage } from "./QuestPage";
import { RankReading } from "./RankHeader";
import "./ledger.css";

function OwnerHeader({ address, progress }: { address: Address; progress: WalletProgress | undefined }) {
  const reduced = useReducedMotion();

  return (
    <div className="rank-header">
      <p className="wallet-owner-label">This ledger belongs to</p>
      <p className="wallet-owner-address">{address}</p>
      {progress === undefined ? (
        <span className="shimmer rank-header-shimmer" aria-hidden="true" />
      ) : (
        <RankReading progress={progress} reduced={reduced} />
      )}
      {isDojiWallet(address) && <p className="wallet-owner-doji">This wallet belongs to Doji.</p>}
    </div>
  );
}

function OtherWalletLedger({ address }: { address: Address }) {
  const progress = useQuests(address);
  return <LedgerStage progress={progress ?? null} header={<OwnerHeader address={address} progress={progress} />} readOnly />;
}

/**
 * One wallet's public ledger. `address` comes from the URL, so it is only ever shown and read (C76). The only way to a
 * claim or a quest button is QuestPage, which acts for the connected wallet and is reached only when that wallet is this
 * one.
 */
export function WalletLedger({ address }: { address: Address }) {
  const { address: connected } = useAccount();
  return parseAddress(connected) === address ? <QuestPage /> : <OtherWalletLedger address={address} />;
}

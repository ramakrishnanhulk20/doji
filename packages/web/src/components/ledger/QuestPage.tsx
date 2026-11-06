"use client";

import { useAccount } from "wagmi";
import { useQuests } from "../../hooks/useQuests";
import { LedgerStage } from "./LedgerStage";
import { RankHeader } from "./RankHeader";

export function QuestPage() {
  const { address } = useAccount();
  const progress = useQuests(address);

  // With no wallet, or while its first read is going, every quest shows open and the cover shows no seal.
  return (
    <LedgerStage
      progress={address === undefined ? null : (progress ?? null)}
      header={<RankHeader connected={address !== undefined} progress={progress} />}
    />
  );
}

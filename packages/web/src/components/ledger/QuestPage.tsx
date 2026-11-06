"use client";

import { useCallback, useLayoutEffect, useRef, useState } from "react";
import type { Address } from "viem";
import { useAccount } from "wagmi";
import { useQuests } from "../../hooks/useQuests";
import { parseAddress } from "../../lib/address";
import type { WalletProgress } from "../../lib/quests/exp";
import type { RankId } from "../../lib/quests/ranks";
import { QUESTS, type QuestId } from "../../lib/quests/table";
import { showToast } from "../app/toast-store";
import { QUEST_COPY } from "./chapters";
import { LedgerStage } from "./LedgerStage";
import { RankHeader } from "./RankHeader";
import { RankUp } from "./RankUp";

const NOTHING_LANDING: ReadonlySet<QuestId> = new Set();

const tableExp = (id: QuestId) => QUESTS.find((quest) => quest.id === id)?.exp ?? 0;

function newlyDone(before: WalletProgress, after: WalletProgress): QuestId[] {
  const earlier = new Set(before.quests.filter((quest) => quest.done).map((quest) => quest.id));
  return after.quests.filter((quest) => quest.done && !earlier.has(quest.id)).map((quest) => quest.id);
}

// A bug bonus has no fixed size in the quest table, so it is whatever the rise in EXP leaves after the fixed quests.
function expEarned(id: QuestId, landed: readonly QuestId[], before: WalletProgress, after: WalletProgress): number {
  if (id !== "bug") return tableExp(id);
  return after.exp - before.exp - landed.reduce((sum, quest) => sum + tableExp(quest), 0);
}

export function QuestPage() {
  const { address } = useAccount();
  const progress = useQuests(address);

  // The last read that finished, so a partial read in between cannot look like quests lost and then earned again (C70).
  const lastRead = useRef<WalletProgress | null>(null);
  const [landing, setLanding] = useState(NOTHING_LANDING);
  const [risen, setRisen] = useState<{ rank: RankId; address: Address } | null>(null);

  // A layout effect: this read's seal is drawn plain in the same commit, and it must never reach the screen before the stamp.
  useLayoutEffect(() => {
    const wallet = parseAddress(address);
    if (lastRead.current !== null && lastRead.current.address !== wallet) {
      lastRead.current = null;
      setLanding(NOTHING_LANDING);
      setRisen(null);
    }
    if (progress === undefined || !progress.complete || progress.address !== wallet) return;

    const before = lastRead.current;
    lastRead.current = progress;
    if (before === null) return;

    const landed = newlyDone(before, progress);
    if (landed.length > 0) setLanding((current) => new Set([...current, ...landed]));
    for (const id of landed) {
      const detail = `${QUEST_COPY[id].title}. +${expEarned(id, landed, before, progress)} EXP`;
      showToast({ id: `new-seal-${progress.address}-${id}`, kind: "done", title: "New seal", detail });
    }
    if (progress.rank.exp > before.rank.exp) setRisen({ rank: progress.rank.id, address: progress.address });
  }, [address, progress]);

  const closeRankUp = useCallback(() => setRisen(null), []);

  // With no wallet, or while its first read is going, every quest shows open and the cover shows no seal.
  return (
    <>
      <LedgerStage
        progress={address === undefined ? null : (progress ?? null)}
        header={<RankHeader connected={address !== undefined} progress={progress} />}
        landing={landing}
      />
      {risen !== null && <RankUp rank={risen.rank} address={risen.address} onClose={closeRankUp} />}
    </>
  );
}

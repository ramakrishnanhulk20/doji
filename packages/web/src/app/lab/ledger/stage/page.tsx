import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { LedgerStage } from "../../../../components/ledger/LedgerStage";
import labSample from "../../../../components/ledger/lab-sample.json";
import type { WalletProgress } from "../../../../lib/quests/exp";

export const metadata: Metadata = {
  title: "Ledger stage lab",
  robots: { index: false, follow: false },
};

// A real wallet read from the chain by scripts/save-lab-sample.ts, the same one the ledger lab uses.
const SAMPLE = labSample as WalletProgress;

export default function LabLedgerStagePage() {
  // Same guard as the ledger lab: the stage is tried here first and never shown to visitors.
  if (process.env.NODE_ENV === "production") notFound();
  return (
    <main>
      <LedgerStage progress={SAMPLE} />
    </main>
  );
}

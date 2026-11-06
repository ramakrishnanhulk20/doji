import type { Metadata } from "next";
import { QuestBoard } from "../../../components/ledger/QuestBoard";
import { QuestPage } from "../../../components/ledger/QuestPage";

// The site's title template would add a second "| Doji", so this one title is written out whole.
export const metadata: Metadata = {
  title: { absolute: "Quests | Doji" },
  description: "Try Doji with free test tokens, earn red seals in your ledger and rise through the ranks of an Osaka merchant house.",
};

export default function QuestsPage() {
  return (
    <>
      <QuestPage />
      <QuestBoard />
    </>
  );
}

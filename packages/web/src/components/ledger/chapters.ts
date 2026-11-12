import type { Hex } from "viem";
import type { WalletProgress } from "../../lib/quests/exp";
import { BONUS_EXP_CAP, QUESTS, type Chapter, type QuestId } from "../../lib/quests/table";

export type ChapterInfo = { id: Chapter; numeral: string; name: string; line: string };

export const CHAPTERS: readonly ChapterInfo[] = [
  { id: "first", numeral: "一", name: "First steps", line: "Get set up and take your first loan." },
  { id: "lender", numeral: "二", name: "The lender", line: "Put your MUSD to work." },
  { id: "thursday", numeral: "三", name: "Thursday", line: "These open up once a Thursday has passed." },
  { id: "hard", numeral: "四", name: "Hard mode", line: "For people who want to dig." },
];

export const EXP_SENTENCE = "EXP has no cash value. Doji may use it in future under terms published then. Nothing is promised.";

export type QuestCopy = {
  title: string;
  steps: readonly string[];
  need: string;
  /** A button with no href does nothing yet. */
  button: { label: string; href?: string };
};

export const QUEST_COPY: Record<QuestId, QuestCopy> = {
  kit: {
    title: "Claim your starter kit",
    steps: ["Connect your wallet.", "Press Claim.", "In a few seconds, 0.001 test BTC and 25 test MUSD arrive."],
    need: "Just a wallet. Doji pays the fee.",
    button: { label: "Claim" },
  },
  borrow: {
    title: "Lock Bitcoin and borrow",
    steps: [
      "Open Borrow.",
      "Lock 0.0005 test BTC.",
      "Pick a Thursday at least two weeks away and borrow 10 MUSD, so you can vote too.",
      "Confirm in your wallet.",
    ],
    need: "Your starter kit.",
    button: { label: "Open Borrow", href: "/borrow" },
  },
  vote: {
    title: "Vote with your locked Bitcoin",
    steps: [
      "Open My loans.",
      "If Votes says closed, press Extend on the Lock row and pick the next Thursday.",
      "Press Vote, pick a pool and confirm.",
    ],
    need: "A loan on Doji. Votes close a week before the lock ends, and Extend reopens them.",
    button: { label: "Open my loans", href: "/loans" },
  },
  paydown: {
    title: "Let rewards pay your loan",
    steps: ["Open your loan.", "Press Turn on pay-down.", "Confirm in your wallet."],
    need: "A loan on Doji.",
    button: { label: "Open my loans", href: "/loans" },
  },
  repay: {
    title: "Repay your loan",
    steps: ["Open your loan.", "Press Repay.", "Approve the MUSD, then confirm."],
    need: "A little MUSD for the interest. Your starter kit covers it.",
    button: { label: "Open my loans", href: "/loans" },
  },
  home: {
    title: "Take your position back",
    steps: ["Repay your loan first.", "Open it and press Withdraw veBTC.", "Confirm in your wallet."],
    need: "A repaid loan.",
    button: { label: "Open my loans", href: "/loans" },
  },
  parked: {
    title: "Post an offer that earns in sMUSD",
    steps: ["Open Lend.", "Pick a Thursday and a rate.", "Type 10 MUSD.", "Leave Earn in sMUSD while it waits on, and confirm."],
    need: "10 MUSD from your starter kit.",
    button: { label: "Open Lend", href: "/lend" },
  },
  stranger: {
    title: "A stranger borrows from your offer",
    steps: [
      "Post an offer at a rate people will take.",
      "Share Doji with a friend, or wait.",
      "This seal lands when another wallet borrows from your offer.",
    ],
    need: "An open offer.",
    button: { label: "Open Lend", href: "/lend" },
  },
  units: {
    title: "Claim your credit units",
    steps: ["Wait until someone borrows from your offer.", "Open Lend and find Your credit units.", "Press Claim units."],
    need: "An offer someone borrowed from.",
    button: { label: "Open Lend", href: "/lend" },
  },
  sell: {
    title: "Sell credit units",
    steps: ["Open Lend, then Your credit units.", "Press Sell units.", "Set a price up to 1.000 and list them."],
    need: "Credit units.",
    button: { label: "Open Lend", href: "/lend" },
  },
  buy: {
    title: "Buy credit units",
    steps: ["Open Lend, then Credit units for sale.", "Press Buy units on someone else's listing.", "Approve the MUSD, then confirm."],
    need: "A little MUSD.",
    button: { label: "Open Lend", href: "/lend" },
  },
  payout: {
    title: "Collect a payout",
    steps: ["Hold credit units past their Thursday.", "Open Lend, then Your credit units.", "Press Redeem, or Withdraw what's collected."],
    need: "Credit units from a date that has passed.",
    button: { label: "Open Lend", href: "/lend" },
  },
  harvest: {
    title: "Press Pay down now",
    steps: ["Find a loan with pay-down on.", "Check that it shows MUSD to repay.", "Press Pay down now and confirm."],
    need: "Any loan with rewards waiting. Pressing on someone else's loan counts.",
    button: { label: "Open my loans", href: "/loans" },
  },
  roll: {
    title: "Roll a loan to a later Thursday",
    steps: ["Open your loan.", "Press Roll to a later date.", "Pick a later Thursday and confirm."],
    need: "A loan on Doji.",
    button: { label: "Open my loans", href: "/loans" },
  },
  auction: {
    title: "Buy a loan at auction",
    steps: ["Open the landing page: every loan in auction is listed above its auction chart.", "Open it and check the price.", "Press the Buy button and confirm."],
    need: "Enough MUSD for the price.",
    button: { label: "See auctions", href: "/" },
  },
  bug: {
    title: "Report a real bug",
    steps: [
      "Find something that breaks or looks wrong.",
      "Write down what you did and what happened.",
      "Open an issue with your wallet address.",
    ],
    need: "Up to 1,000 EXP. Doji checks each report by hand, and your wallet goes on a public list only if you say yes.",
    button: { label: "Open an issue", href: "https://github.com/ramakrishnanhulk20/doji/issues/new" },
  },
};

/** Kanji and the EXP line come from the quest table, so a row changed there changes here. */
export const QUEST_FACTS = Object.fromEntries(
  QUESTS.map((quest) => [
    quest.id,
    {
      kanji: quest.kanji,
      expLabel: quest.id === "bug" ? `up to ${BONUS_EXP_CAP.toLocaleString("en-US")} EXP` : `+${quest.exp} EXP`,
    },
  ]),
) as Record<QuestId, { kanji: string; expLabel: string }>;

export type Entry = {
  id: QuestId;
  chapter: Chapter;
  /** Counts across the whole book, from 1. */
  number: number;
  /** The row's place in the quest table, from 0. It tilts the empty outline. */
  position: number;
  kanji: string;
  title: string;
  expLabel: string;
  done: boolean;
  at?: number;
  hash?: Hex;
};

export function entriesOf(progress: WalletProgress): Entry[] {
  return QUESTS.map((quest, position) => {
    const state = progress.quests.find((item) => item.id === quest.id);
    return {
      id: quest.id,
      chapter: quest.chapter,
      number: position + 1,
      position,
      kanji: QUEST_FACTS[quest.id].kanji,
      title: QUEST_COPY[quest.id].title,
      expLabel: QUEST_FACTS[quest.id].expLabel,
      done: state?.done === true,
      at: state?.at,
      hash: state?.hash,
    };
  });
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "19 Nov 2026", in UTC so the same block shows the same day everywhere. */
export function ledgerDate(seconds: number): string {
  const date = new Date(seconds * 1000);
  return `${date.getUTCDate()} ${MONTHS[date.getUTCMonth()] ?? ""} ${date.getUTCFullYear()}`;
}

/** Degrees from -4 to 4. A done quest tilts by its transaction hash so each seal differs and keeps its tilt between visits. */
export function sealTilt(entry: { hash?: Hex; position: number }): number {
  const seed = entry.hash === undefined ? entry.position : Number.parseInt(entry.hash.slice(-2), 16);
  return (seed % 9) - 4;
}

export const explorerTx = (hash: Hex): string => `https://explorer.test.mezo.org/tx/${hash}`;

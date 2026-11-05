import type { CSSProperties } from "react";
import { Seal } from "../Seal";
import { ledgerDate, sealTilt, type Entry } from "./chapters";
import type { QuestId } from "../../lib/quests/table";
import "./ledger.css";

type QuestEntryProps = {
  entry: Entry;
  /** "column" is one column of a spread page. "row" is a line in the stacked layout below 1024. */
  variant: "column" | "row";
  onOpen: (id: QuestId) => void;
};

const pad = (value: number) => String(value).padStart(2, "0");

// The Seal draws its red square 56 units wide inside a 64 unit box, so a 76px red square needs a box of 76 * 64 / 56.
const COLUMN_SEAL_BOX = (76 * 64) / 56;
const ROW_SEAL_BOX = 56;

export function QuestEntry({ entry, variant, onOpen }: QuestEntryProps) {
  const { id, done, at, kanji, title, expLabel } = entry;
  const date = done && at !== undefined ? ledgerDate(at) : null;
  const label = done ? (date === null ? `${title}, done` : `${title}, done on ${date}`) : `${title}, not done`;
  const tilt = { "--tilt": `${sealTilt(entry)}deg` } as CSSProperties;
  const markSize = variant === "column" ? COLUMN_SEAL_BOX : ROW_SEAL_BOX;

  const mark = done ? (
    <span className="ledger-entry-seal" style={tilt}>
      <Seal size={markSize} title="" />
    </span>
  ) : (
    <span className="ledger-entry-outline" style={tilt} aria-hidden="true" />
  );

  if (variant === "row") {
    return (
      <button
        type="button"
        className="ledger-entry ledger-entry-row"
        data-done={done}
        aria-label={label}
        onClick={() => onOpen(id)}
      >
        <span className="ledger-entry-kanji" lang="ja">
          {kanji}
        </span>
        <span className="ledger-entry-text">
          <span className="ledger-entry-title">{title}</span>
          <span className="ledger-entry-exp">{expLabel}</span>
        </span>
        <span className="ledger-entry-mark">
          {mark}
          {date !== null && <span className="ledger-entry-date">{date}</span>}
        </span>
      </button>
    );
  }

  return (
    <button
      type="button"
      className="ledger-entry ledger-entry-column"
      data-done={done}
      aria-label={label}
      onClick={() => onOpen(id)}
    >
      <span className="ledger-entry-number">{pad(entry.number)}</span>
      <span className="ledger-entry-art">
        <span className="ledger-entry-cluster">
          <span className="ledger-entry-kanji" lang="ja">
            {kanji}
          </span>
          {mark}
        </span>
        {date !== null && <span className="ledger-entry-date">{date}</span>}
      </span>
      <span className="ledger-entry-title">{title}</span>
      <span className="ledger-entry-exp">{expLabel}</span>
    </button>
  );
}

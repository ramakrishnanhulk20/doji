import type { QuestId } from "../../lib/quests/table";
import { EXP_SENTENCE, type ChapterInfo, type Entry } from "./chapters";
import { ThreadBinding } from "./LedgerCover";
import { PaperSheet } from "./PaperSheet";
import { QuestEntry } from "./QuestEntry";
import "./ledger.css";

type LedgerSpreadProps = {
  chapter: ChapterInfo;
  entries: readonly Entry[];
  onOpen: (id: QuestId) => void;
  landing?: ReadonlySet<QuestId>;
};

const COLUMNS_PER_PAGE = 3;

function ChapterBlock({ chapter }: { chapter: ChapterInfo }) {
  return (
    <div className="ledger-chapter">
      <span className="ledger-chapter-numeral" lang="ja" aria-hidden="true">
        {chapter.numeral}
      </span>
      <h3 className="ledger-chapter-name display-face">{chapter.name}</h3>
      <p className="ledger-chapter-line">{chapter.line}</p>
    </div>
  );
}

type PageProps = {
  side: "left" | "right";
  chapter: ChapterInfo;
  /** The whole chapter. Each page takes its own three columns from it. */
  entries: readonly Entry[];
  onOpen: (id: QuestId) => void;
  landing?: ReadonlySet<QuestId>;
};

// Each page always draws three ruled columns, so a chapter with few quests leaves blank ruled columns. A right page with
// no entry at all carries the chapter numeral large and faint, so the open book never shows an empty sheet.
export function LedgerPage({ side, chapter, entries, onOpen, landing }: PageProps) {
  const first = side === "left" ? 0 : COLUMNS_PER_PAGE;
  const own = entries.slice(first, first + COLUMNS_PER_PAGE);
  return (
    <PaperSheet className={`ledger-page ledger-page-${side}`}>
      <span className="ledger-page-rule ledger-page-rule-top" aria-hidden="true" />
      <span className="ledger-page-rule ledger-page-rule-bottom" aria-hidden="true" />
      <span className="ledger-gutter" aria-hidden="true" />
      <div className="ledger-page-head">{side === "left" && <ChapterBlock chapter={chapter} />}</div>
      <div className="ledger-page-body">
        {side === "right" && own.length === 0 && (
          <span className="ledger-page-numeral" lang="ja" aria-hidden="true">
            {chapter.numeral}
          </span>
        )}
        {Array.from({ length: COLUMNS_PER_PAGE }, (_, index) => {
          const entry = own[index];
          return (
            <div key={index} className="ledger-page-column">
              {entry && <QuestEntry entry={entry} variant="column" onOpen={onOpen} landing={landing?.has(entry.id)} />}
            </div>
          );
        })}
      </div>
      <div className="ledger-page-foot">{side === "right" && <p className="ledger-exp-note">{EXP_SENTENCE}</p>}</div>
    </PaperSheet>
  );
}

// Both layouts are in the page and CSS shows one, so the first paint never flashes the wrong one and no script has to
// measure the window. The hidden one is display: none, so its buttons are out of the tab order too.
export function LedgerSpread({ chapter, entries, onOpen, landing }: LedgerSpreadProps) {
  return (
    <div className="ledger-spread">
      <div className="ledger-spread-wide">
        <LedgerPage side="left" chapter={chapter} entries={entries} onOpen={onOpen} landing={landing} />
        <LedgerPage side="right" chapter={chapter} entries={entries} onOpen={onOpen} landing={landing} />
      </div>
      <PaperSheet className="ledger-stack">
        <ThreadBinding ticks={false} />
        <ChapterBlock chapter={chapter} />
        <div className="ledger-stack-rows">
          {entries.map((entry) => (
            <QuestEntry key={entry.id} entry={entry} variant="row" onOpen={onOpen} landing={landing?.has(entry.id)} />
          ))}
        </div>
        <p className="ledger-exp-note">{EXP_SENTENCE}</p>
      </PaperSheet>
    </div>
  );
}

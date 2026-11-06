import { PaperSheet } from "./PaperSheet";
import { RankSeal, type Rank } from "./RankSeal";
import "./ledger.css";

const TICKS = [12, 37, 63, 88];

// Japanese books bind on the right, so the thread runs down the right edge. The svg is as wide as the ticks are long and
// sits flush right, which puts the line itself 16px in.
export function ThreadBinding({ ticks }: { ticks: boolean }) {
  return (
    <svg className="ledger-thread" aria-hidden="true" focusable="false">
      <line x1="0" y1="0" x2="0" y2="100%" stroke="var(--sumi)" strokeWidth="1.5" />
      {ticks &&
        TICKS.map((percent) => (
          <line key={percent} x1="0" y1={`${percent}%`} x2="100%" y2={`${percent}%`} stroke="var(--sumi)" strokeWidth="1.5" />
        ))}
    </svg>
  );
}

// The cord is drawn in a 40 x 94 box whose zero point is where it leaves the top edge. Stroke widths do not scale with the
// box, so the cord keeps its 3px and 1px on a narrow cover.
const CORD = "M 0 0 C 10 -30, -10 -60, 3 -90";

function HangingCord() {
  return (
    <svg className="ledger-cover-cord" viewBox="-20 -92 40 94" aria-hidden="true" focusable="false">
      <path d={CORD} fill="none" stroke="#b79d73" strokeWidth="3" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
      <path
        d={CORD}
        transform="translate(1 0)"
        fill="none"
        stroke="rgba(255, 245, 225, 0.35)"
        strokeWidth="1"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

// With no rank the cover stays bare: a ledger that has not been signed into yet shows no seal.
export function LedgerCover({ rank }: { rank?: Rank }) {
  return (
    <div className="ledger-cover-wrap">
      <div className="ledger-cover-book" role="img" aria-label="The Doji ledger, closed">
        <span className="ledger-cover-edge ledger-cover-edge-left" aria-hidden="true" />
        <span className="ledger-cover-edge ledger-cover-edge-bottom" aria-hidden="true" />
        <PaperSheet className="ledger-cover">
          <ThreadBinding ticks />
          <PaperSheet className="ledger-cover-slip">
            <span className="ledger-cover-title" lang="ja">
              大福帳
            </span>
          </PaperSheet>
          <span className="ledger-cover-name">Doji</span>
          {rank !== undefined && (
            <span className="ledger-cover-seal">
              <RankSeal rank={rank} size={96} />
            </span>
          )}
          <HangingCord />
        </PaperSheet>
      </div>
    </div>
  );
}

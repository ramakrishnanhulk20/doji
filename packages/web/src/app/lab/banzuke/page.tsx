import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { Banzuke, type BanzukeRow } from "../../../components/ledger/Banzuke";
import board from "../../../components/ledger/lab-board.json";
import { parseAddress } from "../../../lib/address";

export const metadata: Metadata = {
  title: "Banzuke lab",
  robots: { index: false, follow: false },
};

// lab-board.json is written by scripts/save-lab-board.ts from the live leaderboard, so its fields already have these types.
const SAVED_ROWS = board.rows as BanzukeRow[];
const FULL_BOARD = 50;

const first = (value: string | string[] | undefined) => (Array.isArray(value) ? value[0] : value);

// Dev-only view of a full board: the real rows repeated up to 50 places, so every tier can be judged.
function repeatedTo50(rows: BanzukeRow[]): BanzukeRow[] {
  if (rows.length === 0) return rows;
  return Array.from({ length: FULL_BOARD }, (_, at) => {
    const source = rows[at % rows.length];
    return source ? { ...source, place: at + 1 } : [];
  }).flat();
}

export default async function LabBanzukePage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  // Same guard as the ledger lab. The flags below exist only here and never in the component.
  if (process.env.NODE_ENV === "production") notFound();
  const query = await searchParams;

  // ?fill=1 repeats the rows to 50 places. ?rows=N keeps the first N real rows. ?you=<address> marks one wallet.
  const keep = Number(first(query.rows));
  const real = Number.isInteger(keep) && keep >= 0 ? SAVED_ROWS.slice(0, keep) : SAVED_ROWS;
  const rows = first(query.fill) === "1" ? repeatedTo50(real) : real;
  const you = parseAddress(first(query.you)) ?? undefined;

  return (
    <main style={{ minHeight: "100vh", padding: "72px 24px 140px", background: "var(--ink)", color: "var(--paper)" }}>
      <Banzuke rows={rows} asOf={board.asOf} you={you} />
    </main>
  );
}

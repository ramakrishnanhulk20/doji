"use client";

import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { parseAddress } from "../../lib/address";
import { RANKS, type RankId } from "../../lib/quests/ranks";
import { Banzuke, type BanzukeRow } from "./Banzuke";
import { PaperSheet } from "./PaperSheet";
import "./ledger.css";

const POLL_MS = 60_000;
const STALE_AFTER_SECONDS = 600;
const MAX_ROWS = 50;

const READ_FAILED = "The rankings could not be read right now.";

const AS_OF_FORMAT = new Intl.DateTimeFormat("en-GB", {
  timeZone: "UTC",
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

type Board = { asOf: number; rows: BanzukeRow[] };

const isRankId = (value: unknown): value is RankId => RANKS.some((rank) => rank.id === value);
const isWhole = (value: unknown, least: number): value is number => Number.isSafeInteger(value) && (value as number) >= least;

function checkRow(value: unknown): BanzukeRow | null {
  if (typeof value !== "object" || value === null) return null;
  const { place, address, exp, rank } = value as Record<string, unknown>;
  const wallet = parseAddress(address);
  if (wallet === null || !isRankId(rank) || !isWhole(place, 1) || !isWhole(exp, 0) || place > MAX_ROWS) return null;
  return { place, address: wallet, exp, rank };
}

/** Null unless every row passes. This reply is input to the page, so one bad row fails the whole read (C78). */
function checkBoard(value: unknown): Board | null {
  if (typeof value !== "object" || value === null) return null;
  const { asOf, rows } = value as Record<string, unknown>;
  if (!isWhole(asOf, 1) || !Array.isArray(rows) || rows.length > MAX_ROWS) return null;

  const checked = rows.map(checkRow).filter((row) => row !== null);
  const everyRowPassed = checked.length === rows.length;
  const placesAreUnique = new Set(checked.map((row) => row.place)).size === checked.length;
  return everyRowPassed && placesAreUnique ? { asOf, rows: checked } : null;
}

async function readBoard(): Promise<Board> {
  const reply = await fetch("/api/leaderboard");
  if (!reply.ok) throw new Error("the rankings are unavailable");
  const board = checkBoard(await reply.json());
  if (board === null) throw new Error("the rankings failed their checks");
  return board;
}

function BoardLoading() {
  return (
    <div className="ledger bz">
      <PaperSheet className="banzuke-sheet">
        <header className="bz-head">
          <h2 className="bz-title" lang="ja">
            番付
          </h2>
          <p className="bz-asof">Doji rankings</p>
        </header>
        <div className="bz-rule" aria-hidden="true" />
        <span className="shimmer quest-board-shimmer" aria-hidden="true" />
      </PaperSheet>
    </div>
  );
}

/** The live rankings under the book, or one plain line when they cannot be read. */
export function QuestBoard() {
  const { address } = useAccount();
  const board = useQuery({ queryKey: ["leaderboard"], queryFn: readBoard, refetchInterval: POLL_MS, retry: false });
  const { data } = board;

  return (
    <section id="rankings" className="quest-board">
      {board.isError ? (
        <p className="quest-board-failed">{READ_FAILED}</p>
      ) : data === undefined ? (
        <BoardLoading />
      ) : (
        <>
          <Banzuke rows={data.rows} asOf={data.asOf} you={parseAddress(address) ?? undefined} />
          {board.dataUpdatedAt / 1000 - data.asOf > STALE_AFTER_SECONDS && (
            <p className="quest-board-asof">As of {AS_OF_FORMAT.format(data.asOf * 1000).replace(",", "")} UTC.</p>
          )}
        </>
      )}
    </section>
  );
}

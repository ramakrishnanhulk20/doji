// Osaka merchant ranks, lowest first. A rank depends on EXP alone (C69). 2,500 is every quest a log can prove, so the
// top rank needs them all or a bonus entry.
export const RANKS = [
  { id: "decchi", kanji: "丁稚", exp: 0 },
  { id: "tedai", kanji: "手代", exp: 300 },
  { id: "banto", kanji: "番頭", exp: 800 },
  { id: "nakagai", kanji: "仲買", exp: 1_400 },
  { id: "ryogaesho", kanji: "両替商", exp: 2_000 },
  { id: "sobashi", kanji: "相場師", exp: 2_500 },
] as const;

export type Rank = (typeof RANKS)[number];
export type RankId = Rank["id"];

/** The highest rank this much EXP has reached. */
export function rankOf(exp: number): Rank {
  return RANKS.reduce<Rank>((reached, rank) => (exp >= rank.exp ? rank : reached), RANKS[0]);
}

/** The rank after this much EXP, or null at the top. */
export function nextRank(exp: number): Rank | null {
  return RANKS.find((rank) => rank.exp > exp) ?? null;
}

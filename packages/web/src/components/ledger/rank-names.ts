import type { RankId } from "../../lib/quests/ranks";

// ranks.ts holds the EXP and kanji; the names and what they mean are only for reading, so they live here.
export const RANK_TEXT: Record<RankId, { name: string; meaning: string }> = {
  decchi: { name: "Decchi", meaning: "the apprentice" },
  tedai: { name: "Tedai", meaning: "the clerk" },
  banto: { name: "Banto", meaning: "the head clerk" },
  nakagai: { name: "Nakagai", meaning: "the broker" },
  ryogaesho: { name: "Ryogaesho", meaning: "the money changer" },
  sobashi: { name: "Sobashi", meaning: "the market master" },
};

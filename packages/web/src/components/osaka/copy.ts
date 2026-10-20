export const FOLD_LABEL = "Where futures began";
export const FOLD_TITLE = "Osaka, 1730.";
export const FOLD_KANJI = "堂島";

export const FLAG_LABEL = "The price flag, 1730";

// Where the rooftop flag man stands in the print, as a share of its width and height.
export const FLAG_ANCHOR = { x: 77.6, y: 16 } as const;
// The same point inside panel 4 of 6: (0.776 x 6 - 4) of the panel's width.
export const FLAG_PANEL_ANCHOR = { x: 65.6, y: 16 } as const;

export const FOLD_LEFT = {
  heading: "Rice for a fixed date.",
  body: "Dōjima's traders bought and sold rice to be delivered on a fixed date: the first futures market. Prices crossed Osaka by flag, relayed from rooftop to rooftop.",
} as const;

export const FOLD_RIGHT = {
  heading: "MUSD for a fixed date.",
  body: "Doji runs one market for each Thursday. Lenders set the rate, borrowers lock it in, and the price comes from Mezo's oracle every 60 seconds.",
} as const;

export const FOLD_CLOSE = "The first futures exchange. Now for Bitcoin.";

export const FLAT_SIZES = "min(1200px, 84vw)";

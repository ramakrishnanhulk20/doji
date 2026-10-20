export type HeadlineChoice = 1 | 2 | 3;

export const EYEBROW = "Fixed-rate MUSD loans on Mezo";

// Each headline is two sentences. The hero raises them as two lines, 90ms apart.
export const HEADLINES: Record<HeadlineChoice, readonly [string, string]> = {
  1: ["Keep your Bitcoin locked.", "Borrow MUSD anyway."],
  2: ["Borrow against locked Bitcoin.", "It stays locked."],
  3: ["Your Bitcoin keeps earning.", "Your MUSD arrives today."],
};

export const SUBLINE =
  "Fixed rate, fixed date. Pick a Thursday, see exactly what you will owe, and your veBTC keeps its votes and rewards the whole time.";

export const PRINT_ALT =
  "Dōjima Rice Exchange in Osaka, a woodblock print by Yoshimitsu Sasaki, about 1880: traders crowd the exchange balcony over the river while a man on a rooftop waves the price flag.";

export const CARTOUCHE_LABEL = "Dōji: at the same time";

export const CREDIT_TIPS = [
  "Read live: veBTC.supply() and PriceFeed.fetchPrice() on Mezo mainnet",
  "Read live: the sum of open offers in CreditMarkets on Mezo testnet",
  "Read live: the lowest rate among open offers for the nearest date",
  "Read live: eth_blockNumber every 4 seconds",
] as const;

export const PRINT_SIZES = "calc(100vh * 2.39)";

export const PRINT_SOURCES = {
  avif: "/art/dojima-960.avif 960w, /art/dojima-1600.avif 1600w, /art/dojima-2400.avif 2400w",
  webp: "/art/dojima-960.webp 960w, /art/dojima-1600.webp 1600w, /art/dojima-2400.webp 2400w",
} as const;

export const IMAGE_CREDIT =
  "Dōjima Rice Exchange, Yoshimitsu Sasaki, c. 1880. Osaka Prefectural Nakanoshima Library. Public domain, via Wikimedia Commons.";

export const IMAGE_CREDIT_URL =
  "https://commons.wikimedia.org/wiki/File:Dojima-Rice-Exchange-Osaka-by-Yoshimitsu-Sasaki.png";

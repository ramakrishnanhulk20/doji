import type { Metadata, Viewport } from "next";
import { Fraunces, IBM_Plex_Mono, IBM_Plex_Sans, Shippori_Mincho_B1 } from "next/font/google";
import localFont from "next/font/local";
import "lenis/dist/lenis.css";
import "./globals.css";
import { Providers } from "../components/Providers";

const shippori = Shippori_Mincho_B1({
  weight: ["700", "800"],
  subsets: ["latin"],
  display: "swap",
  variable: "--font-shippori",
});

const fraunces = Fraunces({
  subsets: ["latin"],
  axes: ["opsz", "SOFT", "WONK"],
  display: "swap",
  variable: "--font-fraunces",
});

// latin-ext carries the macron in "Dōjima" for the image credit line.
const plexSans = IBM_Plex_Sans({
  weight: ["400", "500", "600"],
  subsets: ["latin", "latin-ext"],
  display: "swap",
  variable: "--font-plex-sans",
});

const plexMono = IBM_Plex_Mono({
  weight: ["400", "500"],
  subsets: ["latin"],
  display: "swap",
  variable: "--font-plex-mono",
});

// A subset of Shippori Mincho B1 800 holding only the seven kanji of 同時堂島米市場.
const dojiKanji = localFont({
  src: "../fonts/doji-kanji-800.woff2",
  weight: "800",
  style: "normal",
  display: "swap",
  variable: "--font-doji-kanji",
});

export const metadata: Metadata = {
  title: { default: "Doji", template: "%s | Doji" },
  description: "Fixed-rate MUSD loans on Mezo",
  icons: { icon: [{ url: "/favicon.svg", type: "image/svg+xml" }] },
};

export const viewport: Viewport = {
  themeColor: "#0E0C0B",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const fontVariables = [shippori, fraunces, plexSans, plexMono, dojiKanji].map((font) => font.variable).join(" ");

  return (
    <html lang="en" className={fontVariables}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}

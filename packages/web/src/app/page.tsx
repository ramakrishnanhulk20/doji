import type { Metadata } from "next";
import { ClosingCall } from "../components/close/ClosingCall";
import { Footer } from "../components/Footer";
import { Hero } from "../components/hero/Hero";
import { PRINT_SIZES, PRINT_SOURCES } from "../components/hero/copy";
import { HowItWorks } from "../components/how/HowItWorks";
import "../components/landing/landing.css";
import { NameBand } from "../components/name/NameBand";
import { FoldingScreen } from "../components/osaka/FoldingScreen";
import { ProofGrid } from "../components/proof/ProofGrid";
import { AuctionChart } from "../components/risk/AuctionChart";
import { StampMoment } from "../components/stamp/StampMoment";

export const metadata: Metadata = {
  title: { absolute: "Doji: borrow MUSD against locked Bitcoin" },
  description:
    "Fixed-rate MUSD loans against veBTC on Mezo. Your Bitcoin stays locked, keeps its votes and earns its rewards while you borrow.",
};

// Fraunces only, headline 1, and motion follows the visitor's system setting.
export default function Home() {
  return (
    <div data-type="b">
      <link
        rel="preload"
        as="image"
        href="/art/dojima-1600.avif"
        imageSrcSet={PRINT_SOURCES.avif}
        imageSizes={PRINT_SIZES}
        type="image/avif"
        fetchPriority="high"
      />
      <main>
        <Hero type="b" headline={1} motion="full" />
        <StampMoment motion="full" />
        <NameBand />
        <FoldingScreen motion="full" />
        <HowItWorks />
        <AuctionChart />
        <ProofGrid />
        <ClosingCall />
      </main>
      <Footer />
    </div>
  );
}

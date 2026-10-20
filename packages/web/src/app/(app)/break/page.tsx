import type { Metadata } from "next";
import { BreakScreen } from "../../../components/break/BreakScreen";

export const metadata: Metadata = {
  title: "Try to break it",
  description:
    "Run twelve attacks against the live Doji contracts on Mezo testnet. Each one is a simulation, and you see how the contract refuses it.",
};

export default function BreakPage() {
  return <BreakScreen />;
}

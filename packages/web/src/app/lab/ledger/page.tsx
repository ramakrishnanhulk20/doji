import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { LabLedger } from "../../../components/ledger/LabLedger";

export const metadata: Metadata = {
  title: "Ledger lab",
  robots: { index: false, follow: false },
};

export default function LabLedgerPage() {
  // Same guard as the main lab: the ledger materials are tried here first and never shown to visitors.
  if (process.env.NODE_ENV === "production") notFound();
  return <LabLedger />;
}

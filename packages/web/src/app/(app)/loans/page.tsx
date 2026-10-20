import type { Metadata } from "next";
import { MyLoans } from "../../../components/loans/MyLoans";

export const metadata: Metadata = {
  title: "My loans",
  description:
    "Everything Doji holds for your wallet: what you owe, by when, how safe each loan is, and the votes and rewards that stay yours.",
};

export default function LoansPage() {
  return <MyLoans />;
}

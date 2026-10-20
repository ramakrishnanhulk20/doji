import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { LoanPage } from "../../../../components/loans/LoanPage";

type LoanRouteProps = { params: Promise<{ id: string }> };

// A veBTC token id is a whole number. Anything else is not a loan.
const isTokenId = (id: string) => /^[0-9]{1,30}$/.test(id);

export async function generateMetadata({ params }: LoanRouteProps): Promise<Metadata> {
  const { id } = await params;
  return {
    title: isTokenId(id) ? `Loan on veBTC #${BigInt(id)}` : "Loan not found",
    description: "The state of one Doji loan: what is owed, the collateral, the limits, and the auction if there is one.",
  };
}

export default async function LoanRoute({ params }: LoanRouteProps) {
  const { id } = await params;
  if (!isTokenId(id)) notFound();
  return <LoanPage id={id} />;
}

import type { Metadata } from "next";
import { LendScreen } from "../../../components/lend/LendScreen";

export const metadata: Metadata = {
  title: "Lend MUSD",
  description:
    "Post a fixed-rate MUSD offer for a Thursday, cancel what is not taken, and manage your credit units until you are paid back.",
};

type LendPageProps = {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
};

export default async function LendPage({ searchParams }: LendPageProps) {
  const { date } = await searchParams;
  const text = Array.isArray(date) ? date[0] : date;
  // The landing page's "Be the first lender" link carries the Thursday as a unix time. The screen checks it against the open dates.
  const initialDate = text !== undefined && /^\d{1,12}$/.test(text) ? Number(text) : null;
  return <LendScreen initialDate={initialDate} />;
}

import type { Metadata } from "next";
import { BorrowScreen } from "../../../components/borrow/BorrowScreen";

export const metadata: Metadata = {
  title: "Borrow MUSD",
  description:
    "Lock Bitcoin, or use a veBTC position you already have, and borrow MUSD at a fixed rate until a Thursday you choose.",
};

export default function BorrowPage() {
  return <BorrowScreen />;
}

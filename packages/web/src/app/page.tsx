import { redirect } from "next/navigation";

// The landing page does not exist yet, so the root sends visitors to the lab.
export default function Home() {
  redirect("/lab");
}

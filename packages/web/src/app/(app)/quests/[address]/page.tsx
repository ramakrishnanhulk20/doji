import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { WalletLedger } from "../../../../components/ledger/WalletLedger";
import { parseAddress } from "../../../../lib/address";

// Constants, so a forged Host header cannot end up in a shared link (C77).
const SITE_ORIGIN = new URL("https://www.dojis.site");
const DESCRIPTION = "A wallet's seals and rank in Doji's quest ledger.";

type WalletPageProps = { params: Promise<{ address: string }> };

/** Everything here is computed from the parsed address, so no text from the URL reaches a shared card (C77). */
export async function generateMetadata({ params }: WalletPageProps): Promise<Metadata> {
  const { address: raw } = await params;
  const address = parseAddress(raw);
  if (address === null) notFound();

  const title = `${address.slice(0, 6)}...${address.slice(-4)} on the Doji ledger`;
  const path = `/quests/${address}`;
  return {
    metadataBase: SITE_ORIGIN,
    title: { absolute: title },
    description: DESCRIPTION,
    alternates: { canonical: path },
    openGraph: { type: "website", url: path, title, description: DESCRIPTION },
    twitter: { card: "summary_large_image", title, description: DESCRIPTION },
  };
}

/** A wallet's public ledger. An address has one URL: other spellings redirect to it and anything else is a 404 (C73). */
export default async function WalletPage({ params }: WalletPageProps) {
  const { address: raw } = await params;
  const address = parseAddress(raw);
  if (address === null) notFound();
  if (raw !== address) redirect(`/quests/${address}`);
  return <WalletLedger address={address} />;
}

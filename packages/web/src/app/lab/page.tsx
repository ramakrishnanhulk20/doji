import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { PRINT_SIZES, PRINT_SOURCES } from "../../components/hero/copy";
import { LabShell } from "../../components/lab/LabShell";
import { parseLabState } from "../../lib/lab-state";

export const metadata: Metadata = {
  title: "Lab",
  robots: { index: false, follow: false },
};

export default async function LabPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  // The lab is where design choices were tried before they reached the real pages; visitors never need it.
  if (process.env.NODE_ENV === "production") notFound();
  const initial = parseLabState(await searchParams);

  return (
    <>
      <link
        rel="preload"
        as="image"
        href="/art/dojima-1600.avif"
        imageSrcSet={PRINT_SOURCES.avif}
        imageSizes={PRINT_SIZES}
        type="image/avif"
        fetchPriority="high"
      />
      <LabShell initial={initial} />
    </>
  );
}

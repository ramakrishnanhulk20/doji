import type { ReactNode } from "react";
import Link from "next/link";
import { DocsLayout } from "fumadocs-ui/layouts/docs";
import { RootProvider } from "fumadocs-ui/provider/next";
import { Seal } from "../../../components/Seal";
import { DocsNativeScroll } from "../../../components/docs/DocsNativeScroll";
import "../../../components/docs/docs.css";
import { source } from "../../../lib/docs-source";

export default function DocsRootLayout({ children }: { children: ReactNode }) {
  return (
    <RootProvider theme={{ enabled: false }} search={{ options: { api: "/docs/search" } }}>
      <DocsNativeScroll />
      <DocsLayout
        tree={source.getPageTree()}
        tabs={false}
        themeSwitch={{ enabled: false }}
        nav={{
          url: "/docs",
          title: (
            <>
              <Seal size={24} title="" />
              <span className="docs-brand-name display-face">Doji docs</span>
            </>
          ),
        }}
        sidebar={{
          defaultOpenLevel: 1,
          banner: (
            <Link href="/" className="docs-back-link">
              Back to the app
            </Link>
          ),
        }}
        searchToggle={{ full: { className: "docs-search-full" } }}
      >
        {children}
      </DocsLayout>
    </RootProvider>
  );
}

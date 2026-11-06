import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

// C78: any script on a framed page could ask a connected wallet to sign, and every page of ours can ask for a signature,
// so no other site may frame any of them.
const NEVER_FRAMED = [
  { key: "Content-Security-Policy", value: "frame-ancestors 'none'" },
  { key: "X-Frame-Options", value: "DENY" },
];

const nextConfig: NextConfig = {
  // A verification build sets NEXT_DIST_DIR so it never overwrites the folder the dev server is using.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  reactStrictMode: true,
  devIndicators: false,
  // The proof page used to live under /docs/business; old links still land on it.
  async redirects() {
    return [{ source: "/docs/business/judging-criteria", destination: "/docs/proof", permanent: true }];
  },
  async headers() {
    return [{ source: "/:path*", headers: NEVER_FRAMED }];
  },
};

export default withMDX(nextConfig);

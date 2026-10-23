import type { NextConfig } from "next";
import { createMDX } from "fumadocs-mdx/next";

const withMDX = createMDX();

const nextConfig: NextConfig = {
  // A verification build sets NEXT_DIST_DIR so it never overwrites the folder the dev server is using.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  reactStrictMode: true,
  devIndicators: false,
  // The proof page used to live under /docs/business; old links still land on it.
  async redirects() {
    return [{ source: "/docs/business/judging-criteria", destination: "/docs/proof", permanent: true }];
  },
};

export default withMDX(nextConfig);

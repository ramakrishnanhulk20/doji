import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // A verification build sets NEXT_DIST_DIR so it never overwrites the folder the dev server is using.
  distDir: process.env.NEXT_DIST_DIR || ".next",
  reactStrictMode: true,
  devIndicators: false,
};

export default nextConfig;

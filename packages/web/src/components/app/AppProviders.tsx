"use client";

import type { ReactNode } from "react";
import { WagmiProvider } from "wagmi";
import { wagmiConfig } from "../../lib/wagmi";

/** The wallet layer for the app screens only. The landing page and the lab never load it. */
export function AppProviders({ children }: { children: ReactNode }) {
  return <WagmiProvider config={wagmiConfig}>{children}</WagmiProvider>;
}

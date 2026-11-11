"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { parseUnits } from "viem";
import { useAccount, useBalance } from "wagmi";
import { APP_CHAIN_ID } from "../../lib/wagmi";

const LOW_BALANCE = parseUnits("0.0005", 18);

/** Shown under the top bar when a connected wallet on Mezo testnet is nearly out of test BTC. */
export function BtcStrip() {
  const pathname = usePathname();
  const { address, chainId, isConnected } = useAccount();
  const balance = useBalance({ address, chainId: APP_CHAIN_ID, query: { enabled: isConnected && chainId === APP_CHAIN_ID } });

  // The Quests page is where the starter kit is claimed, so the strip would only repeat what the page already says.
  if (pathname === "/quests" || !isConnected || chainId !== APP_CHAIN_ID || balance.data === undefined || balance.data.value >= LOW_BALANCE) {
    return null;
  }

  return (
    <div className="btc-strip">
      You need a little test BTC for gas.{" "}
      <Link className="link-draw link-cue" href="/quests">
        Claim a free starter kit
      </Link>
    </div>
  );
}

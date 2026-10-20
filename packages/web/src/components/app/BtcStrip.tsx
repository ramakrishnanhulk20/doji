"use client";

import { parseUnits } from "viem";
import { useAccount, useBalance } from "wagmi";
import { APP_CHAIN_ID } from "../../lib/wagmi";

const LOW_BALANCE = parseUnits("0.0005", 18);

/** Shown under the top bar when a connected wallet on Mezo testnet is nearly out of test BTC. */
export function BtcStrip() {
  const { address, chainId, isConnected } = useAccount();
  const balance = useBalance({ address, chainId: APP_CHAIN_ID, query: { enabled: isConnected && chainId === APP_CHAIN_ID } });

  if (!isConnected || chainId !== APP_CHAIN_ID || balance.data === undefined || balance.data.value >= LOW_BALANCE) {
    return null;
  }

  return (
    <div className="btc-strip">
      You need a little test BTC for gas and to lock. Get some from the{" "}
      <a className="link-draw" href="https://faucet.test.mezo.org" target="_blank" rel="noopener noreferrer">
        Mezo faucet
      </a>
      .
    </div>
  );
}

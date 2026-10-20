"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { openConnectModal } from "../components/app/connect-modal-store";
import { APP_CHAIN_ID } from "../lib/wagmi";

/** What a button needs to know before it can send: is a wallet connected, and is it on Mezo testnet. */
export function useLoanGate() {
  const { address, chainId, isConnected } = useAccount();
  const { switchChain } = useSwitchChain();
  const wrongChain = isConnected && chainId !== APP_CHAIN_ID;

  return {
    address,
    isConnected,
    wrongChain,
    ready: isConnected && !wrongChain && address !== undefined,
    connect: openConnectModal,
    switchNetwork: () => switchChain({ chainId: APP_CHAIN_ID }),
  };
}

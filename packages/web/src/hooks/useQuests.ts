"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { parseAddress } from "../lib/address";
import type { WalletProgress } from "../lib/quests/exp";
import { readWalletProgress } from "../lib/quests/read-wallet";

const POLL_MS = 20_000;

/** A wallet's quests from chain logs, refreshed every 20 seconds. Undefined until the first read lands or for a non-address. */
export function useQuests(address: string | undefined): WalletProgress | undefined {
  const wallet = parseAddress(address);
  const quests = useQuery({
    queryKey: ["quests", wallet],
    queryFn: () => readWalletProgress(wallet as Address),
    enabled: wallet !== null,
    refetchInterval: POLL_MS,
    retry: false,
  });
  return quests.data;
}

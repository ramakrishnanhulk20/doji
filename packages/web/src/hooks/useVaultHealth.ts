"use client";

import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { readParking } from "../lib/lend";
import { APP_CHAIN_ID } from "../lib/wagmi";

export type VaultHealth = {
  /** Mezo's sMUSD vault would refuse to hand back Doji's parked principal right now. */
  down: boolean;
  /** False until a read has answered, and again whenever the latest read failed. */
  known: boolean;
};

/**
 * The keeper's vault check (C35), run from the browser for the C52 rule. Only a real revert reads as down: a read
 * that fails any other way leaves every offer in place, because an RPC hiccup must never hide MUSD a borrower could take.
 */
export function useVaultHealth(): VaultHealth {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const parking = useQuery({
    queryKey: ["vault-health"],
    queryFn: () => readParking(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: 30_000,
    retry: false,
  });

  if (parking.isError || parking.data === undefined) return { down: false, known: false };
  return { down: parking.data.vault === "down", known: true };
}

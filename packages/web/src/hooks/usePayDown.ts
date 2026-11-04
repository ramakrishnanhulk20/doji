"use client";

import { useCallback } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { Address, PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { quoteHarvest, readHarvests, readPayDownState } from "../lib/paydown";
import { APP_CHAIN_ID } from "../lib/wagmi";

const STATE_POLL_MS = 15_000;
const QUOTE_POLL_MS = 30_000;
const ZERO: Address = "0x0000000000000000000000000000000000000000";

/**
 * What the pay-down card reads about one position: whether the borrower turned it on, every harvest so far, and what a
 * harvest would repay now. The estimate is only asked for while pay-down is on and the loan is open, since a harvest
 * of a closed loan repays nothing. It is asked from the connected wallet, or from the zero address when none is.
 */
export function usePayDown(tokenId: bigint, enabled: boolean, loanOpen: boolean) {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address } = useAccount();
  const queryClient = useQueryClient();
  const id = tokenId.toString();
  const account = address ?? ZERO;
  const ready = enabled && client !== undefined;

  const state = useQuery({
    queryKey: ["paydown", "state", id],
    queryFn: () => readPayDownState(client as PublicClient, tokenId),
    enabled: ready,
    refetchInterval: STATE_POLL_MS,
    retry: false,
  });

  const harvests = useQuery({
    queryKey: ["paydown", "harvests", id],
    queryFn: () => readHarvests(client as PublicClient, tokenId),
    enabled: ready,
    refetchInterval: STATE_POLL_MS,
    retry: false,
  });

  const quote = useQuery({
    queryKey: ["paydown", "quote", id, account],
    queryFn: () => quoteHarvest(client as PublicClient, tokenId, account),
    enabled: ready && state.data?.isPayDown === true && loanOpen,
    refetchInterval: QUOTE_POLL_MS,
    retry: false,
  });

  /** Asks again for all three and for the loan itself, after a write of the card succeeded. */
  const refresh = useCallback(async () => {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["paydown", "state", id] }),
      queryClient.invalidateQueries({ queryKey: ["paydown", "harvests", id] }),
      queryClient.invalidateQueries({ queryKey: ["paydown", "quote", id] }),
      queryClient.invalidateQueries({ queryKey: ["loan-view", id] }),
    ]);
  }, [id, queryClient]);

  return { state, harvests, quote, refresh };
}

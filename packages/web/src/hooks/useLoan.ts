"use client";

import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { readLoanPair, readMarket, readMusdWallet, readOpened, readPositionViews, STATE_NONE } from "../lib/loans";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;

/**
 * Everything the public loan page reads about one position. No wallet is needed; a connected one adds its MUSD. The
 * position is read from the LoanManager that holds it now; one that neither holds reads as not in Doji, from Wave 2.
 */
export function useLoan(id: bigint) {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address } = useAccount();
  const key = id.toString();

  const view = useQuery({
    queryKey: ["loan-view", key],
    queryFn: async () => {
      const pair = await readLoanPair(client as PublicClient, id);
      return (await readPositionViews(client as PublicClient, [{ id, pair: pair?.key ?? "wave2" }]))[0] ?? null;
    },
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const opened = useQuery({
    queryKey: ["loan-opened", key],
    queryFn: () => readOpened(id),
    staleTime: 60_000,
    refetchInterval: (query) => (query.state.status === "error" ? POLL_MS : false),
    retry: false,
  });

  const pair = view.data?.pair;
  const maturity = view.data && view.data.loan.state !== STATE_NONE ? view.data.loan.maturity : null;
  const market = useQuery({
    queryKey: ["loan-market", pair, maturity],
    queryFn: () => readMarket(client as PublicClient, maturity as number, pair as NonNullable<typeof pair>),
    enabled: client !== undefined && maturity !== null && pair !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const musd = useQuery({
    queryKey: ["loan-musd", address, pair],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`, pair),
    enabled: client !== undefined && address !== undefined && pair !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  return { view, opened, market, musd };
}

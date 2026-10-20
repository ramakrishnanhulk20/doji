"use client";

import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { readMarket, readMusdWallet, readOpened, readPositionViews, STATE_NONE } from "../lib/loans";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;

/** Everything the public loan page reads about one position. No wallet is needed; a connected one adds its MUSD. */
export function useLoan(id: bigint) {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address } = useAccount();
  const key = id.toString();

  const view = useQuery({
    queryKey: ["loan-view", key],
    queryFn: async () => (await readPositionViews(client as PublicClient, [id]))[0] ?? null,
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

  const maturity = view.data && view.data.loan.state !== STATE_NONE ? view.data.loan.maturity : null;
  const market = useQuery({
    queryKey: ["loan-market", maturity],
    queryFn: () => readMarket(client as PublicClient, maturity as number),
    enabled: client !== undefined && maturity !== null,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const musd = useQuery({
    queryKey: ["loan-musd", address],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`),
    enabled: client !== undefined && address !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  return { view, opened, market, musd };
}

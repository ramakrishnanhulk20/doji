"use client";

import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { readBorrowSettings } from "../lib/borrow-reads";
import { readClaimables, readMusdWallet, readPositionViews, readWalletPositionIds } from "../lib/loans";
import { scanOpenOffers } from "../lib/stats";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;
// Finding the ids reads the explorer's logs, so it runs less often than the reads of the loans themselves.
const IDS_POLL_MS = 60_000;

/** Everything the My loans screen reads. The reads need only the wallet's address, not its network. */
export function useMyLoans() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address } = useAccount();
  const enabled = client !== undefined && address !== undefined;

  const ids = useQuery({
    queryKey: ["loan-ids", address],
    queryFn: () => readWalletPositionIds(client as PublicClient, address as `0x${string}`),
    enabled,
    refetchInterval: IDS_POLL_MS,
    retry: false,
  });

  const idKey = ids.data?.map(String).join(",");
  const views = useQuery({
    queryKey: ["loan-views", address, idKey],
    queryFn: () => readPositionViews(client as PublicClient, ids.data ?? []),
    enabled: enabled && ids.data !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const claimables = useQuery({
    queryKey: ["loan-claimables", address],
    queryFn: () => readClaimables(client as PublicClient, address as `0x${string}`),
    enabled,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const musd = useQuery({
    queryKey: ["loan-musd", address],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`),
    enabled,
    refetchInterval: POLL_MS,
    retry: false,
  });

  // Same keys as the Borrow screen, so the two screens share one read of the limits and the offers.
  const settings = useQuery({
    queryKey: ["borrow-settings"],
    queryFn: () => readBorrowSettings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const offers = useQuery({
    queryKey: ["open-offers"],
    queryFn: scanOpenOffers,
    refetchInterval: POLL_MS,
    retry: false,
  });

  return { client, address, ids, views, claimables, musd, settings, offers };
}

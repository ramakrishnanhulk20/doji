"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address, PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { readListings, readMarketSettings, readUnitWallet } from "../lib/units";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;

/**
 * What the units market shows. Both reads work before a wallet connects. useWrite refreshes every query after a
 * confirmed or reverted transaction, so the listings and the Lend data come back together without a separate call here.
 */
export function useUnitMarket() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;

  const listings = useQuery({
    queryKey: ["units", "listings"],
    queryFn: () => readListings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const settings = useQuery({
    queryKey: ["units", "settings"],
    queryFn: () => readMarketSettings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  return { listings, settings };
}

/** The buyer's MUSD balance and what UnitMarket may pull, read only while a buy sheet is open. */
export function useUnitWallet(address: Address | undefined) {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;

  return useQuery({
    queryKey: ["units", "wallet", address],
    queryFn: () => readUnitWallet(client as PublicClient, address as Address),
    enabled: client !== undefined && address !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

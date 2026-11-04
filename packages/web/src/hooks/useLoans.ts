"use client";

import { useCallback } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import type { PairKey } from "../lib/addresses";
import { readBorrowSettings } from "../lib/borrow-reads";
import { readClaimables, readMusdWallet, readPositionViews, readWalletPositionIds } from "../lib/loans";
import { scanOpenOffers, scanPairOffers, usableOffers, type OpenOffer } from "../lib/stats";
import { APP_CHAIN_ID } from "../lib/wagmi";
import { useVaultHealth } from "./useVaultHealth";

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

  const idKey = ids.data?.map((ref) => `${ref.pair}:${ref.id}`).join(",");
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
    queryKey: ["loan-musd", address, "wave2"],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`, "wave2"),
    enabled,
    refetchInterval: POLL_MS,
    retry: false,
  });

  // Same keys as the Borrow screen, so the two screens share one read of the limits, the offers and the vault.
  const settings = useQuery({
    queryKey: ["borrow-settings"],
    queryFn: () => readBorrowSettings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const vault = useVaultHealth();
  // C52 runs in select, before a roll's dates, selection or quote see an offer. The 20 October pair is filtered the
  // same way, and stays whole, because none of its offers is parked.
  const keepUsable = useCallback((list: OpenOffer[]) => usableOffers(list, vault.down), [vault.down]);

  const offers = useQuery({
    queryKey: ["open-offers"],
    queryFn: () => scanOpenOffers(),
    select: keepUsable,
    refetchInterval: POLL_MS,
    retry: false,
  });

  // A 20 October loan repays, rolls and claims on its own pair, so that pair's allowance, limits and offers are read
  // too, but only while the wallet has a position there.
  const hasLegacy = views.data?.some((view) => view.pair === "legacy") ?? false;

  const legacyMusd = useQuery({
    queryKey: ["loan-musd", address, "legacy"],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`, "legacy"),
    enabled: enabled && hasLegacy,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const legacySettings = useQuery({
    queryKey: ["borrow-settings", "legacy"],
    queryFn: () => readBorrowSettings(client as PublicClient, "legacy"),
    enabled: client !== undefined && hasLegacy,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const legacyOffers = useQuery({
    queryKey: ["open-offers", "legacy"],
    queryFn: () => scanPairOffers("legacy"),
    select: keepUsable,
    enabled: hasLegacy,
    refetchInterval: POLL_MS,
    retry: false,
  });

  /** The wallet, limits and offers a repay or roll on `pair` works with. */
  const forPair = (pair: PairKey) =>
    pair === "wave2"
      ? { wallet: musd.data, settings: settings.data, offers: offers.data }
      : { wallet: legacyMusd.data, settings: legacySettings.data, offers: legacyOffers.data };

  return { client, address, ids, views, claimables, musd, settings, offers, vault, forPair };
}

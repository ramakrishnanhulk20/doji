"use client";

import { useCallback } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, useBalance, usePublicClient } from "wagmi";
import { readBorrowSettings, readBtcAllowance, readPositions, readPrice, type Position } from "../lib/borrow-reads";
import { STATE_NONE, readPositionViews, readWalletPositionIds } from "../lib/loans";
import { scanOpenOffers, usableOffers, type OpenOffer } from "../lib/stats";
import { APP_CHAIN_ID } from "../lib/wagmi";
import { useVaultHealth } from "./useVaultHealth";

const POLL_MS = 15_000;

/** Everything the Borrow screen reads. The offers, the price and the limits load before a wallet connects. */
export function useBorrowData() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address, chainId, isConnected } = useAccount();
  const walletReady = isConnected && chainId === APP_CHAIN_ID && address !== undefined;
  const vault = useVaultHealth();

  // C52 runs in select, before the dates, Max, the selection or the quote see an offer. A select is per screen, so the
  // Break page, which shares this cache key, still reads every offer.
  const keepUsable = useCallback((list: OpenOffer[]) => usableOffers(list, vault.down), [vault.down]);
  const offers = useQuery({
    queryKey: ["open-offers"],
    queryFn: scanOpenOffers,
    select: keepUsable,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const settings = useQuery({
    queryKey: ["borrow-settings"],
    queryFn: () => readBorrowSettings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const price = useQuery({
    queryKey: ["oracle-price"],
    queryFn: () => readPrice(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const balance = useBalance({
    address,
    chainId: APP_CHAIN_ID,
    query: { enabled: walletReady, refetchInterval: POLL_MS },
  });

  const allowance = useQuery({
    queryKey: ["btc-allowance", address],
    queryFn: () => readBtcAllowance(client as PublicClient, address as `0x${string}`),
    enabled: client !== undefined && walletReady,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const positions = useQuery({
    queryKey: ["veBTC-positions", address, price.data?.toString()],
    queryFn: () => readPositions(client as PublicClient, address as `0x${string}`, price.data as bigint),
    enabled: client !== undefined && walletReady && price.data !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  // Positions the wallet already put into Doji that carry no loan: they can borrow again with no approval or deposit.
  // Only Wave 2 holds count, because a new loan opens on Wave 2; one held by the 20 October LoanManager is withdrawn
  // from My loans first.
  const held = useQuery({
    queryKey: ["doji-held-positions", address, price.data?.toString()],
    queryFn: async (): Promise<Position[]> => {
      const refs = await readWalletPositionIds(client as PublicClient, address as `0x${string}`);
      const views = await readPositionViews(
        client as PublicClient,
        refs.filter((ref) => ref.pair === "wave2"),
      );
      return views
        .filter((view) => view.loan.state === STATE_NONE && view.lock !== null)
        .map((view) => {
          const lock = view.lock as NonNullable<typeof view.lock>;
          return {
            id: view.id,
            amount: lock.amount,
            end: lock.end,
            isPermanent: lock.isPermanent,
            accepted: true,
            approved: true,
            inDoji: true,
            rewardOperator: view.rewardOperator,
            value: view.value ?? (lock.amount * (price.data as bigint)) / 10n ** 18n,
          };
        });
    },
    enabled: client !== undefined && walletReady && price.data !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  // The wallet's own positions first, then the ones Doji holds.
  const walletList = positions.data;
  const heldList = held.data;
  const merged = walletList === undefined ? undefined : [...walletList, ...(heldList ?? [])];

  return {
    client,
    address,
    walletReady,
    isConnected,
    chainId,
    vault,
    offers,
    settings,
    price,
    balance,
    allowance,
    positions: { data: merged, isLoading: positions.isLoading || held.isLoading, isError: positions.isError },
  };
}

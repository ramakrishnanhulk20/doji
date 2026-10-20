"use client";

import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, useBalance, usePublicClient } from "wagmi";
import { readBorrowSettings, readBtcAllowance, readPositions, readPrice } from "../lib/borrow-reads";
import { scanOpenOffers } from "../lib/stats";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;

/** Everything the Borrow screen reads. The offers, the price and the limits load before a wallet connects. */
export function useBorrowData() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address, chainId, isConnected } = useAccount();
  const walletReady = isConnected && chainId === APP_CHAIN_ID && address !== undefined;

  const offers = useQuery({
    queryKey: ["open-offers"],
    queryFn: scanOpenOffers,
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

  return { client, address, walletReady, isConnected, chainId, offers, settings, price, balance, allowance, positions };
}

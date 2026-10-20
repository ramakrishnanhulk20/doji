"use client";

import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { useAccount, usePublicClient } from "wagmi";
import { readCreditUnits, readLendSettings, readMusdWallet, readMyOffers } from "../lib/lend";
import { readThursdayBoard } from "../lib/stats";
import { APP_CHAIN_ID } from "../lib/wagmi";

const POLL_MS = 15_000;
const CLOCK_MS = 30_000;

const nowSeconds = () => Math.floor(Date.now() / 1000);

/** The clock the screen compares dates against, refreshed every 30 seconds. */
export function useLendNow(): number {
  const [now, setNow] = useState(nowSeconds);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(nowSeconds()), CLOCK_MS);
    return () => window.clearInterval(timer);
  }, []);
  return now;
}

/** Everything the Lend screen reads. The dates, rates and limits load before a wallet connects. */
export function useLendData() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const { address, chainId, isConnected } = useAccount();
  const walletReady = isConnected && chainId === APP_CHAIN_ID && address !== undefined;

  const settings = useQuery({
    queryKey: ["lend-settings"],
    queryFn: () => readLendSettings(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const dates = useQuery({
    queryKey: ["lend-dates"],
    queryFn: () => readThursdayBoard(nowSeconds()),
    refetchInterval: POLL_MS,
    retry: false,
  });

  const musd = useQuery({
    queryKey: ["musd-wallet", address],
    queryFn: () => readMusdWallet(client as PublicClient, address as `0x${string}`),
    enabled: client !== undefined && walletReady,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const offers = useQuery({
    queryKey: ["my-offers", address],
    queryFn: () => readMyOffers(client as PublicClient, address as `0x${string}`),
    enabled: client !== undefined && walletReady,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const maxTermSeconds = settings.data?.maxTermSeconds;
  const units = useQuery({
    queryKey: ["my-units", address, maxTermSeconds],
    queryFn: () => readCreditUnits(client as PublicClient, address as `0x${string}`, nowSeconds(), maxTermSeconds as number),
    enabled: client !== undefined && walletReady && maxTermSeconds !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });

  return { client, address, walletReady, isConnected, chainId, settings, dates, musd, offers, units };
}

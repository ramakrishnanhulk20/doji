"use client";

import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { useOpenAuctions } from "../../hooks/useChainReads";
import { buildTargets, readChainTargets } from "../../lib/attacks";
import { scanOpenOffers, type OpenAuction } from "../../lib/stats";
import { APP_CHAIN_ID } from "../../lib/wagmi";

const POLL_MS = 15_000;
const CLOCK_MS = 30_000;

const NO_AUCTIONS: readonly OpenAuction[] = [];

const nowSeconds = () => Math.floor(Date.now() / 1000);

function useNow(): number {
  const [now, setNow] = useState(nowSeconds);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(nowSeconds()), CLOCK_MS);
    return () => window.clearInterval(timer);
  }, []);
  return now;
}

/**
 * What the twelve attacks point at, read live. The offers and the auction search use the same queries as the rest of
 * the app, so a visitor who came from the landing page or Borrow already has them cached.
 */
export function useAttackTargets() {
  const client = usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;
  const now = useNow();

  const offers = useQuery({
    queryKey: ["open-offers"],
    queryFn: scanOpenOffers,
    refetchInterval: POLL_MS,
    retry: false,
  });
  const chain = useQuery({
    queryKey: ["break-chain-targets"],
    queryFn: () => readChainTargets(client as PublicClient),
    enabled: client !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });
  const auctions = useOpenAuctions();

  // The explorer that lists loans can fail on its own. Without it the buy attack falls back to the demo loan.
  const auctionList = auctions.isError ? NO_AUCTIONS : (auctions.data ?? null);

  const targets = useMemo(
    () =>
      offers.data && chain.data
        ? buildTargets({ offers: offers.data, auctions: auctionList, chain: chain.data, now })
        : null,
    [offers.data, chain.data, auctionList, now],
  );

  const failed = (offers.isError && offers.data === undefined) || (chain.isError && chain.data === undefined);

  const retry = () => {
    void offers.refetch();
    void chain.refetch();
  };

  return { client, targets, failed, retry };
}

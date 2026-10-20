"use client";

import { useQuery } from "@tanstack/react-query";
import { readBlock, readMezoLocked, readOffers } from "../lib/stats";

const SLOW_POLL_MS = 15_000;
const BLOCK_POLL_MS = 4_000;

export function useLiveStats() {
  const locked = useQuery({
    queryKey: ["mezo-locked"],
    queryFn: readMezoLocked,
    refetchInterval: SLOW_POLL_MS,
    retry: false,
  });

  const offers = useQuery({
    queryKey: ["credit-offers"],
    queryFn: readOffers,
    refetchInterval: SLOW_POLL_MS,
    retry: false,
  });

  // A failed block read falls back to the slow interval, like every other read.
  const block = useQuery({
    queryKey: ["block"],
    queryFn: readBlock,
    refetchInterval: (query) => (query.state.status === "error" ? SLOW_POLL_MS : BLOCK_POLL_MS),
    retry: false,
  });

  return { locked, offers, block };
}

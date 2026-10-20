"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { readOpenAuctions, readRiskSettings, readThursdayBoard, readVerified } from "../lib/stats";

const POLL_MS = 15_000;
// The explorer answers a verification check with the contract's whole source, around 150 to 400 KB, and the answer
// changes once in a contract's life, so it is checked far less often than the chain reads.
const VERIFIED_POLL_MS = 300_000;

export function useThursdayBoard() {
  return useQuery({
    queryKey: ["thursday-board"],
    queryFn: () => readThursdayBoard(Math.floor(Date.now() / 1000)),
    refetchInterval: POLL_MS,
    retry: false,
  });
}

export function useRiskSettings() {
  return useQuery({
    queryKey: ["risk-settings"],
    queryFn: readRiskSettings,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

export function useOpenAuctions() {
  return useQuery({
    queryKey: ["open-auctions"],
    queryFn: readOpenAuctions,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

export function useVerified(address: Address) {
  return useQuery({
    queryKey: ["verified", address],
    queryFn: () => readVerified(address),
    refetchInterval: (query) => (query.state.status === "error" ? POLL_MS : VERIFIED_POLL_MS),
    retry: false,
  });
}

"use client";

import { useQuery } from "@tanstack/react-query";
import { readDemoLoanPrincipal, readDemoLoanState } from "../lib/stats";

const POLL_MS = 15_000;

// The lock, vote and reward reads are cheap, so they load first. The principal waits on a receipt that some
// nodes answer late, and never changes once read, so it has its own query.
export function useDemoLoan() {
  const state = useQuery({
    queryKey: ["demo-loan-state"],
    queryFn: readDemoLoanState,
    refetchInterval: POLL_MS,
    retry: false,
  });

  const principal = useQuery({
    queryKey: ["demo-loan-principal"],
    queryFn: readDemoLoanPrincipal,
    staleTime: Infinity,
    refetchInterval: (query) => (query.state.status === "error" ? POLL_MS : false),
    retry: false,
  });

  return { state, principal };
}

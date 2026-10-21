"use client";

import { useCallback, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { PublicClient } from "viem";
import { usePublicClient } from "wagmi";
import { showToast } from "../components/app/toast-store";
import {
  buildClaimRebaseCall,
  buildClaimRewardsArgs,
  buildClaimRewardsCall,
  buildResetCall,
  forwardedLine,
  parseForwarded,
  readPools,
  readRewardsRound,
  readVoterAddresses,
  readVotes,
  rebaseRefusal,
  voterRefusal,
} from "../lib/votes";
import { APP_CHAIN_ID } from "../lib/wagmi";
import type { useLoanWrite } from "./useLoanWrite";

const POLL_MS = 15_000;
const ADDRESSES_KEY = ["voter-addresses"] as const;

type Send = ReturnType<typeof useLoanWrite>["send"];

const useClient = () => usePublicClient({ chainId: APP_CHAIN_ID }) as PublicClient | undefined;

/** The voter, the fee distributor and the vote limit. They are fixed at deployment, so they are read once. */
export function useVoterAddresses() {
  const client = useClient();
  return useQuery({
    queryKey: ADDRESSES_KEY,
    queryFn: () => readVoterAddresses(client as PublicClient),
    enabled: client !== undefined,
    staleTime: Infinity,
    retry: false,
  });
}

/** Every pool on the voter with its name and whether its gauge takes votes. */
export function useVotePools() {
  const client = useClient();
  const addresses = useVoterAddresses();
  const voter = addresses.data?.poolsVoter;
  return useQuery({
    queryKey: ["vote-pools", voter],
    queryFn: () => readPools(client as PublicClient, voter as `0x${string}`),
    enabled: client !== undefined && voter !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

/** The pools one position's vote stands on, and when it last voted. */
export function useVotes(tokenId: bigint, enabled = true) {
  const client = useClient();
  const addresses = useVoterAddresses();
  const voter = addresses.data?.poolsVoter;
  const maxVotes = addresses.data?.maxVotes;
  return useQuery({
    queryKey: ["votes", voter, tokenId.toString()],
    queryFn: () => readVotes(client as PublicClient, voter as `0x${string}`, maxVotes as number, tokenId),
    enabled: enabled && client !== undefined && voter !== undefined && maxVotes !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

/** The gauges and token lists a pool rewards claim would send, so the screen knows whether it has anything to claim. */
export function useClaimPlan(tokenId: bigint, enabled: boolean) {
  const client = useClient();
  const addresses = useVoterAddresses();
  const votes = useVotes(tokenId, enabled);
  const voter = addresses.data?.poolsVoter;
  const pools = votes.data?.pools.map((entry) => entry.pool);
  return useQuery({
    queryKey: ["claim-plan", voter, tokenId.toString(), pools?.join(",")],
    queryFn: () => buildClaimRewardsArgs(client as PublicClient, voter as `0x${string}`, pools ?? []),
    enabled: enabled && client !== undefined && voter !== undefined && pools !== undefined,
    refetchInterval: POLL_MS,
    retry: false,
  });
}

let toastCounter = 0;
const nowSeconds = () => Math.floor(Date.now() / 1000);

/**
 * The actions that need a look at the voter before anything is sent: reset, claim rebase and claim pool rewards.
 * Each one stops with a toast in plain words when the voter would refuse, so a wallet prompt is never wasted.
 */
export function useVoteActions(send: Send) {
  const client = useClient();
  const queryClient = useQueryClient();
  const [acting, setActing] = useState<string | null>(null);

  const stop = useCallback((detail: string) => {
    showToast({ id: `vote-note-${(toastCounter += 1)}`, kind: "problem", title: "Not sent", detail });
  }, []);

  const run = useCallback(
    async (key: string, work: () => Promise<unknown>) => {
      setActing(key);
      try {
        await work();
      } catch {
        stop("Doji could not read the voter right now. Try again in a moment.");
      } finally {
        setActing(null);
      }
    },
    [stop],
  );

  const addresses = useCallback(
    () =>
      queryClient.fetchQuery({
        queryKey: ADDRESSES_KEY,
        queryFn: () => readVoterAddresses(client as PublicClient),
        staleTime: Infinity,
      }),
    [client, queryClient],
  );

  const resetVotes = useCallback(
    (id: bigint) =>
      run(`reset:${id}`, async () => {
        const { poolsVoter, maxVotes } = await addresses();
        const state = await readVotes(client as PublicClient, poolsVoter, maxVotes, id);
        const refusal = voterRefusal("reset", state.lastVoted, nowSeconds());
        if (refusal) return stop(refusal);
        await send(buildResetCall(id), `The votes on veBTC #${id} are cleared.`);
      }),
    [addresses, client, run, send, stop],
  );

  const claimRebase = useCallback(
    (id: bigint) =>
      run(`rebase:${id}`, async () => {
        const { feeDistributor } = await addresses();
        const refusal = rebaseRefusal(await readRewardsRound(client as PublicClient, feeDistributor), nowSeconds());
        if (refusal) return stop(refusal);
        await send(buildClaimRebaseCall(id), `The rebase for veBTC #${id} is claimed.`);
      }),
    [addresses, client, run, send, stop],
  );

  const claimRewards = useCallback(
    (id: bigint) =>
      run(`rewards:${id}`, async () => {
        const { poolsVoter, maxVotes } = await addresses();
        const state = await readVotes(client as PublicClient, poolsVoter, maxVotes, id);
        const plan = await buildClaimRewardsArgs(
          client as PublicClient,
          poolsVoter,
          state.pools.map((entry) => entry.pool),
        );
        if (plan.gauges.length === 0) {
          return stop(
            state.pools.length === 0
              ? "This position has no votes, so no pool pays it anything. Vote first."
              : "Mezo's voter lists no reward token for these pools yet, so there is nothing Doji can claim.",
          );
        }
        await send(buildClaimRewardsCall(id, plan), (receipt) => forwardedLine(parseForwarded(receipt, plan.tokens)));
      }),
    [addresses, client, run, send, stop],
  );

  return { acting, resetVotes, claimRebase, claimRewards };
}

export type VoteActions = ReturnType<typeof useVoteActions>;

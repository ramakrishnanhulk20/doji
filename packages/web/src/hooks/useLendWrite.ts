"use client";

import { useCallback } from "react";
import type { LendCall } from "../lib/lend";
import { useWrite, type WriteResult, type WriteTarget } from "./useWrite";

/**
 * Sends one Lend call through the shared write hook, so it is simulated first and shows the usual toasts.
 * useWrite finds the contract by name in the address book, and its name type does not list the MUSD token, so the
 * name is passed through as the same kind of key.
 */
export function useLendWrite() {
  const { write, busy } = useWrite();

  const send = useCallback(
    (call: LendCall, successLine: string): Promise<WriteResult> =>
      write({
        target: call.target as WriteTarget,
        abi: call.abi,
        functionName: call.functionName,
        args: call.args,
        successLine,
      }),
    [write],
  );

  return { send, busy };
}

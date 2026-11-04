"use client";

import { useCallback } from "react";
import type { LendCall } from "../lib/lend";
import { useWrite, type SuccessLine, type WriteResult } from "./useWrite";

/**
 * Sends one Lend call through the shared write hook, so it is simulated first and shows the usual toasts.
 * useWrite finds the contract by the name the call carries, which already names the pair the call belongs to.
 */
export function useLendWrite() {
  const { write, busy } = useWrite();

  const send = useCallback(
    (call: LendCall, successLine: SuccessLine): Promise<WriteResult> =>
      write({
        target: call.target,
        abi: call.abi,
        functionName: call.functionName,
        args: call.args,
        successLine,
      }),
    [write],
  );

  return { send, busy };
}

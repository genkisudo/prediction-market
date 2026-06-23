/**
 * Pure resolution logic for the World Cup prediction-market resolver.
 *
 * Kept separate from `main.ts` (the WASM entry point) for two reasons:
 *   1. The CRE/Javy compiler turns every *exported* function in the entry
 *      module into a WASM export, and WASM exports may not take parameters.
 *      Helpers therefore live here and are imported (not re-exported) by main.
 *   2. These functions are deterministic and side-effect free, so they are
 *      unit-tested directly in `main.test.ts`.
 *
 * Only `viem` is used here — no Node built-ins — so it is QuickJS/WASM-safe.
 */

import { encodeAbiParameters, parseAbiParameters, type Hex } from "viem";

/** Mirrors PredictionMarket.Outcome (Yes=1, No=2, Invalid=3). */
export const OUTCOME = { YES: 1, NO: 2, INVALID: 3 } as const;

/** ABI shape of the report body consumed by PredictionMarket.onReport. */
export const RESOLUTION_REPORT_PARAMS = parseAbiParameters("(uint256 marketId, uint8 outcome)[]");

export type EventResult = {
  eventId: string;
  status: string; // "SETTLED" | "PENDING"
  outcome: string; // "YES" | "NO" | "INVALID" | "NONE"
};

export type Resolution = { marketId: bigint; outcome: number };

/** Map an API event result to an on-chain outcome code, or null if not settleable. */
export function outcomeCodeFor(result: EventResult): number | null {
  if (result.status !== "SETTLED") return null;
  switch (result.outcome) {
    case "YES":
      return OUTCOME.YES;
    case "NO":
      return OUTCOME.NO;
    case "INVALID":
      return OUTCOME.INVALID;
    default:
      return null;
  }
}

/** Build the settlement batch from chain markets + their fetched results. */
export function buildResolutions(
  markets: { marketId: bigint; eventId: string }[],
  results: Map<string, EventResult>,
): Resolution[] {
  const resolutions: Resolution[] = [];
  for (const m of markets) {
    const result = results.get(m.eventId);
    if (!result) continue;
    const code = outcomeCodeFor(result);
    if (code === null) continue;
    resolutions.push({ marketId: m.marketId, outcome: code });
  }
  return resolutions;
}

/** ABI-encode the Resolution[] report body. */
export function encodeResolutionReport(resolutions: Resolution[]): Hex {
  return encodeAbiParameters(RESOLUTION_REPORT_PARAMS, [
    resolutions.map((r) => ({ marketId: r.marketId, outcome: r.outcome })),
  ]);
}

import { sepolia } from "wagmi/chains";
import { predictionMarketAbi } from "./abi";

export const predictionMarket = {
  address: (process.env.NEXT_PUBLIC_MARKET_ADDRESS ??
    "0x0000000000000000000000000000000000000000") as `0x${string}`,
  abi: predictionMarketAbi,
  chainId: sepolia.id,
} as const;

/** PredictionMarket.Outcome enum. */
export const Outcome = {
  Unresolved: 0,
  Yes: 1,
  No: 2,
  Invalid: 3,
} as const;

export const outcomeLabel: Record<number, string> = {
  0: "Open",
  1: "YES won",
  2: "NO won",
  3: "Voided — refunds",
};

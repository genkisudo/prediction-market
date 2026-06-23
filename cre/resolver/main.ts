/**
 * World Cup Prediction Market — CRE Resolver Workflow
 * ===================================================
 *
 * Chainlink CRE acts as the decentralized oracle that settles markets with no
 * manual intervention. On every cron tick the workflow:
 *
 *   1. Reads `getResolvableMarkets()` from the PredictionMarket contract
 *      (markets past their resolve time that are still open).
 *   2. For each market, fetches the verifiable match result from the configured
 *      sports-results API. The fetch runs on every DON node and the responses
 *      are reduced by consensus (identical agreement), so a single node can't
 *      forge an outcome.
 *   3. Encodes the settled results as a `Resolution[]` report, has the DON sign
 *      it (`runtime.report`), and writes it on-chain via `writeReport`. The
 *      KeystoneForwarder calls `onReport` on the contract, which settles every
 *      market in the batch atomically. Winners can `claim()` immediately.
 *
 * Because resolution + payout are a single signed on-chain write triggered on a
 * tight cron cadence, settlement lands in ~minutes, not the 1–2 hours a manual
 * dispute/settlement flow takes.
 *
 * NOTE: only `main` (no parameters) is exported from this entry module — the
 * CRE/Javy WASM compiler forbids exported functions that take parameters. Pure
 * helpers live in `./lib`.
 */

import {
  ConsensusAggregationByFields,
  CronCapability,
  EVMClient,
  HTTPClient,
  LAST_FINALIZED_BLOCK_NUMBER,
  Runner,
  encodeCallMsg,
  handler,
  identical,
  ok,
  prepareReportRequest,
  text,
  type HTTPSendRequester,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  bytesToHex,
  decodeFunctionResult,
  encodeFunctionData,
  parseAbi,
  type Hex,
} from "viem";
import { buildResolutions, encodeResolutionReport, type EventResult } from "./lib";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

type Config = {
  /** Cron schedule. Frequent cadence keeps settlement latency low. */
  schedule: string;
  /** CRE chain selector name, e.g. "ethereum-testnet-sepolia". */
  chainName: string;
  /** Deployed PredictionMarket address. */
  marketContractAddress: string;
  /** Base URL of the sports-results oracle source (no trailing slash). */
  apiBaseUrl: string;
  /** Gas limit for the settlement write. */
  gasLimit?: string;
};

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

const MARKET_ABI = parseAbi([
  "function getResolvableMarkets() view returns (uint256[] ids, string[] eventIds)",
]);

function chainSelector(chainName: string): bigint {
  const selectors = EVMClient.SUPPORTED_CHAIN_SELECTORS as Record<string, bigint>;
  const selector = selectors[chainName];
  if (selector === undefined) {
    throw new Error(`Unsupported chain selector name: ${chainName}`);
  }
  return selector;
}

// ---------------------------------------------------------------------------
// Capability calls
// ---------------------------------------------------------------------------

/** Read markets eligible for resolution from the contract (consensus by the DON). */
function readResolvableMarkets(
  runtime: Runtime<Config>,
  evmClient: EVMClient,
): { marketId: bigint; eventId: string }[] {
  const callData = encodeFunctionData({ abi: MARKET_ABI, functionName: "getResolvableMarkets" });

  const reply = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: ZERO_ADDRESS,
        to: runtime.config.marketContractAddress as Hex,
        data: callData,
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result();

  const data = bytesToHex(reply.data);
  if (data === "0x") return [];

  const [ids, eventIds] = decodeFunctionResult({
    abi: MARKET_ABI,
    functionName: "getResolvableMarkets",
    data,
  }) as readonly [readonly bigint[], readonly string[]];

  return ids.map((marketId, i) => ({ marketId, eventId: eventIds[i] }));
}

/** Fetch one event result from the oracle source with cross-node consensus. */
function fetchEventResult(
  runtime: Runtime<Config>,
  httpClient: HTTPClient,
  eventId: string,
): EventResult {
  const url = `${runtime.config.apiBaseUrl}/results/${encodeURIComponent(eventId)}`;

  return httpClient
    .sendRequest(
      runtime,
      (sender: HTTPSendRequester): EventResult => {
        const resp = sender.sendRequest({ url, method: "GET" }).result();
        if (!ok(resp)) {
          throw new Error(`HTTP ${resp.statusCode} for ${eventId}`);
        }
        const body = JSON.parse(text(resp)) as {
          eventId?: string;
          status?: string;
          outcome?: string | null;
        };
        return {
          eventId: body.eventId ?? eventId,
          status: String(body.status ?? "PENDING"),
          outcome: String(body.outcome ?? "NONE"),
        };
      },
      ConsensusAggregationByFields<EventResult>({
        eventId: identical,
        status: identical,
        outcome: identical,
      }),
    )()
    .result();
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

const onResolveTick = (runtime: Runtime<Config>): string => {
  const evmClient = new EVMClient(chainSelector(runtime.config.chainName));
  const httpClient = new HTTPClient();

  let markets: { marketId: bigint; eventId: string }[] = [];
  try {
    markets = readResolvableMarkets(runtime, evmClient);
  } catch (err) {
    runtime.log(`Could not read resolvable markets (contract deployed & address set?): ${String(err)}`);
    return JSON.stringify({ resolved: 0, reason: "read-failed" });
  }

  if (markets.length === 0) {
    runtime.log("No markets are due for resolution.");
    return JSON.stringify({ resolved: 0, reason: "none-due" });
  }

  runtime.log(`Found ${markets.length} market(s) due for resolution.`);

  const results = new Map<string, EventResult>();
  for (const m of markets) {
    try {
      const result = fetchEventResult(runtime, httpClient, m.eventId);
      results.set(m.eventId, result);
      runtime.log(`Event ${m.eventId}: status=${result.status} outcome=${result.outcome}`);
    } catch (err) {
      runtime.log(`Skipping ${m.eventId}: ${String(err)}`);
    }
  }

  const resolutions = buildResolutions(markets, results);
  if (resolutions.length === 0) {
    runtime.log("No settled results yet; nothing to write this tick.");
    return JSON.stringify({ resolved: 0, reason: "not-settled" });
  }

  const encoded = encodeResolutionReport(resolutions);
  const report = runtime.report(prepareReportRequest(encoded)).result();

  const writeReply = evmClient
    .writeReport(runtime, {
      receiver: runtime.config.marketContractAddress as Hex,
      report,
      gasConfig: { gasLimit: runtime.config.gasLimit ?? "2000000" },
    })
    .result();

  const txHash = writeReply.txHash ? bytesToHex(writeReply.txHash) : "n/a";
  runtime.log(
    `Settled ${resolutions.length} market(s). txStatus=${writeReply.txStatus} txHash=${txHash}`,
  );

  return JSON.stringify({
    resolved: resolutions.length,
    marketIds: resolutions.map((r) => r.marketId.toString()),
    txStatus: writeReply.txStatus,
    txHash,
  });
};

// ---------------------------------------------------------------------------
// Workflow wiring
// ---------------------------------------------------------------------------

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  return [handler(cron.trigger({ schedule: config.schedule }), onResolveTick)];
};

// The CRE runtime imports this module and invokes the exported `main`.
export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}

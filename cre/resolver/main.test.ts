import { describe, expect, test } from "bun:test";
import { decodeAbiParameters, parseAbiParameters } from "viem";
import {
  OUTCOME,
  buildResolutions,
  encodeResolutionReport,
  outcomeCodeFor,
  type EventResult,
} from "./lib";

describe("outcomeCodeFor", () => {
  test("maps settled YES/NO/INVALID to outcome codes", () => {
    expect(outcomeCodeFor({ eventId: "e", status: "SETTLED", outcome: "YES" })).toBe(OUTCOME.YES);
    expect(outcomeCodeFor({ eventId: "e", status: "SETTLED", outcome: "NO" })).toBe(OUTCOME.NO);
    expect(outcomeCodeFor({ eventId: "e", status: "SETTLED", outcome: "INVALID" })).toBe(
      OUTCOME.INVALID,
    );
  });

  test("returns null for pending or unknown results", () => {
    expect(outcomeCodeFor({ eventId: "e", status: "PENDING", outcome: "NONE" })).toBeNull();
    expect(outcomeCodeFor({ eventId: "e", status: "PENDING", outcome: "YES" })).toBeNull();
    expect(outcomeCodeFor({ eventId: "e", status: "SETTLED", outcome: "NONE" })).toBeNull();
  });
});

describe("buildResolutions", () => {
  const markets = [
    { marketId: 1n, eventId: "ronaldo" },
    { marketId: 2n, eventId: "messi" },
    { marketId: 3n, eventId: "usa" },
  ];

  test("includes only settled markets and preserves ids", () => {
    const results = new Map<string, EventResult>([
      ["ronaldo", { eventId: "ronaldo", status: "SETTLED", outcome: "NO" }],
      ["messi", { eventId: "messi", status: "SETTLED", outcome: "YES" }],
      ["usa", { eventId: "usa", status: "PENDING", outcome: "NONE" }],
    ]);
    const resolutions = buildResolutions(markets, results);
    expect(resolutions).toEqual([
      { marketId: 1n, outcome: OUTCOME.NO },
      { marketId: 2n, outcome: OUTCOME.YES },
    ]);
  });

  test("skips markets with no fetched result", () => {
    const results = new Map<string, EventResult>([
      ["messi", { eventId: "messi", status: "SETTLED", outcome: "YES" }],
    ]);
    expect(buildResolutions(markets, results)).toEqual([{ marketId: 2n, outcome: OUTCOME.YES }]);
  });

  test("returns empty when nothing is settled", () => {
    const results = new Map<string, EventResult>([
      ["ronaldo", { eventId: "ronaldo", status: "PENDING", outcome: "NONE" }],
    ]);
    expect(buildResolutions(markets, results)).toEqual([]);
  });
});

describe("encodeResolutionReport", () => {
  test("encodes a Resolution[] that round-trips through the on-chain ABI shape", () => {
    const resolutions = [
      { marketId: 1n, outcome: OUTCOME.NO },
      { marketId: 7n, outcome: OUTCOME.YES },
    ];
    const encoded = encodeResolutionReport(resolutions);

    const [decoded] = decodeAbiParameters(
      parseAbiParameters("(uint256 marketId, uint8 outcome)[]"),
      encoded,
    );

    expect(decoded).toEqual([
      { marketId: 1n, outcome: 2 },
      { marketId: 7n, outcome: 1 },
    ]);
  });
});

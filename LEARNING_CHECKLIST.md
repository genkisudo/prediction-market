# Session Deep-Understanding Checklist

## Stage 1 — The Problem
- [x] What a prediction market is and why it needs an oracle
- [x] Why the oracle problem is hard (the "real world → blockchain" gap)
- [x] How UMA's optimistic oracle works (propose → dispute window → finalize)
- [x] Why UMA's approach is slow (and when slow is fine vs. not fine)
- [x] Why 1–2 hour settlement is a bad fit for this use case

## Stage 2 — The Solution: Chainlink CRE
- [x] What a DON is and why decentralization matters
- [x] What CRE is and how it differs from Chainlink Functions / Automation
- [x] The five-step resolution loop (cron → read → fetch → agree → sign → write)
- [x] What `ConsensusAggregationByFields(identical)` actually does
- [x] What the KeystoneForwarder is and why it exists
- [x] Why cryptographic trust beats economic (dispute) trust here
- [x] Why CRE reads at LAST_FINALIZED_BLOCK_NUMBER (reorg safety)

## Stage 3 — The Smart Contract
- [x] `PredictionMarket.sol` lifecycle: create → bet → resolve → claim
- [x] Parimutuel payout math (how winners are paid from the losing pool)
- [x] `onReport` / `_processReport` — who calls it and how
- [x] Edge case: auto-void when winning side has zero stake → zero fee
- [x] Edge case: `Invalid` outcome → full refunds, zero fee
- [x] Edge case: `voidMarket()` 7-day delay prevents owner gaming outcomes
- [x] Security: `onlyForwarder`, `nonReentrant`, `immutable` forwarder

## Stage 4 — The CRE Workflow Code
- [x] Why TypeScript → WASM (Javy/QuickJS) and what that limits
- [x] Why exported functions can't have parameters in Javy WASM
- [x] Why `lib.ts` and `main.ts` are separated
- [x] How `EVMClient.callContract` reads on-chain data
- [x] How `HTTPClient.sendRequest` with consensus works
- [x] `LAST_FINALIZED_BLOCK_NUMBER` — what it is and why it matters
- [x] `prepareReportRequest` and `runtime.report` — signing flow
- [x] `EVMClient.writeReport` — what actually hits the chain

## Stage 5 — Broader Context
- [x] What this pattern unlocks for DeFi beyond prediction markets
- [x] The trust hierarchy: DON → data source → relay
- [x] Why the relay normalizing the API matters for consensus
- [x] What needs to change to go from local dev to Sepolia to mainnet
- [x] Security notes: what the owner can do and why that needs a timelock

---
**Progress:** All 5 stages ✅ COMPLETE

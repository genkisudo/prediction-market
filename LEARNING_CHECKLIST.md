# Session Deep-Understanding Checklist

## Stage 1 — The Problem
- [ ] What a prediction market is and why it needs an oracle
- [ ] Why the oracle problem is hard (the "real world → blockchain" gap)
- [ ] How UMA's optimistic oracle works (propose → dispute window → finalize)
- [ ] Why UMA's approach is slow (and when slow is fine vs. not fine)
- [ ] Why 1–2 hour settlement is a bad fit for this use case

## Stage 2 — The Solution: Chainlink CRE
- [ ] What a DON is and why decentralization matters
- [ ] What CRE is and how it differs from Chainlink Functions / Automation
- [ ] The five-step resolution loop (cron → read → fetch → agree → sign → write)
- [ ] What `ConsensusAggregationByFields(identical)` actually does
- [ ] What the KeystoneForwarder is and why it exists
- [ ] Why cryptographic trust beats economic (dispute) trust here

## Stage 3 — The Smart Contract
- [ ] `PredictionMarket.sol` lifecycle: create → bet → resolve → claim
- [ ] Parimutuel payout math (how winners are paid from the losing pool)
- [ ] `onReport` / `_processReport` — who calls it and how
- [ ] Edge case: auto-void when winning side has zero stake
- [ ] Edge case: `Invalid` outcome → full refunds, no fee
- [ ] Edge case: `voidMarket()` owner safety valve (7-day window)
- [ ] Security: `onlyForwarder`, `nonReentrant`, `immutable` forwarder

## Stage 4 — The CRE Workflow Code
- [ ] Why TypeScript → WASM (Javy/QuickJS) and what that limits
- [ ] Why exported functions can't have parameters in Javy WASM
- [ ] Why `lib.ts` and `main.ts` are separated
- [ ] How `EVMClient.callContract` reads on-chain data
- [ ] How `HTTPClient.sendRequest` with consensus works
- [ ] `LAST_FINALIZED_BLOCK_NUMBER` — what it is and why it matters
- [ ] `prepareReportRequest` and `runtime.report` — signing flow
- [ ] `EVMClient.writeReport` — what actually hits the chain

## Stage 5 — Broader Context
- [ ] What this pattern unlocks for DeFi beyond prediction markets
- [ ] The trust hierarchy: DON → data source → relay
- [ ] Why the relay normalizing the API matters for consensus
- [ ] What needs to change to go from local dev to Sepolia to mainnet
- [ ] Security notes: what the owner can do and why that needs a timelock

---
**Progress:** Stage 1 of 5 | Not started

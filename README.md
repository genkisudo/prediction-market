# ⚽ WorldCup Markets — onchain prediction markets resolved by Chainlink CRE

Trade **YES/NO** markets on FIFA World Cup outcomes (e.g. _"Will Ronaldo win his first World Cup?"_).
Markets are settled **automatically** from verifiable match-result data by a **Chainlink CRE**
(Chainlink Runtime Environment) workflow acting as the prediction-market oracle — **no manual
settlement** — and winners are **paid out onchain in minutes**, not the 1–2 hours a manual
dispute/settlement flow takes.

The whole lifecycle — **market creation, escrow, resolution, and payout** — is handled end to end.

```
┌─────────────┐   bet YES/NO (ETH)   ┌────────────────────────┐
│  Frontend   │ ───────────────────► │   PredictionMarket.sol │   escrow + parimutuel payout
│ (Next.js +  │ ◄─────────────────── │   (Sepolia)            │
│  wagmi)     │   read markets/odds  └───────────▲────────────┘
└─────────────┘                                  │ onReport (signed report)
                                                 │
                                      ┌───────────┴────────────┐
                                      │  KeystoneForwarder      │  verifies DON signatures
                                      └───────────▲────────────┘
                                                  │ writeReport
                              ┌───────────────────┴───────────────────┐
                              │     CRE Resolver Workflow (DON)         │
                              │  cron → read getResolvableMarkets()     │
                              │       → HTTP fetch match result         │  ← consensus across nodes
                              │       → sign Resolution[] report        │
                              └───────────────────▲───────────────────┘
                                                  │ GET /results/:eventId
                                      ┌───────────┴────────────┐
                                      │  Sports-results feed     │  (mock now; swap real API)
                                      └─────────────────────────┘
```

## Why Chainlink CRE is the oracle

There is no native price feed for "did Ronaldo win the World Cup". CRE lets a decentralized
oracle network (DON) **fetch verifiable match-result data over HTTP, agree on it by consensus,
sign a report, and write it onchain** — exactly the trust model a prediction-market oracle needs:

- **No single trusted settler.** Every DON node fetches the result; the workflow only proceeds on
  values the nodes agree on (`ConsensusAggregationByFields(... identical)`).
- **No manual settlement.** A cron trigger sweeps resolvable markets every minute and settles them.
- **Tamper-evident payout.** The contract only accepts reports relayed by the `KeystoneForwarder`,
  so settlement can't be forged.

This is a general-purpose pattern, not a sports-specific one. RWA lending and automated
rebalancing use this exact same five-step loop: DON fetches real-world data → consensus → signed
report → contract acts. Sports outcomes are just one instance.

### Why not Hyperliquid HIP-4?

Hyperliquid's HIP-4 outcome markets sidestep the oracle problem entirely — settlement resolves
against Hyperliquid's own internal mark price (e.g. BTC at 06:00 UTC daily), so no external data
fetch is needed. That works because the truth is already inside the same closed system.

"Did Ronaldo win the World Cup?" has no answer on any blockchain. The moment settlement depends on
a real-world event, you need an oracle. CRE is the right tool; HIP-4 is not applicable.

## How the resolver workflow works

A **cron timer** wakes the workflow every minute (configurable). It **reads the contract** to find
markets whose `resolveTime` has passed but aren't settled yet, **fetches the real match result over
HTTP** from a sports-data source, and then **every node in the Chainlink DON independently fetches
that same result and must agree** on it (consensus). Once they agree, the DON **cryptographically
signs** the outcome and **writes it back to the contract**, which flips the market to YES/NO and
lets winners claim immediately.

The five steps in order:

1. **Cron fires.** Every node in the DON wakes on the schedule and asks: is anything resolvable
   right now?
2. **Read the contract.** `getResolvableMarkets()` returns all markets that are past their
   `resolveTime` and still unresolved — returning their on-chain IDs and the off-chain `eventId`
   keys.
3. **Fetch and reach consensus.** For each market, every DON node independently fetches the match
   result from the configured sports feed. The DON compares all nodes' answers using
   `ConsensusAggregationByFields(...identical)` — every field must be identical across all nodes.
   If even one node gets a different response (network error, stale data), consensus fails and that
   market is skipped this tick.
4. **Sign a report.** The DON encodes the `Resolution[]` batch (market IDs + outcome codes) and
   collectively signs it — like a multi-signature from the quorum of DON nodes.
5. **Write on-chain.** The signed report is submitted to the `KeystoneForwarder`, which verifies
   the DON's signatures and forwards to `PredictionMarket.onReport`. Each market in the batch is
   settled atomically in one transaction.

### Why no UMA oracle is needed

UMA's optimistic oracle works by *waiting*: someone **proposes** an answer, there is a **dispute
window** (hours), and if anyone disputes, UMA token-holders **vote** over days — that delay is the
"1–2 hours" optimistic case, or much longer if disputed. CRE flips the model entirely: instead of
_"assume it's right unless someone challenges,"_ it **goes and gets the truth directly** — multiple
independent nodes pull the verifiable result and only proceed on the value they all agree on. Trust
comes from **decentralized fetching + cryptographic signatures, not from an economic dispute game**,
so there is no proposer, no disputer, no voting period — settlement lands in minutes.

| Property | UMA Optimistic Oracle | Chainlink CRE |
|---|---|---|
| Settlement time | 2+ hours (dispute window) | ~1 minute (next cron tick) |
| Trust model | Economic (bonds + challengers) | Cryptographic (DON multi-sig) |
| Manual intervention | Possible dispute resolution | None |
| Data source | Any proposer + dispute | DON nodes fetch + consensus |
| Failure mode | Unchallenged wrong answer wins | DON consensus fails → no settlement |
| On-chain verification | Bond expiry | Signature verification by KeystoneForwarder |

### Honest tradeoffs

Neither model is unconditionally better — they have different failure modes and suit different risk
profiles.

**What CRE's DON consensus does protect against:**

- A single node getting a network error or returning a stale response (consensus fails → no wrong
  settlement)
- A single compromised or malicious node forging an outcome (the quorum won't agree with it)
- Anyone forging a report on-chain without the DON's private keys (the `KeystoneForwarder`
  rejects it)

**What CRE's DON consensus does NOT protect against:**

- **The data source itself returning wrong data.** If the sports API sends the same incorrect
  result to all 7 nodes, consensus passes on a wrong answer. The DON faithfully reports what it
  saw — garbage in, garbage out.
- A coordinated attack on a majority of DON nodes simultaneously.

**What UMA protects against that CRE does not:**

- Subtly ambiguous or disputed outcomes — UMA's human-vote mechanism can handle edge cases
  ("the match was abandoned in extra time") that a deterministic API response can't capture.

**The root tradeoff:**

| | UMA | Chainlink CRE |
|---|---|---|
| Trust anchor | Human challengers + token-holder vote | Data source + DON node honesty |
| Fails silently if | Nobody challenges a wrong answer | The data source lies uniformly |
| Best suited for | Ambiguous, subjective, or rare outcomes | Objective, deterministic, frequent outcomes |
| Speed | 2+ hours minimum | ~1 minute |

For this use case — "did team X win the World Cup?" — the outcome is objective and universally
reported, making CRE the right fit. For "was the project milestone actually delivered?", UMA's
human arbitration is better. Choose your oracle based on the nature of the question, not just the
speed requirement.

## Repository layout

| Path          | What it is                                                                 |
| ------------- | -------------------------------------------------------------------------- |
| `contracts/`  | Foundry project — `PredictionMarket.sol` (escrow, parimutuel payout, `onReport` resolution) + 24 tests |
| `cre/`        | CRE TypeScript project — the resolver workflow (`cre/resolver/`)           |
| `mock-api/`   | Mock sports-results oracle source for local dev & CRE simulation           |
| `frontend/`   | Next.js + wagmi/viem dApp — browse markets, trade YES/NO, claim winnings   |
| `shared/`     | Generated `PredictionMarket.abi.json` shared by the workflow & frontend    |

## The contract lifecycle (`contracts/src/PredictionMarket.sol`)

1. **Create** — owner calls `createMarket(question, eventId, tradingDeadline, resolveTime)`.
   `eventId` is the key the oracle resolves against.
2. **Escrow** — anyone calls `betYes{value}(id)` / `betNo{value}(id)` before `tradingDeadline`.
   Stakes are held by the contract.
3. **Resolve** — after `resolveTime`, the CRE workflow delivers a signed `Resolution[]` report via
   the forwarder → `onReport` → `_processReport`. Each market is settled atomically. Betting is
   already closed, so no one can bet against a known result.
4. **Payout** — winners call `claim(id)` and receive their stake **plus a pro-rata share of the
   losing pool**, net of a protocol fee (default 2%, taken from the losing pool only).

### Parimutuel payout model

This contract uses the same model as horse racing: your payout is not fixed when you place your
bet — it depends on the final split between the two sides.

```
distributable = losingPool − (losingPool × feeBps / 10_000)
yourPayout    = yourStake + (distributable × yourStake / totalWinningPool)
```

Example: Alice bets 1 ETH YES, Bob bets 2 ETH NO, Carol bets 1 ETH NO. Oracle says NO.
Fee = 2%.

- Losing pool = 1 ETH. Fee = 0.02 ETH. Distributable = 0.98 ETH.
- Total NO pool = 3 ETH. Bob holds 2/3, Carol holds 1/3.
- Bob gets: 2 ETH stake + (0.98 × 2/3) ≈ **2.653 ETH**
- Carol gets: 1 ETH stake + (0.98 × 1/3) ≈ **1.327 ETH**

Key rule: **the protocol fee is taken from the losing pool only.** Winners always receive their
full stake back at minimum. If the winning side has zero bettors, or the outcome is `Invalid`,
the market auto-voids and **everyone gets a full refund with zero fee**.

### Safety properties enforced by the contract

- Bets rejected at/after the trading deadline and once resolved.
- A market whose **winning side has zero stake** auto-voids → full refunds, zero fee.
- `Invalid` outcome → full refunds, zero fee.
- `voidMarket()` owner safety valve if the oracle *never* resolves — only callable 7+ days after
  `resolveTime` so the owner can't use it to cancel a market with an unfavorable result.
- `claim()` is `nonReentrant` and idempotent per user.

Outcome codes shared between the workflow and contract: `Yes=1`, `No=2`, `Invalid=3`.

## Quick start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`)
- [Bun](https://bun.sh) ≥ 1.2.21
- [CRE CLI](https://docs.chain.link/cre) (`cre`) + a CRE account for deployment
- Node ≥ 20 (for the mock API)

### 1. Contracts — build & test

```bash
cd contracts
forge test -vv          # 24 tests: escrow, resolution, parimutuel payout, refunds, fees
```

Regenerate the shared ABI after any contract change:

```bash
forge inspect PredictionMarket abi --json > ../shared/PredictionMarket.abi.json
```

### 2. Mock sports-results feed

```bash
cd mock-api
npm start               # http://localhost:8888
curl http://localhost:8888/results/wc2026-ronaldo-champion
# {"eventId":"...","status":"SETTLED","outcome":"NO",...}
```

Outcome of any event can be flipped for demos:

```bash
curl -X POST http://localhost:8888/results/wc2026-ronaldo-champion \
  -H 'content-type: application/json' \
  -d '{"status":"SETTLED","outcome":"YES"}'
```

### 3. CRE resolver workflow

```bash
cd cre/resolver
bun install
bun test                # pure resolution-logic unit tests
bun run typecheck
```

Simulate (compiles to WASM, fires the cron trigger once, reads the contract, returns):

```bash
cd cre
cre workflow simulate resolver --target staging-settings --non-interactive --trigger-index 0
```

Config lives in `cre/resolver/config.staging.json`:

```json
{
  "schedule": "*/20 * * * * *",
  "chainName": "ethereum-testnet-sepolia",
  "marketContractAddress": "0xYourDeployedMarket",
  "apiBaseUrl": "http://localhost:8888",
  "gasLimit": "2000000"
}
```

> With `marketContractAddress` unset (zero address) the simulation reads cleanly and reports
> "No markets are due for resolution". Point it at a deployed contract with a resolvable market to
> exercise the full HTTP-fetch → consensus → settlement path.

### 4. Frontend

```bash
cd frontend
bun install
cp .env.local.example .env.local   # set NEXT_PUBLIC_MARKET_ADDRESS
bun run dev                         # http://localhost:3000
```

## Deploying to Sepolia (testnet)

1. **Deploy the contract** with the Sepolia KeystoneForwarder
   (`0xF8344CFd5c43616a4366C34E3EEE75af79a74482` — verify in the
   [CRE forwarder directory](https://docs.chain.link/cre/guides/workflow/using-evm-client/forwarder-directory-ts)):

   ```bash
   cd contracts
   export PRIVATE_KEY=0x...                 # funded Sepolia key
   export FORWARDER=0xF8344CFd5c43616a4366C34E3EEE75af79a74482
   export FEE_BPS=200
   forge script script/Deploy.s.sol \
     --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
   ```

2. **Create a market** (short windows are handy for a live demo):

   ```bash
   export MARKET=0xYourDeployedMarket
   export EVENT_ID=wc2026-ronaldo-champion
   export TRADING_SECONDS=120 RESOLVE_SECONDS=120
   forge script script/SeedMarket.s.sol \
     --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
   ```

3. **Expose the results feed.** Host `mock-api/` (or a real provider) at a public HTTPS URL and put
   it in `config.*.json` `apiBaseUrl`. For a keyed provider, store the key as a CRE secret and read
   it in node mode (`runtime.getSecret`) instead of a plain GET.

4. **Deploy the workflow.** Set `marketContractAddress` in the config, fund the workflow owner key
   in `cre/.env` (`CRE_ETH_PRIVATE_KEY`), then follow the CRE deploy flow
   (`cre workflow deploy` — requires deployment access via `cre account access`).

Once live, the workflow's cron cadence (every minute in production config) settles each market
within ~1 trigger interval of `resolveTime`, and winners can `claim()` immediately — end-to-end
settlement in **~minutes**.

## Swapping in a real sports API

The workflow only depends on the response shape:

```jsonc
{ "eventId": "…", "status": "SETTLED" | "PENDING", "outcome": "YES" | "NO" | "INVALID" | null }
```

Adapt a provider (e.g. football-data.org, API-Football) behind a small relay that maps each
`eventId` to a settled YES/NO/INVALID, and point `apiBaseUrl` at it. The relay is the right place
to hold the provider API key and to normalize results deterministically so DON nodes reach
consensus.

## Tests at a glance

- `contracts/test/PredictionMarket.t.sol` — 24 passing tests (creation, escrow, only-forwarder
  resolution, batch resolution, parimutuel math with fees, invalid/void refunds, claim guards,
  `getResolvableMarkets`).
- `cre/resolver/main.test.ts` — outcome mapping, batch building, and ABI round-trip of the report
  payload against the exact on-chain `Resolution[]` shape.

## Security notes

- This is reference/demo code; have contracts audited before mainnet use.
- The protocol owner can create markets, set the fee (capped at 10%), void stale markets, and
  withdraw accrued fees. Consider a timelock/multisig for production.
- Settlement trust reduces to the CRE DON + the configured data source. Use a reputable,
  deterministic results feed and the production `KeystoneForwarder`.
- Never commit real keys. `cre/.env`, `frontend/.env.local` are git-ignored.

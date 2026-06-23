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

Safety properties enforced by the contract:

- Bets rejected at/after the trading deadline and once resolved.
- A market whose **winning side has zero stake** auto-voids → both sides refundable.
- `Invalid` outcome → full refunds, no fee.
- `voidMarket()` owner safety valve if the oracle never resolves (only 7 days past `resolveTime`).
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

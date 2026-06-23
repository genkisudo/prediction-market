"use client";

import { useReadContract } from "wagmi";
import { ConnectButton } from "@/components/ConnectButton";
import { CreateMarket } from "@/components/CreateMarket";
import { MarketCard } from "@/components/MarketCard";
import { predictionMarket } from "@/lib/contract";

const NOT_CONFIGURED = predictionMarket.address === "0x0000000000000000000000000000000000000000";

export default function Home() {
  const { data: count, refetch } = useReadContract({
    ...predictionMarket,
    functionName: "marketCount",
    query: { enabled: !NOT_CONFIGURED },
  });

  const total = count ? Number(count as bigint) : 0;
  const ids = Array.from({ length: total }, (_, i) => BigInt(total - i)); // newest first

  return (
    <main className="shell">
      <div className="topbar">
        <div className="brand">
          <div className="brand-mark">⚽</div>
          <div>
            <h1>WorldCup Markets</h1>
            <p>Trade YES/NO on World Cup outcomes · settled onchain</p>
          </div>
        </div>
        <ConnectButton />
      </div>

      <div className="oracle-badge">
        <span className="dot" /> Resolved automatically by Chainlink CRE — no manual settlement
      </div>

      {NOT_CONFIGURED ? (
        <div className="notice" style={{ marginTop: 28 }}>
          <strong>Set the contract address to go live.</strong>
          <br />
          Deploy <code>PredictionMarket</code> to Sepolia, then create{" "}
          <code>frontend/.env.local</code> with:
          <pre style={{ marginTop: 10 }}>
            <code>NEXT_PUBLIC_MARKET_ADDRESS=0xYourDeployedAddress</code>
          </pre>
          See the project README for the full deploy + CRE resolver setup.
        </div>
      ) : (
        <>
          <div className="section-title">Create a market</div>
          <CreateMarket onCreated={() => refetch()} />

          <div className="section-title">
            Markets {total > 0 ? `(${total})` : ""}
          </div>
          {total === 0 ? (
            <p className="muted">No markets yet. If you are the owner, create one above.</p>
          ) : (
            <div className="grid">
              {ids.map((id) => (
                <MarketCard key={id.toString()} marketId={id} />
              ))}
            </div>
          )}
        </>
      )}
    </main>
  );
}

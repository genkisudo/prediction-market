"use client";

import { useEffect, useState } from "react";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { predictionMarket } from "@/lib/contract";

/** Owner-only market creation panel. Renders nothing for non-owners. */
export function CreateMarket({ onCreated }: { onCreated?: () => void }) {
  const { address } = useAccount();
  const [question, setQuestion] = useState("Will Ronaldo win his first World Cup?");
  const [eventId, setEventId] = useState("wc2026-ronaldo-champion");
  const [tradingMins, setTradingMins] = useState("60");
  const [resolveMins, setResolveMins] = useState("120");
  const [err, setErr] = useState<string | null>(null);

  const { data: owner } = useReadContract({ ...predictionMarket, functionName: "owner" });
  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess: mined } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (mined) {
      onCreated?.();
      reset();
    }
  }, [mined, onCreated, reset]);

  const isOwner =
    address && owner && address.toLowerCase() === (owner as string).toLowerCase();
  if (!isOwner) return null;

  function create() {
    setErr(null);
    const now = Math.floor(Date.now() / 1000);
    const trading = BigInt(now + Number(tradingMins) * 60);
    const resolve = BigInt(now + Number(resolveMins) * 60);
    writeContract(
      {
        ...predictionMarket,
        functionName: "createMarket",
        args: [question, eventId, trading, resolve],
      },
      { onError: (e) => setErr(e.message.split("\n")[0]) },
    );
  }

  const busy = isPending || isMining;

  return (
    <div className="create">
      <div>
        <label>Question</label>
        <input value={question} onChange={(e) => setQuestion(e.target.value)} />
      </div>
      <div>
        <label>Oracle event id (resolved by the CRE workflow)</label>
        <input value={eventId} onChange={(e) => setEventId(e.target.value)} />
      </div>
      <div className="row">
        <div>
          <label>Trading closes in (minutes)</label>
          <input value={tradingMins} onChange={(e) => setTradingMins(e.target.value)} />
        </div>
        <div>
          <label>Resolvable after (minutes)</label>
          <input value={resolveMins} onChange={(e) => setResolveMins(e.target.value)} />
        </div>
      </div>
      <button className="btn btn-accent" onClick={create} disabled={busy}>
        {busy ? "Creating…" : "Create market"}
      </button>
      {err && <span className="error">{err}</span>}
    </div>
  );
}

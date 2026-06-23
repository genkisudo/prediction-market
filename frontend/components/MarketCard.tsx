"use client";

import { useEffect, useMemo, useState } from "react";
import { formatEther, parseEther } from "viem";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { Outcome, outcomeLabel, predictionMarket } from "@/lib/contract";

type MarketTuple = readonly [
  string, // question
  string, // eventId
  bigint, // tradingDeadline
  bigint, // resolveTime
  number, // outcome
  boolean, // resolved
  bigint, // totalYes
  bigint, // totalNo
];

function fmt(wei: bigint) {
  const eth = Number(formatEther(wei));
  return eth.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

function timeLeft(deadline: bigint) {
  const secs = Number(deadline) - Math.floor(Date.now() / 1000);
  if (secs <= 0) return "closed";
  const h = Math.floor(secs / 3600);
  const d = Math.floor(h / 24);
  if (d > 0) return `${d}d ${h % 24}h`;
  const m = Math.floor((secs % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

export function MarketCard({ marketId }: { marketId: bigint }) {
  const { address } = useAccount();
  const [amount, setAmount] = useState("0.01");
  const [err, setErr] = useState<string | null>(null);

  const { data, refetch } = useReadContract({
    ...predictionMarket,
    functionName: "getMarket",
    args: [marketId],
  });

  const { data: position, refetch: refetchPosition } = useReadContract({
    ...predictionMarket,
    functionName: "getPosition",
    args: address ? [marketId, address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { data: payout, refetch: refetchPayout } = useReadContract({
    ...predictionMarket,
    functionName: "previewPayout",
    args: address ? [marketId, address] : undefined,
    query: { enabled: Boolean(address) },
  });

  const { writeContract, data: txHash, isPending, reset } = useWriteContract();
  const { isLoading: isMining, isSuccess: mined } = useWaitForTransactionReceipt({ hash: txHash });

  useEffect(() => {
    if (mined) {
      refetch();
      refetchPosition();
      refetchPayout();
      reset();
    }
  }, [mined, refetch, refetchPosition, refetchPayout, reset]);

  const m = data as MarketTuple | undefined;

  const view = useMemo(() => {
    if (!m) return null;
    const [question, , tradingDeadline, resolveTime, outcome, resolved, totalYes, totalNo] = m;
    const pool = totalYes + totalNo;
    const yesPct = pool > 0n ? Number((totalYes * 1000n) / pool) / 10 : 50;
    const noPct = 100 - yesPct;
    const open = !resolved && Number(tradingDeadline) > Math.floor(Date.now() / 1000);
    return { question, tradingDeadline, resolveTime, outcome, resolved, totalYes, totalNo, pool, yesPct, noPct, open };
  }, [m]);

  if (!view) return <div className="card muted">Loading market #{marketId.toString()}…</div>;

  const busy = isPending || isMining;

  function bet(isYes: boolean) {
    setErr(null);
    let value: bigint;
    try {
      value = parseEther(amount || "0");
    } catch {
      setErr("Invalid amount");
      return;
    }
    if (value <= 0n) {
      setErr("Enter an amount > 0");
      return;
    }
    writeContract(
      {
        ...predictionMarket,
        functionName: isYes ? "betYes" : "betNo",
        args: [marketId],
        value,
      },
      { onError: (e) => setErr(e.message.split("\n")[0]) },
    );
  }

  function claim() {
    setErr(null);
    writeContract(
      { ...predictionMarket, functionName: "claim", args: [marketId] },
      { onError: (e) => setErr(e.message.split("\n")[0]) },
    );
  }

  const yes = position ? (position as readonly [bigint, bigint, boolean])[0] : 0n;
  const no = position ? (position as readonly [bigint, bigint, boolean])[1] : 0n;
  const hasClaimed = position ? (position as readonly [bigint, bigint, boolean])[2] : false;
  const claimable = (payout as bigint | undefined) ?? 0n;

  let pill = { cls: "pill-open", text: `Closes in ${timeLeft(view.tradingDeadline)}` };
  if (view.resolved) {
    if (view.outcome === Outcome.Yes) pill = { cls: "pill-yes", text: "YES won" };
    else if (view.outcome === Outcome.No) pill = { cls: "pill-no", text: "NO won" };
    else pill = { cls: "pill-void", text: "Voided" };
  } else if (!view.open) {
    pill = { cls: "pill-void", text: "Awaiting oracle" };
  }

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-q">{view.question}</div>
        <span className={`pill ${pill.cls}`}>{pill.text}</span>
      </div>

      <div className="odds" title={`YES ${view.yesPct.toFixed(1)}% · NO ${view.noPct.toFixed(1)}%`}>
        <div className="yes" style={{ width: `${view.yesPct}%` }}>
          YES {view.yesPct.toFixed(0)}%
        </div>
        <div className="no" style={{ width: `${view.noPct}%` }}>
          {view.noPct.toFixed(0)}% NO
        </div>
      </div>

      <div className="meta">
        <span>
          Pool <b>{fmt(view.pool)} ETH</b>
        </span>
        <span>
          YES <b>{fmt(view.totalYes)}</b>
        </span>
        <span>
          NO <b>{fmt(view.totalNo)}</b>
        </span>
        {view.resolved && <span>{outcomeLabel[view.outcome]}</span>}
      </div>

      {view.open && (
        <div className="trade">
          <input
            type="number"
            min="0"
            step="0.01"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="ETH"
            disabled={busy}
          />
          <button className="btn-yes" onClick={() => bet(true)} disabled={busy || !address}>
            Buy YES
          </button>
          <button className="btn-no" onClick={() => bet(false)} disabled={busy || !address}>
            Buy NO
          </button>
        </div>
      )}

      {address && (yes > 0n || no > 0n) && (
        <div className="position">
          <span>
            Your stake — YES <b>{fmt(yes)}</b> · NO <b>{fmt(no)}</b>
          </span>
          {view.resolved && !hasClaimed && claimable > 0n && (
            <>
              <span className="win">Claimable: {fmt(claimable)} ETH</span>
              <button className="btn btn-accent" onClick={claim} disabled={busy}>
                {busy ? "Claiming…" : "Claim winnings"}
              </button>
            </>
          )}
          {hasClaimed && <span>Claimed ✓</span>}
        </div>
      )}

      {busy && <span className="muted">Confirming transaction…</span>}
      {mined && <span className="tx">Confirmed ✓</span>}
      {err && <span className="error">{err}</span>}
    </div>
  );
}

"use client";

import { useAccount, useConnect, useDisconnect } from "wagmi";

function short(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export function ConnectButton() {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (isConnected && address) {
    return (
      <button className="btn" onClick={() => disconnect()}>
        {short(address)}
      </button>
    );
  }

  const injected = connectors[0];
  return (
    <button
      className="btn btn-accent"
      disabled={!injected || isPending}
      onClick={() => injected && connect({ connector: injected })}
    >
      {isPending ? "Connecting…" : "Connect Wallet"}
    </button>
  );
}

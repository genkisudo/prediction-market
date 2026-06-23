#!/usr/bin/env node
// Mock sports-results oracle data source.
//
// Stands in for a real verifiable match-result feed (e.g. football-data.org /
// API-Football) during development and CRE simulation. The CRE resolver workflow
// performs an HTTP GET against `/results/:eventId` on every DON node and reaches
// consensus on the response. Swap the base URL + add an API key (CRE secret) to
// point at a real provider — the response shape is all the workflow depends on.
//
//   GET  /results/:eventId  -> { eventId, status, outcome, title, source, settledAt }
//   GET  /results           -> all known events
//   POST /results/:eventId  -> { status, outcome } to update an event (demo only)
//   GET  /health            -> { ok: true }
//
//   status:  "SETTLED" | "PENDING"
//   outcome: "YES" | "NO" | "INVALID" | null   (null while PENDING)
//
// Usage: node server.mjs   (PORT env, default 8888)

import { createServer } from "node:http";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const DATA_FILE = join(__dirname, "events.json");
const PORT = Number(process.env.PORT ?? 8888);

const VALID_OUTCOMES = new Set(["YES", "NO", "INVALID", null]);

function load() {
  if (!existsSync(DATA_FILE)) return {};
  return JSON.parse(readFileSync(DATA_FILE, "utf8"));
}
function save(events) {
  writeFileSync(DATA_FILE, JSON.stringify(events, null, 2));
}

function send(res, code, body) {
  const payload = JSON.stringify(body);
  res.writeHead(code, {
    "content-type": "application/json",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function resultFor(events, eventId) {
  const e = events[eventId];
  if (!e) {
    // Unknown events resolve as PENDING so the oracle simply skips them.
    return { eventId, status: "PENDING", outcome: null, title: null, source: null, settledAt: null };
  }
  return {
    eventId,
    status: e.status,
    outcome: e.outcome ?? null,
    title: e.title ?? null,
    source: e.source ?? null,
    settledAt: e.settledAt ?? null,
  };
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const parts = url.pathname.split("/").filter(Boolean);

  if (req.method === "GET" && url.pathname === "/health") {
    return send(res, 200, { ok: true });
  }

  // /results
  if (parts[0] === "results") {
    const events = load();

    if (req.method === "GET" && parts.length === 1) {
      return send(res, 200, Object.keys(events).map((id) => resultFor(events, id)));
    }

    if (req.method === "GET" && parts.length === 2) {
      return send(res, 200, resultFor(events, decodeURIComponent(parts[1])));
    }

    if (req.method === "POST" && parts.length === 2) {
      let raw = "";
      req.on("data", (c) => (raw += c));
      req.on("end", () => {
        let body;
        try {
          body = JSON.parse(raw || "{}");
        } catch {
          return send(res, 400, { error: "invalid JSON" });
        }
        if (body.outcome !== undefined && !VALID_OUTCOMES.has(body.outcome)) {
          return send(res, 400, { error: "outcome must be YES, NO, INVALID or null" });
        }
        const id = decodeURIComponent(parts[1]);
        const existing = events[id] ?? {};
        events[id] = {
          ...existing,
          status: body.status ?? existing.status ?? "PENDING",
          outcome: body.outcome ?? existing.outcome ?? null,
          title: body.title ?? existing.title ?? null,
          settledAt:
            (body.status ?? existing.status) === "SETTLED"
              ? body.settledAt ?? new Date().toISOString()
              : null,
        };
        save(events);
        return send(res, 200, resultFor(events, id));
      });
      return;
    }
  }

  send(res, 404, { error: "not found" });
});

server.listen(PORT, () => {
  console.log(`[mock-api] sports-results oracle source on http://localhost:${PORT}`);
  console.log(`[mock-api] try: curl http://localhost:${PORT}/results/wc2026-ronaldo-champion`);
});

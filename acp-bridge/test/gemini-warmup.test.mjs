// Harness for prewarmGeminiSession — the eager warmup that creates + caches a
// gemini-cli session so the first user query reuses it instead of paying
// session/new + MCP spin-up on the visible turn. Gemini Flash is the default
// model for new users, so this is the path that makes the first onboarding /
// floating-bar message warm.
//
// Run with:  npm test   (from acp-bridge/)  — builds first, then node --test.
// Imports the COMPILED module so the test exercises exactly what ships.

import test from "node:test";
import assert from "node:assert/strict";
import {
  prewarmGeminiSession,
  handleGeminiQuery,
  geminiSessionCount,
  clearGeminiSessions,
} from "../dist/gemini-query.js";

// Minimal GeminiProvider stand-in. Records calls; start/initialize/authenticate
// must be idempotent (the real provider's are), and request() fakes the ACP
// round-trips prewarmGeminiSession / handleGeminiQuery make.
function makeProvider(opts = {}) {
  let newCount = 0;
  return {
    calls: [],
    started: 0,
    initialized: 0,
    authenticated: 0,
    get newCount() {
      return newCount;
    },
    start() {
      this.started++;
    },
    async initialize() {
      this.initialized++;
      return {};
    },
    async authenticate() {
      this.authenticated++;
    },
    async request(method, params) {
      this.calls.push({ method, params });
      if (method === "session/new") {
        newCount++;
        return { sessionId: `sid-${newCount}` };
      }
      if (method === "session/load") {
        if (opts.loadFails) throw new Error("session/load: resource not found");
        return {};
      }
      if (method === "session/prompt") return { stopReason: "end_turn", _meta: {} };
      return {};
    },
    registerSessionHandler() {},
    unregisterSessionHandler() {},
    beginActivePrompt() {},
    endActivePrompt() {},
    getRecentTurnError() {
      return null;
    },
    notify() {},
  };
}

function makeDeps(provider, sink) {
  return {
    logErr: () => {},
    send: (m) => sink.sent.push(m),
    sendWithSession: (sessionId, m) => sink.sentWith.push({ sessionId, ...m }),
    getProvider: () => provider,
    buildMcpServers: () => [{ name: "fazm" }],
    registerSession: (key, entry) => sink.registered.push({ key, ...entry }),
  };
}

const newSink = () => ({ sent: [], sentWith: [], registered: [] });

test("prewarm creates + caches a session, wires MCP + system prompt, emits session_started", async () => {
  clearGeminiSessions();
  const provider = makeProvider();
  const sink = newSink();
  await prewarmGeminiSession(
    { key: "main", model: "gemini-flash-latest", systemPrompt: "SP" },
    "/cwd",
    makeDeps(provider, sink),
  );

  assert.equal(provider.started, 1, "provider started");
  assert.equal(provider.initialized, 1, "provider initialized");
  assert.equal(provider.authenticated, 1, "provider authenticated");
  assert.equal(provider.newCount, 1, "exactly one session/new");

  const newCall = provider.calls.find((c) => c.method === "session/new");
  assert.equal(newCall.params.cwd, "/cwd", "session/new carries warm cwd");
  assert.ok(Array.isArray(newCall.params.mcpServers), "session/new carries MCP servers");
  assert.equal(newCall.params._meta.systemPrompt, "SP", "session/new carries system prompt");

  // Registered under the gemini provider so the shared session map routes right.
  assert.deepEqual(sink.registered.at(-1), {
    key: "main",
    sessionId: "sid-1",
    cwd: "/cwd",
    model: "gemini-flash-latest",
    provider: "gemini",
  });
  // session_started so Swift banks the sessionId for resume (parity with Claude warmup).
  assert.ok(
    sink.sentWith.some(
      (m) => m.type === "session_started" && m.sessionKey === "main" && m.isResume === false,
    ),
    "session_started emitted",
  );
  assert.equal(geminiSessionCount(), 1);
});

test("first query after warmup reuses the warm session (no second session/new)", async () => {
  clearGeminiSessions();
  const provider = makeProvider();
  const deps = makeDeps(provider, newSink());
  await prewarmGeminiSession(
    { key: "main", model: "gemini-flash-latest", systemPrompt: "SP" },
    "/cwd",
    deps,
  );
  assert.equal(provider.newCount, 1);

  await handleGeminiQuery(
    { sessionKey: "main", model: "gemini-flash-latest", cwd: "/cwd", prompt: "hello", systemPrompt: "SP" },
    deps,
  );

  assert.equal(provider.newCount, 1, "warm session reused — no cold session/new on the visible turn");
  assert.equal(geminiSessionCount(), 1);
  assert.ok(
    provider.calls.some((c) => c.method === "session/prompt" && c.params.sessionId === "sid-1"),
    "prompt ran on the warm session id",
  );
});

test("warmup is idempotent for the same key + cwd + model", async () => {
  clearGeminiSessions();
  const provider = makeProvider();
  const deps = makeDeps(provider, newSink());
  await prewarmGeminiSession({ key: "floating", model: "gemini-flash-latest" }, "/cwd", deps);
  await prewarmGeminiSession({ key: "floating", model: "gemini-flash-latest" }, "/cwd", deps);
  assert.equal(provider.newCount, 1, "second warmup of an already-warm key is a no-op");
  assert.equal(geminiSessionCount(), 1);
});

test("warmup resume falls back to a fresh session when session/load fails", async () => {
  clearGeminiSessions();
  const provider = makeProvider({ loadFails: true });
  await prewarmGeminiSession(
    { key: "main", model: "gemini-flash-latest", resume: "old-sid", systemPrompt: "SP" },
    "/cwd",
    makeDeps(provider, newSink()),
  );
  assert.ok(provider.calls.some((c) => c.method === "session/load"), "load attempted");
  assert.equal(provider.newCount, 1, "fell back to a fresh session/new");
  assert.equal(geminiSessionCount(), 1);
});

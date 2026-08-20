// Approval gate ("cage mode") unit tests — the shared module that gates
// session/request_permission behind an explicit user decision when
// FAZM_APPROVAL_MODE is destructive/always, and auto-approves otherwise.
//
// Run with:  npm test   (from acp-bridge/)  — builds first, then node --test.
// Imports the COMPILED module so the test exercises exactly what ships.

import test from "node:test";
import assert from "node:assert/strict";
import {
  ApprovalGate,
  currentApprovalMode,
  shouldGate,
  defaultAllowOptionId,
} from "../dist/approval-gate.js";

const OPTIONS = [
  { optionId: "allow-once", kind: "allow_once", name: "Allow" },
  { optionId: "allow-always", kind: "allow_always", name: "Always allow" },
  { optionId: "reject-once", kind: "reject_once", name: "Deny" },
];

function makeParams(kind, overrides = {}) {
  return {
    sessionId: "sess-1",
    toolCall: { toolCallId: "tc-1", title: "Run `rm -rf /tmp/x`", kind },
    options: OPTIONS,
    ...overrides,
  };
}

function makeGate({ mode = "destructive", timeoutMs = 60_000 } = {}) {
  const events = [];
  const gate = new ApprovalGate({
    emit: (msg, sessionId) => events.push({ ...msg, sessionId }),
    logErr: () => {},
    timeoutMs,
    getMode: () => mode,
  });
  return { gate, events };
}

// --- mode parsing --------------------------------------------------------

test("currentApprovalMode: unset/garbage → off; valid values pass through", () => {
  assert.equal(currentApprovalMode({}), "off");
  assert.equal(currentApprovalMode({ FAZM_APPROVAL_MODE: "" }), "off");
  assert.equal(currentApprovalMode({ FAZM_APPROVAL_MODE: "banana" }), "off");
  assert.equal(currentApprovalMode({ FAZM_APPROVAL_MODE: "destructive" }), "destructive");
  assert.equal(currentApprovalMode({ FAZM_APPROVAL_MODE: "always" }), "always");
});

test("shouldGate: destructive gates only edit/delete/move/execute", () => {
  for (const kind of ["edit", "delete", "move", "execute"]) {
    assert.equal(shouldGate("destructive", kind), true, kind);
  }
  for (const kind of ["read", "search", "fetch", "think", "other", undefined]) {
    assert.equal(shouldGate("destructive", kind), false, String(kind));
  }
  assert.equal(shouldGate("always", "read"), true);
  assert.equal(shouldGate("always", undefined), true);
  assert.equal(shouldGate("off", "execute"), false);
});

test("defaultAllowOptionId prefers allow_always, then allow_once, then first, then 'allow'", () => {
  assert.equal(defaultAllowOptionId(OPTIONS), "allow-always");
  assert.equal(defaultAllowOptionId([OPTIONS[0], OPTIONS[2]]), "allow-once");
  assert.equal(defaultAllowOptionId([OPTIONS[2]]), "reject-once");
  assert.equal(defaultAllowOptionId([]), "allow");
});

// --- auto-approve paths --------------------------------------------------

test("mode=off auto-approves destructive kinds immediately (today's behavior)", () => {
  const { gate, events } = makeGate({ mode: "off" });
  let reply = null;
  gate.handleRequest("claude", 7, makeParams("execute"), (r) => { reply = r; });
  assert.deepEqual(reply, { outcome: { outcome: "selected", optionId: "allow-always" } });
  assert.equal(events.length, 0);
  assert.equal(gate.pendingCount, 0);
});

test("mode=destructive auto-approves read/search/etc. without emitting events", () => {
  const { gate, events } = makeGate();
  const replies = [];
  for (const kind of ["read", "search", "fetch", "think", "other"]) {
    gate.handleRequest("claude", kind, makeParams(kind), (r) => replies.push(r));
  }
  assert.equal(replies.length, 5);
  for (const r of replies) assert.equal(r.outcome.outcome, "selected");
  assert.equal(events.length, 0);
});

test("missing toolCall kind is auto-approved in destructive mode", () => {
  const { gate, events } = makeGate();
  let reply = null;
  gate.handleRequest("claude", 1, makeParams(undefined), (r) => { reply = r; });
  assert.equal(reply.outcome.outcome, "selected");
  assert.equal(events.length, 0);
});

test("malformed params (no toolCall, no options) auto-approve with 'allow' fallback", () => {
  const { gate } = makeGate({ mode: "off" });
  let reply = null;
  gate.handleRequest("claude", 1, undefined, (r) => { reply = r; });
  assert.deepEqual(reply, { outcome: { outcome: "selected", optionId: "allow" } });
});

// --- gating round-trip ---------------------------------------------------

test("destructive kind is gated: no reply until permission_response selects an option", () => {
  const { gate, events } = makeGate();
  let reply = null;
  gate.handleRequest("claude", 42, makeParams("execute"), (r) => { reply = r; });

  assert.equal(reply, null, "must NOT reply while gated");
  assert.equal(gate.pendingCount, 1);
  assert.equal(events.length, 1);
  const evt = events[0];
  assert.equal(evt.type, "permission_request");
  assert.equal(evt.toolCallId, "tc-1");
  assert.equal(evt.title, "Run `rm -rf /tmp/x`");
  assert.equal(evt.kind, "execute");
  assert.equal(evt.sessionId, "sess-1");
  assert.deepEqual(evt.options, OPTIONS);

  const handled = gate.handleResponse(evt.id, "allow-once", undefined);
  assert.equal(handled, true);
  assert.deepEqual(reply, { outcome: { outcome: "selected", optionId: "allow-once" } });
  assert.equal(gate.pendingCount, 0);
});

test("permission_response with cancelled:true replies cancelled", () => {
  const { gate, events } = makeGate();
  let reply = null;
  gate.handleRequest("claude", 1, makeParams("delete"), (r) => { reply = r; });
  gate.handleResponse(events[0].id, undefined, true);
  assert.deepEqual(reply, { outcome: { outcome: "cancelled" } });
});

test("mode=always gates a read request too", () => {
  const { gate, events } = makeGate({ mode: "always" });
  let reply = null;
  gate.handleRequest("claude", 1, makeParams("read"), (r) => { reply = r; });
  assert.equal(reply, null);
  assert.equal(events[0].kind, "read");
});

test("gate ids are unique across providers even with colliding JSON-RPC ids", () => {
  const { gate, events } = makeGate();
  gate.handleRequest("claude", 5, makeParams("execute"), () => {});
  gate.handleRequest("codex", 5, makeParams("edit"), () => {});
  assert.equal(gate.pendingCount, 2);
  assert.notEqual(events[0].id, events[1].id);
});

test("unknown/expired response id is ignored (double-answer safe)", () => {
  const { gate, events } = makeGate();
  let replies = 0;
  gate.handleRequest("claude", 1, makeParams("execute"), () => { replies++; });
  const id = events[0].id;
  assert.equal(gate.handleResponse(id, "allow-once", undefined), true);
  assert.equal(gate.handleResponse(id, "allow-once", undefined), false, "second answer ignored");
  assert.equal(gate.handleResponse("bogus", "allow-once", undefined), false);
  assert.equal(replies, 1, "reply must fire exactly once");
});

// --- timeout & flush -----------------------------------------------------

test("timeout replies cancelled and emits permission_timeout", async () => {
  const { gate, events } = makeGate({ timeoutMs: 30 });
  let reply = null;
  gate.handleRequest("claude", 1, makeParams("execute"), (r) => { reply = r; });
  await new Promise((r) => setTimeout(r, 80));
  assert.deepEqual(reply, { outcome: { outcome: "cancelled" } });
  assert.equal(gate.pendingCount, 0);
  const timeoutEvt = events.find((e) => e.type === "permission_timeout");
  assert.ok(timeoutEvt, "permission_timeout event emitted");
  assert.equal(timeoutEvt.id, events[0].id);
  assert.equal(timeoutEvt.reason, "timeout");
  // A late user answer after the timeout must be a no-op.
  assert.equal(gate.handleResponse(events[0].id, "allow-once", undefined), false);
});

test("cancelForSession flushes only that session's gates", () => {
  const { gate, events } = makeGate();
  const replies = { a: null, b: null };
  gate.handleRequest("claude", 1, makeParams("execute", { sessionId: "sess-A" }), (r) => { replies.a = r; });
  gate.handleRequest("claude", 2, makeParams("execute", { sessionId: "sess-B" }), (r) => { replies.b = r; });

  const n = gate.cancelForSession("sess-A", "interrupted");
  assert.equal(n, 1);
  assert.deepEqual(replies.a, { outcome: { outcome: "cancelled" } });
  assert.equal(replies.b, null, "other session's gate stays pending");
  assert.equal(gate.pendingCount, 1);
  const timeoutEvts = events.filter((e) => e.type === "permission_timeout");
  assert.equal(timeoutEvts.length, 1);
  assert.equal(timeoutEvts[0].reason, "interrupted");
});

test("cancelAll flushes everything as cancelled (shutdown must never hang)", () => {
  const { gate } = makeGate();
  const replies = [];
  gate.handleRequest("claude", 1, makeParams("execute"), (r) => replies.push(r));
  gate.handleRequest("codex", 2, makeParams("edit", { sessionId: "sess-2" }), (r) => replies.push(r));
  gate.handleRequest("gemini", 3, makeParams("delete", { sessionId: undefined }), (r) => replies.push(r));

  const n = gate.cancelAll("bridge restarting");
  assert.equal(n, 3);
  assert.equal(gate.pendingCount, 0);
  for (const r of replies) assert.deepEqual(r, { outcome: { outcome: "cancelled" } });
});

test("firstPendingTitle exposes the parked request for diagnostics", () => {
  const { gate } = makeGate();
  assert.equal(gate.firstPendingTitle, undefined);
  gate.handleRequest("claude", 1, makeParams("execute"), () => {});
  assert.equal(gate.firstPendingTitle, "Run `rm -rf /tmp/x`");
  gate.cancelAll("test");
  assert.equal(gate.firstPendingTitle, undefined);
});

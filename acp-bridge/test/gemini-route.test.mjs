// Harness for decideGeminiRoute — the helper that decides whether an inbound
// gemini-cli notification routes directly to its session handler, gets rescued
// to the single in-flight prompt (gemini-cli 0.42.0 emits session/update under
// a mismatched sessionId on resumed/switched sessions, dropping assistant text
// -> empty turns), or is left unrouted.
//
// Run with:  npm test   (from acp-bridge/)  — builds first, then node --test.
// Imports the COMPILED module so the test exercises exactly what ships.

import test from "node:test";
import assert from "node:assert/strict";
import { decideGeminiRoute } from "../dist/gemini-provider.js";

const has = (...ids) => (id) => ids.includes(id);

test("matched sessionId routes directly", () => {
  const d = decideGeminiRoute({
    updateSessionId: "A",
    hasHandler: has("A"),
    activePromptSessionIds: new Set(["A"]),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "direct", sessionId: "A" });
});

test("mismatched session/update with exactly one in-flight prompt is rescued to it", () => {
  // The core bug: gemini-cli streams under id "B" but our handler is keyed on
  // "A" (the id session/new returned). Without rescue the text is dropped.
  const d = decideGeminiRoute({
    updateSessionId: "B",
    hasHandler: has("A"),
    activePromptSessionIds: new Set(["A"]),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "rescue", sessionId: "A" });
});

test("undefined sessionId with one in-flight prompt is rescued (don't drop text)", () => {
  const d = decideGeminiRoute({
    updateSessionId: undefined,
    hasHandler: has("A"),
    activePromptSessionIds: new Set(["A"]),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "rescue", sessionId: "A" });
});

test("mismatched update with NO in-flight prompt stays unrouted (late/dead-session updates)", () => {
  const d = decideGeminiRoute({
    updateSessionId: "B",
    hasHandler: has("A"),
    activePromptSessionIds: new Set(),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "unrouted" });
});

test("mismatched update with TWO in-flight prompts stays unrouted (ambiguous, never misattribute)", () => {
  const d = decideGeminiRoute({
    updateSessionId: "C",
    hasHandler: has("A", "B"),
    activePromptSessionIds: new Set(["A", "B"]),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "unrouted" });
});

test("non-session/update notifications are never rescued", () => {
  // e.g. an early available_commands_update before the handler is registered —
  // benign, must not be force-fed into the active prompt's translator.
  const d = decideGeminiRoute({
    updateSessionId: "B",
    hasHandler: has("A"),
    activePromptSessionIds: new Set(["A"]),
    isSessionUpdate: false,
  });
  assert.deepEqual(d, { kind: "unrouted" });
});

test("rescue is skipped when the active prompt's handler was already torn down", () => {
  const d = decideGeminiRoute({
    updateSessionId: "B",
    hasHandler: has("Z"), // active id "A" no longer has a handler
    activePromptSessionIds: new Set(["A"]),
    isSessionUpdate: true,
  });
  assert.deepEqual(d, { kind: "unrouted" });
});

// Harness for the inherited-MCP health gate. A dead inherited server used to
// block gemini-cli `session/new` for 75s; the gate must report it unusable
// quickly and without blocking the caller.
//
// Run with:  npm test   (from acp-bridge/)  — builds first, then node --test.
// Imports the COMPILED module so the test exercises exactly what ships.

import test from "node:test";
import assert from "node:assert/strict";
import {
  probeStdioMcp,
  isInheritedMcpUsable,
  awaitInheritedMcpProbes,
  _resetMcpHealthForTests,
} from "../dist/mcp-health.js";

const node = process.execPath;

const healthy = {
  name: "healthy",
  command: node,
  args: [
    "-e",
    `process.stdin.on("data", (d) => {
       const m = JSON.parse(String(d).trim().split("\\n")[0]);
       process.stdout.write("banner line, not json\\n");
       process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: m.id, result: { capabilities: {} } }) + "\\n");
     });`,
  ],
  env: [],
};
const hangs = { name: "hangs", command: node, args: ["-e", "setInterval(() => {}, 1000)"], env: [] };
const exits = { name: "exits", command: node, args: ["-e", "process.exit(255)"], env: [] };
const missing = { name: "missing", command: "/nonexistent/mcp-server-binary", args: [], env: [] };

test("healthy server answers initialize", async () => {
  const h = await probeStdioMcp(healthy, 5000);
  assert.equal(h.ok, true);
});

test("hung server is reported unhealthy at the timeout, not later", async () => {
  const h = await probeStdioMcp(hangs, 400);
  assert.equal(h.ok, false);
  assert.ok(h.ms >= 380 && h.ms < 2000, `took ${h.ms}ms`);
});

test("server that exits early is unhealthy immediately", async () => {
  const h = await probeStdioMcp(exits, 5000);
  assert.equal(h.ok, false);
  assert.ok(h.ms < 3000, `took ${h.ms}ms`);
});

test("missing binary is unhealthy, not a crash", async () => {
  const h = await probeStdioMcp(missing, 5000);
  assert.equal(h.ok, false);
});

test("gate never blocks: unknown is unusable, then usable once probed", async () => {
  _resetMcpHealthForTests();
  assert.equal(isInheritedMcpUsable(healthy), false);
  await awaitInheritedMcpProbes(5000);
  assert.equal(isInheritedMcpUsable(healthy), true);
});

test("awaitInheritedMcpProbes honors its cap while a probe hangs", async () => {
  _resetMcpHealthForTests();
  isInheritedMcpUsable(hangs);
  const t0 = Date.now();
  await awaitInheritedMcpProbes(300);
  assert.ok(Date.now() - t0 < 1500, `waited ${Date.now() - t0}ms`);
  assert.equal(isInheritedMcpUsable(hangs), false);
});

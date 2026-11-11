/**
 * Health gate for inherited MCP servers (~/.fazm/mcp-servers.json and
 * ~/.claude.json).
 *
 * Why: gemini-cli and codex-acp block `session/new` until every MCP server in
 * the list has either connected or failed. One dead inherited server (for
 * example an ssh wrapper to an unreachable host) held session creation for
 * 75s on every new chat, measured 2026-11-11. Bundled servers start in about
 * 2s combined, so only servers we do not ship need gating.
 *
 * How: each inherited stdio server is spawned once per bridge process and
 * sent an MCP `initialize`. Servers that answer within PROBE_TIMEOUT_MS are
 * usable; the rest are left out of sessions and re-probed in the background
 * after RETRY_AFTER_MS so a recovered server comes back without a restart.
 */

import { spawn } from "child_process";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

export type StdioMcpSpec = {
  name: string;
  command: string;
  args: string[];
  env: Array<{ name: string; value: string }>;
};

export const PROBE_TIMEOUT_MS = 8000;
const RETRY_AFTER_MS = 5 * 60 * 1000;

type Health = { ok: boolean; ms: number; checkedAt: number; reason?: string };

const results = new Map<string, Health>();
const inflight = new Map<string, Promise<Health>>();

let log: (msg: string) => void = () => {};

export function setMcpHealthLogger(fn: (msg: string) => void): void {
  log = fn;
}

function keyOf(spec: StdioMcpSpec): string {
  return JSON.stringify([spec.name, spec.command, spec.args]);
}

/** Spawn the server, send `initialize`, resolve once it answers or gives up. */
export function probeStdioMcp(spec: StdioMcpSpec, timeoutMs = PROBE_TIMEOUT_MS): Promise<Health> {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let settled = false;
    let child: ReturnType<typeof spawn> | null = null;
    const finish = (ok: boolean, reason?: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        child?.kill("SIGTERM");
      } catch {
        // already gone
      }
      resolve({ ok, ms: Date.now() - startedAt, checkedAt: Date.now(), reason });
    };
    const timer = setTimeout(() => finish(false, `no initialize response in ${timeoutMs}ms`), timeoutMs);

    const env: NodeJS.ProcessEnv = { ...process.env };
    for (const { name, value } of spec.env) env[name] = value;

    try {
      child = spawn(spec.command, spec.args, { env, stdio: ["pipe", "pipe", "ignore"] });
    } catch (err) {
      finish(false, `spawn failed: ${err}`);
      return;
    }
    child.on("error", (err) => finish(false, `spawn failed: ${err.message}`));
    child.on("exit", (code) => finish(false, `exited with code ${code} before initialize`));

    let buf = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      buf += chunk.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        try {
          const msg = JSON.parse(line) as { id?: unknown; result?: unknown };
          if (msg.id === 0 && msg.result !== undefined) finish(true);
        } catch {
          // servers may print non-JSON banners on stdout; ignore
        }
      }
    });
    child.stdin?.on("error", () => {
      // EPIPE when the server dies early; the exit handler reports it
    });
    child.stdin?.write(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 0,
        method: "initialize",
        params: {
          protocolVersion: "2025-03-26",
          capabilities: {},
          clientInfo: { name: "fazm-mcp-health", version: "1" },
        },
      }) + "\n",
    );
  });
}

function startProbe(spec: StdioMcpSpec): Promise<Health> {
  const key = keyOf(spec);
  const running = inflight.get(key);
  if (running) return running;
  const p = probeStdioMcp(spec).then((health) => {
    inflight.delete(key);
    results.set(key, health);
    if (health.ok) {
      log(`[mcp-health] "${spec.name}" ok in ${health.ms}ms`);
    } else {
      log(
        `[mcp-health] "${spec.name}" UNHEALTHY (${health.reason}); leaving it out of new sessions, will re-check in ${RETRY_AFTER_MS / 60000}min`,
      );
    }
    return health;
  });
  inflight.set(key, p);
  return p;
}

/**
 * True when the server answered its last probe. Never blocks: an unprobed
 * server starts a probe and reports false until the probe lands, and a failed
 * server is re-probed in the background once RETRY_AFTER_MS has passed.
 */
export function isInheritedMcpUsable(spec: StdioMcpSpec): boolean {
  const health = results.get(keyOf(spec));
  if (!health) {
    void startProbe(spec);
    return false;
  }
  if (!health.ok && Date.now() - health.checkedAt > RETRY_AFTER_MS) {
    void startProbe(spec);
  }
  return health.ok;
}

/**
 * Wait for in-flight probes, but never longer than `maxWaitMs`. Healthy
 * servers answer in under 2s; a server still pending after the cap is simply
 * left out of the session being built and picked up by later ones.
 */
export async function awaitInheritedMcpProbes(maxWaitMs = 3000): Promise<void> {
  if (inflight.size === 0) return;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const cap = new Promise<void>((resolve) => {
    timer = setTimeout(resolve, maxWaitMs);
  });
  await Promise.race([Promise.all([...inflight.values()]).then(() => undefined), cap]);
  if (timer) clearTimeout(timer);
}

type RawServer = {
  type?: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  url?: string;
  enabled?: boolean;
};

function specsFrom(servers: Record<string, RawServer> | undefined): StdioMcpSpec[] {
  const out: StdioMcpSpec[] = [];
  for (const [name, cfg] of Object.entries(servers ?? {})) {
    if (!cfg || cfg.enabled === false || !cfg.command) continue;
    if (cfg.type === "http" || cfg.url) continue;
    out.push({
      name,
      command: cfg.command,
      args: cfg.args || [],
      env: Object.entries(cfg.env ?? {}).map(([k, v]) => ({ name: k, value: String(v) })),
    });
  }
  return out;
}

/** Read the same two config files buildMcpServers inherits from. */
export function listInheritedStdioServers(): StdioMcpSpec[] {
  const specs: StdioMcpSpec[] = [];
  try {
    const p = join(homedir(), ".fazm", "mcp-servers.json");
    if (existsSync(p)) specs.push(...specsFrom(JSON.parse(readFileSync(p, "utf-8"))));
  } catch {
    // buildMcpServers logs parse failures for this file
  }
  if (process.env.FAZM_DISABLE_CLAUDE_CODE_MCP !== "true") {
    try {
      const p = join(homedir(), ".claude.json");
      if (existsSync(p)) {
        const parsed = JSON.parse(readFileSync(p, "utf-8")) as { mcpServers?: Record<string, RawServer> };
        specs.push(...specsFrom(parsed.mcpServers));
      }
    } catch {
      // buildMcpServers logs parse failures for this file
    }
  }
  return specs;
}

/** Kick off probes for every inherited server. Call once at bridge start. */
export function primeInheritedMcpProbes(): void {
  const specs = listInheritedStdioServers();
  if (specs.length === 0) return;
  log(`[mcp-health] probing ${specs.length} inherited MCP server(s): ${specs.map((s) => s.name).join(", ")}`);
  for (const spec of specs) {
    if (!results.has(keyOf(spec))) void startProbe(spec);
  }
}

/** Test hook. */
export function _resetMcpHealthForTests(): void {
  results.clear();
  inflight.clear();
}

/**
 * ACP Bridge — translates between OMI's JSON-lines protocol and the
 * Agent Client Protocol (ACP) used by claude-code-acp.
 *
 * THIS IS THE DESKTOP APP FLOW. It is unrelated to the VM/agent-cloud flow
 * (agent-cloud/agent.mjs), which runs Claude Code SDK on a remote VM for
 * the Omi Agent feature. This bridge runs locally on the user's Mac.
 *
 * Session lifecycle:
 * 1. warmup  → session/new (system prompt applied here, once)
 * 2. query   → session reused; systemPrompt field in the message is ignored
 *              unless the session was invalidated (cwd change → new session/new)
 * 3. The ACP SDK owns conversation history after session/new — do not inject
 *    it into the system prompt.
 *
 * Token counts:
 * session/prompt drives one or more internal Anthropic API calls (initial
 * response + one per tool-use round). The usage returned in the result is
 * the AGGREGATE across all those rounds. There are no separate sub-agents.
 *
 * Implementation flow:
 * 1. Create Unix socket server for omi-tools relay
 * 2. Spawn claude-code-acp as subprocess (JSON-RPC over stdio)
 * 3. Initialize ACP connection
 * 4. Handle auth if required (forward to Swift, wait for user action)
 * 5. On query: reuse or create session, send prompt, translate notifications → JSON-lines
 * 6. On interrupt: cancel the session
 */

import { spawn, execSync, type ChildProcess } from "child_process";
import { createInterface } from "readline";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { createServer as createNetServer, type Socket } from "net";
import { tmpdir } from "os";
import { unlinkSync, appendFileSync, existsSync, watch, mkdirSync } from "fs";
import type {
  InboundMessage,
  OutboundMessage,
  QueryMessage,
  WarmupMessage,
  AuthMethod,
} from "./protocol.js";
import { startOAuthFlow, type OAuthFlowHandle } from "./oauth-flow.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Resolve paths to bundled tools
const playwrightCli = join(
  __dirname,
  "..",
  "node_modules",
  "@playwright",
  "mcp",
  "cli.js"
);

const omiToolsStdioScript = join(__dirname, "omi-tools-stdio.js");

// mcp-server-macos-use binary lives in Contents/MacOS/ alongside the main app binary.
// Node runs from Contents/Resources/Fazm_Fazm.bundle/node, so navigate up to Contents/.
const macosUseBinary = join(
  dirname(process.execPath),
  "..",
  "..",
  "MacOS",
  "mcp-server-macos-use"
);

// --- Helpers ---

function send(msg: OutboundMessage): void {
  try {
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch (err) {
    logErr(`Failed to write to stdout: ${err}`);
  }
}

function logErr(msg: string): void {
  process.stderr.write(`[acp-bridge] ${msg}\n`);
}

// --- OMI tools relay via Unix socket ---

let omiToolsPipePath = "";
let omiToolsClients: Socket[] = [];

// Pending tool call promises — resolved when Swift sends back results
const pendingToolCalls = new Map<
  string,
  { resolve: (result: string) => void }
>();

let currentMode: "ask" | "act" = "act";

/** Resolve a pending tool call with a result from Swift */
function resolveToolCall(msg: { callId: string; result: string }): void {
  const pending = pendingToolCalls.get(msg.callId);
  if (pending) {
    pending.resolve(msg.result);
    pendingToolCalls.delete(msg.callId);
  } else {
    logErr(`Warning: no pending tool call for callId=${msg.callId}`);
  }
}

/** Start Unix socket server for omi-tools stdio processes to connect to */
function startOmiToolsRelay(): Promise<string> {
  const pipePath = join(tmpdir(), `omi-tools-${process.pid}.sock`);

  // Clean up any stale socket
  try {
    unlinkSync(pipePath);
  } catch {
    // ignore
  }

  return new Promise((resolve, reject) => {
    const server = createNetServer((client: Socket) => {
      omiToolsClients.push(client);
      let buffer = "";

      client.on("data", (data: Buffer) => {
        buffer += data.toString();
        let newlineIdx;
        while ((newlineIdx = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, newlineIdx);
          buffer = buffer.slice(newlineIdx + 1);
          if (!line.trim()) continue;

          try {
            const msg = JSON.parse(line) as {
              type: string;
              callId: string;
              name: string;
              input: Record<string, unknown>;
            };

            if (msg.type === "tool_use") {
              // Forward tool call to Swift via stdout
              send({
                type: "tool_use",
                callId: msg.callId,
                name: msg.name,
                input: msg.input,
              });

              // Create a promise that will be resolved when Swift responds
              const callId = msg.callId;
              pendingToolCalls.set(callId, {
                resolve: (result: string) => {
                  // Send result back to the omi-tools stdio process
                  try {
                    client.write(
                      JSON.stringify({
                        type: "tool_result",
                        callId,
                        result,
                      }) + "\n"
                    );
                  } catch (err) {
                    logErr(`Failed to send tool result to omi-tools: ${err}`);
                  }
                },
              });
            }
          } catch {
            logErr(`Failed to parse omi-tools message: ${line.slice(0, 200)}`);
          }
        }
      });

      client.on("close", () => {
        omiToolsClients = omiToolsClients.filter((c) => c !== client);
      });

      client.on("error", (err) => {
        logErr(`omi-tools client error: ${err.message}`);
      });
    });

    server.listen(pipePath, () => {
      logErr(`omi-tools relay socket: ${pipePath}`);
      resolve(pipePath);
    });

    server.on("error", reject);

    // Clean up on exit
    process.on("exit", () => {
      server.close();
      try {
        unlinkSync(pipePath);
      } catch {
        // ignore
      }
    });
  });
}

// --- ACP subprocess management ---

/** Kill the ACP subprocess and its entire process group (MCP servers, etc.) */
function killAcpProcessTree(): void {
  if (!acpProcess) return;
  const pid = acpProcess.pid;
  if (pid) {
    try {
      // Kill the entire process group (negative PID)
      process.kill(-pid, "SIGTERM");
    } catch {
      // Process group may already be dead; try killing just the process
      try {
        acpProcess.kill("SIGTERM");
      } catch {
        // already dead
      }
    }
  } else {
    try {
      acpProcess.kill("SIGTERM");
    } catch {
      // already dead
    }
  }
  acpProcess = null;
}

let acpProcess: ChildProcess | null = null;
let acpStdinWriter: ((line: string) => void) | null = null;
let acpResponseHandlers = new Map<
  number,
  { resolve: (result: unknown) => void; reject: (err: Error) => void }
>();
let acpNotificationHandler: ((method: string, params: unknown) => void) | null =
  null;
let nextRpcId = 1;

/** Send a JSON-RPC request to the ACP subprocess and wait for the response */
async function acpRequest(
  method: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  const id = nextRpcId++;
  const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });

  return new Promise((resolve, reject) => {
    acpResponseHandlers.set(id, { resolve, reject });
    if (acpStdinWriter) {
      acpStdinWriter(msg);
    } else {
      reject(new Error("ACP process stdin not available"));
    }
  });
}

/** Send a JSON-RPC notification (no response expected) to ACP */
function acpNotify(
  method: string,
  params: Record<string, unknown> = {}
): void {
  const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
  if (acpStdinWriter) {
    acpStdinWriter(msg);
  }
}

/** Start the ACP subprocess */
function startAcpProcess(): void {
  // Build environment for ACP subprocess
  // If ANTHROPIC_API_KEY is present (Mode A), keep it so ACP uses OMI's key.
  // If absent (Mode B), ACP will use user's own OAuth.
  const env = { ...process.env };
  // Allow CLAUDE_CODE_USE_VERTEX to flow through when set by Swift (Vertex mode)
  // Remove CLAUDECODE so the ACP subprocess (and the Claude Code it spawns) don't
  // inherit the nested-session guard. Without this, `--resume` silently fails when
  // Claude Code detects it's being launched from inside another Claude Code session.
  delete env.CLAUDECODE;
  env.NODE_NO_WARNINGS = "1";

  // Use our patched ACP entry point (adds model selection support)
  // Located in dist/ (same as __dirname) so it's included in the app bundle
  const acpEntry = join(__dirname, "patched-acp-entry.mjs");
  const nodeBin = process.execPath;

  const mode = env.CLAUDE_CODE_USE_VERTEX ? "Mode C (Vertex AI)" : env.ANTHROPIC_API_KEY ? "Mode A (Omi API key)" : "Mode B (Your Claude Account / OAuth)";
  logErr(`Starting ACP subprocess [${mode}]: ${nodeBin} ${acpEntry}`);

  acpProcess = spawn(nodeBin, [acpEntry], {
    env,
    stdio: ["pipe", "pipe", "pipe"],
    detached: true,
  });

  if (!acpProcess.stdin || !acpProcess.stdout || !acpProcess.stderr) {
    throw new Error("Failed to create ACP subprocess pipes");
  }

  // Write to ACP stdin
  acpStdinWriter = (line: string) => {
    try {
      acpProcess?.stdin?.write(line + "\n");
    } catch (err) {
      logErr(`Failed to write to ACP stdin: ${err}`);
    }
  };

  // Read ACP stdout (JSON-RPC responses and notifications)
  const rl = createInterface({
    input: acpProcess.stdout,
    terminal: false,
  });

  rl.on("line", (line: string) => {
    if (!line.trim()) return;
    try {
      const msg = JSON.parse(line) as Record<string, unknown>;

      if ("method" in msg && "id" in msg && msg.id !== null && msg.id !== undefined) {
        // Server-initiated JSON-RPC request (has both method and id, expects a response)
        const id = msg.id as number;
        const method = msg.method as string;

        if (method === "session/request_permission") {
          // Auto-approve all tool permissions (matches agent-bridge's bypassPermissions behavior)
          const params = msg.params as Record<string, unknown> | undefined;
          const options = (params?.options as Array<{ kind: string; optionId: string }>) ?? [];
          const allowAlways = options.find((o) => o.kind === "allow_always");
          const allowOnce = options.find((o) => o.kind === "allow_once");
          const optionId = allowAlways?.optionId ?? allowOnce?.optionId ?? "allow";
          logErr(`Auto-approving permission for tool (id=${id})`);
          acpStdinWriter?.(JSON.stringify({
            jsonrpc: "2.0",
            id,
            result: { outcome: { outcome: "selected", optionId } },
          }));
        } else if (method === "session/update") {
          // session/update can also arrive as a request (with id) — handle and ack
          if (acpNotificationHandler) {
            acpNotificationHandler(method, msg.params as unknown);
          }
          acpStdinWriter?.(JSON.stringify({ jsonrpc: "2.0", id, result: null }));
        } else {
          logErr(`Unhandled ACP request: ${method} (id=${id})`);
          acpStdinWriter?.(JSON.stringify({
            jsonrpc: "2.0",
            id,
            error: { code: -32601, message: `Method not handled: ${method}` },
          }));
        }
      } else if ("id" in msg && msg.id !== null && msg.id !== undefined) {
        // JSON-RPC response (has id but no method)
        const id = msg.id as number;
        const handler = acpResponseHandlers.get(id);
        if (handler) {
          acpResponseHandlers.delete(id);
          if ("error" in msg) {
            const err = msg.error as {
              code: number;
              message: string;
              data?: unknown;
            };
            const error = new AcpError(err.message, err.code, err.data);
            handler.reject(error);
          } else {
            handler.resolve(msg.result);
          }
        }
      } else if ("method" in msg) {
        // JSON-RPC notification (has method but no id)
        if (acpNotificationHandler) {
          acpNotificationHandler(
            msg.method as string,
            msg.params as unknown
          );
        }
      }
    } catch (err) {
      logErr(`Failed to parse ACP message: ${line.slice(0, 200)}`);
    }
  });

  // Read ACP stderr for logging
  acpProcess.stderr.on("data", (data: Buffer) => {
    const text = data.toString().trim();
    if (text) {
      logErr(`ACP stderr: ${text}`);
    }
  });

  acpProcess.on("exit", (code) => {
    logErr(`ACP process exited with code ${code}`);
    acpProcess = null;
    acpStdinWriter = null;
    // All sessions are lost when ACP process dies
    sessions.clear();
    activeSessionId = "";
    isInitialized = false;
    for (const [, handler] of acpResponseHandlers) {
      handler.reject(new Error(`ACP process exited (code ${code})`));
    }
    acpResponseHandlers.clear();
  });
}

class AcpError extends Error {
  code: number;
  data?: unknown;
  constructor(message: string, code: number, data?: unknown) {
    super(message);
    this.code = code;
    this.data = data;
  }
}

// --- Screenshot auto-resize ---
// Playwright on Retina Macs produces screenshots >2000px which hit Claude's
// multi-image dimension limit. Watch /tmp/playwright-mcp/ and resize in-place.
const PLAYWRIGHT_OUTPUT_DIR = "/tmp/playwright-mcp";
const MAX_SCREENSHOT_DIM = 1920; // stay under 2000px API limit

function startScreenshotResizeWatcher(): void {

  try {
    mkdirSync(PLAYWRIGHT_OUTPUT_DIR, { recursive: true });
  } catch { /* ignore */ }

  // Track files we've already resized to avoid double-processing
  const resized = new Set<string>();

  watch(PLAYWRIGHT_OUTPUT_DIR, (eventType, filename) => {
    if (!filename || (!filename.endsWith(".png") && !filename.endsWith(".jpeg"))) return;
    const filepath = join(PLAYWRIGHT_OUTPUT_DIR, filename);
    if (resized.has(filepath)) return;

    // Small delay to ensure the file is fully written
    setTimeout(() => {
      try {
        if (!existsSync(filepath)) return;
        // sips is built into macOS — no dependencies needed
        const info = execSync(`sips -g pixelWidth -g pixelHeight "${filepath}" 2>/dev/null`, { encoding: "utf8" });
        const wMatch = info.match(/pixelWidth:\s+(\d+)/);
        const hMatch = info.match(/pixelHeight:\s+(\d+)/);
        if (!wMatch || !hMatch) return;
        const w = parseInt(wMatch[1], 10);
        const h = parseInt(hMatch[1], 10);
        if (w > MAX_SCREENSHOT_DIM || h > MAX_SCREENSHOT_DIM) {
          execSync(`sips --resampleHeightWidthMax ${MAX_SCREENSHOT_DIM} "${filepath}" 2>/dev/null`);
          logErr(`Screenshot resized: ${filename} from ${w}x${h} to fit ${MAX_SCREENSHOT_DIM}px`);
        }
        resized.add(filepath);
        // Prevent unbounded growth — purge entries older than 100
        if (resized.size > 100) {
          const first = resized.values().next().value;
          if (first) resized.delete(first);
        }
      } catch (err) {
        // Non-critical — worst case Claude hits the error and retries without image
        logErr(`Screenshot resize failed for ${filename}: ${err}`);
      }
    }, 200);
  });

  logErr(`Screenshot resize watcher started on ${PLAYWRIGHT_OUTPUT_DIR} (max ${MAX_SCREENSHOT_DIM}px)`);
}

// --- State ---

/** Pre-warmed sessions keyed by sessionKey (e.g. "main", "floating", or model name for backward compat) */
const sessions = new Map<string, { sessionId: string; cwd: string; model?: string }>();
/**
 * Tracks how many image-bearing turns each session key has had.
 * Claude's API enforces a stricter 2000px/image limit once a session has many images.
 * Resetting this counter on session delete ensures a fresh session starts clean.
 */
const imageTurnCounts = new Map<string, number>();
/** Max images per session before we stop sending screenshots to prevent API limit errors. */
const MAX_IMAGE_TURNS = 20;
/** The session currently being used by an active query (for interrupt) */
let activeSessionId = "";
let activeAbort: AbortController | null = null;
let interruptRequested = false;
let isInitialized = false;
let authMethods: AuthMethod[] = [];
let authResolve: (() => void) | null = null;
let preWarmPromise: Promise<void> | null = null;
let authRetryCount = 0;
const MAX_AUTH_RETRIES = 2;
let activeAuthPromise: Promise<void> | null = null;
let activeOAuthFlow: OAuthFlowHandle | null = null;
/** Last warmup config received from Swift — replayed after OAuth subprocess restart */
let lastWarmupConfig: { cwd?: string; sessions?: WarmupSessionConfig[] } | null = null;

// --- Auth flow (OAuth) ---

/** Restart the ACP subprocess so it picks up freshly-stored credentials,
 *  then replay the last warmup so sessions are restored before the caller retries. */
async function restartAcpProcess(): Promise<void> {
  logErr("Restarting ACP subprocess to pick up new credentials...");
  if (acpProcess) {
    const exitPromise = new Promise<void>((resolve) => {
      acpProcess!.once("exit", () => resolve());
    });
    killAcpProcessTree();
    await exitPromise;
  }
  // State is cleaned up by the exit handler (sessions, handlers, etc.)
  startAcpProcess();

  // Replay warmup so sessions are re-created/resumed with the new credentials.
  // Without this, the caller would get a fresh (no-history) session after OAuth.
  if (lastWarmupConfig) {
    logErr("Replaying warmup after OAuth restart...");
    await preWarmSession(lastWarmupConfig.cwd, lastWarmupConfig.sessions);
  }
}

/**
 * Start the OAuth flow: spin up a local callback server, send the auth URL
 * to Swift (so it can open the browser), wait for the user to complete auth,
 * store credentials in Keychain, and restart the ACP subprocess.
 *
 * Idempotent: if a flow is already running, returns the same promise.
 */
async function startAuthFlow(): Promise<void> {
  if (activeAuthPromise) {
    logErr("Auth flow already in progress, waiting for it...");
    return activeAuthPromise;
  }

  activeAuthPromise = (async () => {
    try {
      logErr("Starting OAuth flow...");
      const flow = await startOAuthFlow(logErr);
      activeOAuthFlow = flow;

      // Send auth URL to Swift so it can open the browser
      send({ type: "auth_required", methods: authMethods, authUrl: flow.authUrl });

      // Wait for OAuth callback + token exchange + credential storage
      await flow.complete;
      logErr("OAuth flow completed successfully");

      // Restart ACP subprocess so it picks up new credentials from Keychain
      await restartAcpProcess();

      // Notify Swift
      send({ type: "auth_success" });
    } catch (err) {
      logErr(`OAuth flow failed: ${err}`);
      const isTimeout = err instanceof Error && err.message.includes("timed out");
      send({ type: "auth_timeout", reason: isTimeout ? "timeout" : String(err) });
      throw err;
    } finally {
      activeOAuthFlow = null;
      activeAuthPromise = null;
    }
  })();

  return activeAuthPromise;
}

// --- ACP initialization ---

async function initializeAcp(): Promise<void> {
  if (isInitialized) return;

  try {
    const result = (await acpRequest("initialize", {
      protocolVersion: 1,
    })) as {
      protocolVersion: number;
      agentCapabilities?: Record<string, unknown>;
      agentInfo?: { name: string; version: string };
      authMethods?: Array<{
        id: string;
        name: string;
        description?: string;
        type?: string;
        args?: string[];
        env?: Record<string, string>;
      }>;
    };

    logErr(
      `ACP initialized: protocol=${result.protocolVersion}, capabilities=${JSON.stringify(result.agentCapabilities)}`
    );

    // Store auth methods for potential later use
    if (result.authMethods && result.authMethods.length > 0) {
      authMethods = result.authMethods.map((m) => ({
        id: m.id,
        type: (m.type ?? "agent_auth") as AuthMethod["type"],
        displayName: m.name || m.description || m.id,
        args: m.args,
        env: m.env,
      }));
      logErr(
        `Auth methods: ${authMethods.map((m) => `${m.id}(${m.displayName})`).join(", ")}`
      );
    }

    isInitialized = true;
  } catch (err) {
    if (err instanceof AcpError && err.code === -32000) {
      // AUTH_REQUIRED
      const data = err.data as {
        authMethods?: Array<{
          id: string;
          name: string;
          description?: string;
          type?: string;
        }>;
      };
      if (data?.authMethods) {
        authMethods = data.authMethods.map((m) => ({
          id: m.id,
          type: (m.type ?? "agent_auth") as AuthMethod["type"],
          displayName: m.name || m.description || m.id,
        }));
      }
      logErr(`ACP requires authentication: ${JSON.stringify(authMethods)}`);
      await startAuthFlow();

      // Retry initialization after auth (ACP subprocess already restarted)
      await initializeAcp();
      return;
    }
    throw err;
  }
}

// --- MCP server config builder ---

type McpServerConfig = {
  name: string;
  command: string;
  args: string[];
  env: Array<{ name: string; value: string }>;
};

function buildMcpServers(mode: string, cwd?: string, sessionKey?: string): McpServerConfig[] {
  const servers: McpServerConfig[] = [];

  // omi-tools (stdio, connects back via Unix socket)
  const omiToolsEnv: Array<{ name: string; value: string }> = [
    { name: "OMI_BRIDGE_PIPE", value: omiToolsPipePath },
    { name: "OMI_QUERY_MODE", value: mode },
  ];
  if (cwd) {
    omiToolsEnv.push({ name: "OMI_WORKSPACE", value: cwd });
  }
  if (sessionKey === "onboarding") {
    omiToolsEnv.push({ name: "OMI_ONBOARDING", value: "true" });
  }
  servers.push({
    name: "omi-tools",
    command: process.execPath,
    args: [omiToolsStdioScript],
    env: omiToolsEnv,
  });

  // Playwright MCP server
  const playwrightArgs = [playwrightCli];
  if (process.env.PLAYWRIGHT_USE_EXTENSION === "true") {
    playwrightArgs.push("--extension");
  }
  // Save snapshots to files and strip inline base64 screenshots to reduce context size
  playwrightArgs.push("--output-mode", "file", "--image-responses", "omit", "--output-dir", "/tmp/playwright-mcp");
  const playwrightEnv: Array<{ name: string; value: string }> = [];
  if (process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN) {
    playwrightEnv.push({
      name: "PLAYWRIGHT_MCP_EXTENSION_TOKEN",
      value: process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN,
    });
  }
  servers.push({
    name: "playwright",
    command: process.execPath,
    args: playwrightArgs,
    env: playwrightEnv,
  });

  // mcp-server-macos-use (native macOS accessibility automation)
  if (existsSync(macosUseBinary)) {
    servers.push({
      name: "macos-use",
      command: macosUseBinary,
      args: [],
      env: [],
    });
  }

  return servers;
}

// --- Session pre-warming ---

const DEFAULT_MODEL = "claude-opus-4-6";
const SONNET_MODEL = "claude-sonnet-4-6";

interface WarmupSessionConfig {
  key: string;
  model: string;
  systemPrompt?: string;
  resume?: string;  // if set, resume this session ID instead of creating a new one
}

async function preWarmSession(cwd?: string, sessionConfigs?: WarmupSessionConfig[], models?: string[]): Promise<void> {
  // Use tmpdir() instead of $HOME to avoid triggering macOS TCC/FileProvider
  // prompts (e.g. Dropbox) when ACP scans the cwd during session init.
  const warmCwd = cwd || tmpdir();

  // Save config so it can be replayed after an OAuth-triggered subprocess restart
  if (sessionConfigs && sessionConfigs.length > 0) {
    lastWarmupConfig = { cwd, sessions: sessionConfigs };
  }

  // Build the list of sessions to warm: new format (sessionConfigs) takes priority over legacy (models array)
  const toWarm: WarmupSessionConfig[] = sessionConfigs && sessionConfigs.length > 0
    ? sessionConfigs.filter((s) => !sessions.has(s.key))
    : (models && models.length > 0 ? models : [DEFAULT_MODEL, SONNET_MODEL])
        .filter((m) => !sessions.has(m))
        .map((m) => ({ key: m, model: m }));

  if (toWarm.length === 0) {
    logErr("All requested sessions already pre-warmed");
    return;
  }

  try {
    await initializeAcp();

    await Promise.all(
      toWarm.map(async (cfg) => {
        try {
          const sessionParams: Record<string, unknown> = {
            cwd: warmCwd,
            mcpServers: buildMcpServers("act", warmCwd, cfg.key),
            ...(cfg.systemPrompt ? { _meta: { systemPrompt: cfg.systemPrompt } } : {}),
          };

          // Resume existing session if ID provided, otherwise create a new one
          let sessionId: string;
          if (cfg.resume) {
            try {
              await acpRequest("session/resume", {
                sessionId: cfg.resume,
                cwd: warmCwd,
                mcpServers: buildMcpServers("act", warmCwd, cfg.key),
              });
              sessionId = cfg.resume;
              logErr(`Pre-warm resumed session: ${sessionId} (key=${cfg.key}, model=${cfg.model})`);
            } catch (resumeErr) {
              logErr(`Pre-warm session/resume failed for ${cfg.key}, falling back to session/new: ${resumeErr}`);
              const result = (await acpRequest("session/new", sessionParams)) as { sessionId: string };
              sessionId = result.sessionId;
              logErr(`Pre-warmed new session: ${sessionId} (key=${cfg.key}, model=${cfg.model}, hasSystemPrompt=${!!cfg.systemPrompt})`);
            }
          } else {
            // Retry once after a short delay if session/new fails
            let result: { sessionId: string };
            try {
              result = (await acpRequest("session/new", sessionParams)) as { sessionId: string };
            } catch (firstErr) {
              logErr(`Pre-warm session/new failed for ${cfg.key}, retrying in 2s: ${firstErr}`);
              await new Promise((r) => setTimeout(r, 2000));
              result = (await acpRequest("session/new", sessionParams)) as { sessionId: string };
            }
            sessionId = result.sessionId;
            logErr(`Pre-warmed session: ${sessionId} (key=${cfg.key}, model=${cfg.model}, hasSystemPrompt=${!!cfg.systemPrompt})`);
          }

          sessions.set(cfg.key, { sessionId, cwd: warmCwd, model: cfg.model });
          await acpRequest("session/set_model", { sessionId, modelId: cfg.model });
        } catch (err) {
          if (err instanceof AcpError && err.code === -32000) {
            logErr(`Pre-warm failed with auth error (code=${err.code}), starting OAuth flow`);
            await startAuthFlow();
            return;
          }
          logErr(`Pre-warm failed for ${cfg.key}: ${err}`);
        }
      })
    );
  } catch (err) {
    logErr(`Pre-warm failed (will create on first query): ${err}`);
  }
}

// --- Handle query from Swift ---

async function handleQuery(msg: QueryMessage): Promise<void> {
  if (activeAbort) {
    activeAbort.abort();
    activeAbort = null;
  }

  const abortController = new AbortController();
  activeAbort = abortController;
  interruptRequested = false;
  authRetryCount = 0;

  let fullText = "";
  let fullPrompt = "";
  let isNewSession = false;
  let retryingWithHint = false;
  let sessionRetryCount = 0;
  const pendingTools: string[] = [];
  lastTextContentBlockIndex = -1;
  pendingBoundary = false;

  try {
    const mode = msg.mode ?? "act";
    currentMode = mode;
    logErr(`Query mode: ${mode}`);

    // Wait for pre-warm to finish if in progress
    if (preWarmPromise) {
      logErr("Waiting for pre-warm to complete...");
      await preWarmPromise;
      preWarmPromise = null;
    }

    // Ensure ACP is initialized
    await initializeAcp();

    // Look up a pre-warmed session by sessionKey (falls back to model name for backward compat)
    const requestedModel = msg.model || DEFAULT_MODEL;
    const sessionKey = msg.sessionKey ?? requestedModel;
    const requestedCwd = msg.cwd || tmpdir();
    let sessionId = "";

    const existing = sessions.get(sessionKey);
    if (existing) {
      // If cwd changed, invalidate this specific session
      if (existing.cwd !== requestedCwd) {
        logErr(`Cwd changed for ${sessionKey} (${existing.cwd} -> ${requestedCwd}), creating new session`);
        sessions.delete(sessionKey);
        imageTurnCounts.delete(sessionKey);
      } else {
        sessionId = existing.sessionId;
      }
    }

    // Reuse existing session if alive, resume a persisted one, or create a new one
    if (msg.resume && !sessionId) {
      // Resume a persisted session by ID (survives process restarts via ~/.claude/projects/)
      // Fall back to session/new if the session file is gone or resume fails
      try {
        await acpRequest("session/resume", {
          sessionId: msg.resume,
          cwd: requestedCwd,
          mcpServers: buildMcpServers(mode, requestedCwd, sessionKey),
        });
        sessionId = msg.resume;
        sessions.set(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
        isNewSession = false;
        logErr(`ACP session resumed: ${sessionId} (key=${sessionKey})`);
      } catch (resumeErr) {
        logErr(`ACP session resume failed (will create new session): ${resumeErr}`);
        // Fall through to session/new below
      }
    }
    if (!sessionId) {
      const sessionParams: Record<string, unknown> = {
        cwd: requestedCwd,
        mcpServers: buildMcpServers(mode, requestedCwd, sessionKey),
        ...(msg.systemPrompt ? { _meta: { systemPrompt: msg.systemPrompt } } : {}),
      };
      const sessionResult = (await acpRequest("session/new", sessionParams)) as { sessionId: string };

      sessionId = sessionResult.sessionId;
      sessions.set(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
      isNewSession = true;
      if (requestedModel) {
        await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
      }
      logErr(`ACP session created: ${sessionId} (key=${sessionKey}, model=${requestedModel || "default"}, cwd=${requestedCwd})`);
    } else {
      isNewSession = false;
      logErr(`Reusing existing ACP session: ${sessionId} (key=${sessionKey})`);
    }
    activeSessionId = sessionId;

    fullPrompt = msg.prompt;

    // Set up notification handler for this query
    acpNotificationHandler = (method: string, params: unknown) => {
      if (abortController.signal.aborted) return;

      if (method === "session/update") {
        const p = params as Record<string, unknown>;
        handleSessionUpdate(p, pendingTools, (text) => {
          fullText += text;
        });
      }
    };

    // Send the prompt — retry with fresh session if stale
    const sendPrompt = async (): Promise<void> => {
      const promptBlocks: Array<Record<string, unknown>> = [];
      // Cap image sends per session to avoid Claude's "many-image" stricter 2000px limit.
      // After MAX_IMAGE_TURNS images in a session, screenshots are silently dropped.
      const currentImageTurns = imageTurnCounts.get(sessionKey) ?? 0;
      const includeImage = !!(msg.imageBase64 && !retryingWithHint && currentImageTurns < MAX_IMAGE_TURNS);
      if (includeImage) {
        promptBlocks.push({ type: "image", data: msg.imageBase64, mimeType: "image/jpeg" });
      } else if (msg.imageBase64 && !retryingWithHint) {
        logErr(`Skipping screenshot — session has ${currentImageTurns} image turns (cap=${MAX_IMAGE_TURNS})`);
      }
      promptBlocks.push({ type: "text", text: fullPrompt });

      const sessionPromptPayload = {
        sessionId,
        prompt: promptBlocks,
      };

      const promptResult = (await acpRequest("session/prompt", sessionPromptPayload)) as {
        stopReason: string;
        // Populated by patched-acp-entry.mjs intercepting SDKResultSuccess
        usage?: { inputTokens: number; outputTokens: number; cachedReadTokens?: number | null; cachedWriteTokens?: number | null; totalTokens: number };
        _meta?: { costUsd?: number };
      };

      logErr(`Prompt completed: stopReason=${promptResult.stopReason}`);

      // Increment image turn counter so we know when to stop including screenshots.
      if (includeImage) {
        imageTurnCounts.set(sessionKey, currentImageTurns + 1);
      }

      // Mark any remaining pending tools as completed
      for (const name of pendingTools) {
        send({ type: "tool_activity", name, status: "completed" });
      }
      pendingTools.length = 0;

      const inputTokens = promptResult.usage?.inputTokens ?? Math.ceil(fullPrompt.length / 4);
      const outputTokens = promptResult.usage?.outputTokens ?? Math.ceil(fullText.length / 4);
      const cacheReadTokens = promptResult.usage?.cachedReadTokens ?? 0;
      const cacheWriteTokens = promptResult.usage?.cachedWriteTokens ?? 0;
      const costUsd = promptResult._meta?.costUsd ?? 0;
      send({ type: "result", text: fullText, sessionId, costUsd, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens });
    };

    try {
      await sendPrompt();
    } catch (err) {
      if (abortController.signal.aborted) {
        if (interruptRequested) {
          for (const name of pendingTools) {
            send({ type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
          logErr(
            `Query interrupted by user, sending partial result (${fullText.length} chars)`
          );
          const inputTokens = Math.ceil(fullPrompt.length / 4);
          const outputTokens = Math.ceil(fullText.length / 4);
          send({ type: "result", text: fullText, sessionId, costUsd: 0, inputTokens, outputTokens, cacheReadTokens: 0, cacheWriteTokens: 0 });
        } else {
          logErr("Query aborted (superseded by new query)");
        }
        return;
      }
      // Only -32000 is AUTH_REQUIRED in the new ACP protocol.
      // -32603 is a generic internal error (API error, rate limit, etc.) — do NOT start OAuth for it.
      if (err instanceof AcpError && err.code === -32000) {
        if (authRetryCount >= MAX_AUTH_RETRIES) {
          logErr(`session/prompt auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
          send({ type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
          return;
        }
        authRetryCount++;
        logErr(`session/prompt failed with auth error (code=${err.code}), starting OAuth flow (attempt ${authRetryCount})`);
        sessions.delete(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        msg.resume = undefined;
        await startAuthFlow();
        return handleQuery(msg);
      }
      const errMsg = err instanceof Error ? err.message : String(err);

      // Credit balance exhausted — do NOT retry, surface immediately
      const isCreditExhausted = /credit balance is too low|insufficient.*(credit|funds|balance)/i.test(errMsg);
      if (isCreditExhausted) {
        logErr(`Credit balance exhausted, not retrying: ${errMsg}`);
        for (const name of pendingTools) {
          send({ type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        send({ type: "credit_exhausted", message: errMsg });
        return;
      }

      // Image/content too large — retry on the SAME session without the image,
      // with a hint so the model can adjust its approach.
      const isImageTooLarge = /image.*(too large|too big|exceeds.*limit)|unable to resize image|content too long/i.test(errMsg);
      if (isImageTooLarge && sessionId && !retryingWithHint) {
        logErr(`session/prompt failed with image-too-large error, retrying on same session without image: ${errMsg}`);
        for (const name of pendingTools) {
          send({ type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;

        // Strip the image and retry with a hint
        retryingWithHint = true;
        msg.imageBase64 = undefined;
        fullPrompt = `The previous request failed because an image was too large: "${errMsg}". Please continue with a different approach — avoid reading large image files directly. Use smaller outputs or text-based tools instead.`;
        try {
          await sendPrompt();
        } catch (retryErr) {
          const retryErrMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
          const isStillImageTooLarge = /image.*(too large|too big|exceeds.*limit)|unable to resize image|content too long/i.test(retryErrMsg);
          if (isStillImageTooLarge) {
            // The session history itself contains oversized images — start a fresh session.
            logErr(`Retry without image also failed with image-too-large — session history poisoned, starting new session: ${retryErrMsg}`);
            sessions.delete(sessionKey);
            imageTurnCounts.delete(sessionKey);
            activeSessionId = "";
            msg.resume = undefined;
            msg.imageBase64 = undefined;
            fullPrompt = msg.prompt;
            return handleQuery(msg);
          }
          throw retryErr;
        } finally {
          retryingWithHint = false;
        }
        return;
      }
      // If session/prompt failed while reusing an existing session, retry once.
      // Try to resume the same session first (session files on disk may still be valid
      // even if the ACP process died). The resume path (line ~755) has its own try/catch
      // that falls back to session/new if the session file is gone or corrupt.
      // Guard: isNewSession check prevents retry after a fresh session, and sessionRetryCount
      // caps retries to 1 as a safety net against infinite loops.
      if (!isNewSession && sessionId && sessionRetryCount === 0) {
        sessionRetryCount++;
        logErr(`session/prompt failed with existing session, retrying with session resume: ${err}`);
        const failedSessionId = sessionId;
        sessions.delete(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        // Attempt to resume the failed session — the ACP SDK can reload
        // conversation history from ~/.claude/projects/ session files.
        // If resume fails, the resume path falls back to session/new automatically.
        msg.resume = failedSessionId;
        return handleQuery(msg);
      }
      throw err;
    }
  } catch (err: unknown) {
    if (abortController.signal.aborted) {
      if (interruptRequested) {
        for (const name of pendingTools) {
          send({ type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        const inputTokens = Math.ceil(fullPrompt.length / 4);
        const outputTokens = Math.ceil(fullText.length / 4);
        send({ type: "result", text: fullText, sessionId: activeSessionId, costUsd: 0, inputTokens, outputTokens });
      }
      return;
    }
    // Only -32000 is AUTH_REQUIRED in the new ACP protocol.
    // -32603 is a generic internal error — surface it as a real error, not auth.
    if (err instanceof AcpError && err.code === -32000) {
      if (authRetryCount >= MAX_AUTH_RETRIES) {
        logErr(`Query auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
        send({ type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
        return;
      }
      authRetryCount++;
      logErr(`Query failed with auth error (code=${(err as AcpError).code}), starting OAuth flow (attempt ${authRetryCount})`);
      await startAuthFlow();
      return handleQuery(msg);
    }
    const errMsg = err instanceof Error ? err.message : String(err);
    // Credit balance exhausted — surface as specific type (outer catch)
    const isCreditExhausted = /credit balance is too low|insufficient.*(credit|funds|balance)/i.test(errMsg);
    if (isCreditExhausted) {
      logErr(`Credit balance exhausted (outer): ${errMsg}`);
      send({ type: "credit_exhausted", message: errMsg });
      return;
    }
    logErr(`Query error: ${errMsg}`);
    send({ type: "error", message: errMsg });
  } finally {
    if (activeAbort === abortController) {
      activeAbort = null;
    }
    acpNotificationHandler = null;
  }
}

/** Track the last content block index to detect boundaries between consecutive text blocks */
let lastTextContentBlockIndex = -1;
/** Whether the next text delta should be preceded by a boundary (e.g. after tool use) */
let pendingBoundary = false;

/** Translate ACP session/update notifications into our JSON-lines protocol.
 *
 * ACP uses `params.update.sessionUpdate` as the discriminator field:
 *   - "agent_message_chunk" → text delta (content.text)
 *   - "agent_thought_chunk" → thinking delta (content.text)
 *   - "tool_call" → tool started (title, toolCallId, kind, status)
 *   - "tool_call_update" → tool completed (toolCallId, status, content)
 *   - "plan" → plan entries (entries[].content)
 */
function handleSessionUpdate(
  params: Record<string, unknown>,
  pendingTools: string[],
  onText: (text: string) => void
): void {
  const update = params.update as Record<string, unknown> | undefined;
  if (!update) {
    logErr(`session/update missing 'update' field: ${JSON.stringify(params).slice(0, 200)}`);
    return;
  }

  const sessionUpdate = update.sessionUpdate as string;

  switch (sessionUpdate) {
    case "agent_message_chunk": {
      const content = update.content as { type: string; text?: string } | undefined;
      const text = content?.text ?? "";

      // Detect content block boundaries: the ACP update may include an index
      // field indicating which content block this chunk belongs to. When the
      // index changes, we've crossed into a new text block.
      const blockIndex = typeof (update as Record<string, unknown>).index === "number"
        ? (update as Record<string, unknown>).index as number
        : typeof (content as Record<string, unknown> | undefined)?.index === "number"
          ? (content as Record<string, unknown>).index as number
          : -1;

      if (text) {
        // If tools were pending, they're now complete
        if (pendingTools.length > 0) {
          for (const name of pendingTools) {
            send({ type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
        }

        // Signal a boundary between text blocks:
        // - when content block index changes within a single response
        // - when resuming text after a tool call (pendingBoundary)
        if (pendingBoundary || (blockIndex >= 0 && lastTextContentBlockIndex >= 0 && blockIndex !== lastTextContentBlockIndex)) {
          send({ type: "text_block_boundary" });
          pendingBoundary = false;
        }
        if (blockIndex >= 0) {
          lastTextContentBlockIndex = blockIndex;
        }

        onText(text);
        send({ type: "text_delta", text });
      }
      break;
    }

    case "agent_thought_chunk": {
      const content = update.content as { type: string; text?: string } | undefined;
      const text = content?.text ?? "";
      if (text) {
        send({ type: "thinking_delta", text });
      }
      break;
    }

    case "tool_call": {
      // Mark that text after tool use should get a boundary separator
      pendingBoundary = true;

      const toolCallId = (update.toolCallId as string) ?? "";
      let title = (update.title as string) ?? "unknown";
      const kind = (update.kind as string) ?? "";
      const status = (update.status as string) ?? "pending";

      // Recover real tool name for server-side tools (e.g. WebSearch, WebFetch)
      // where title may arrive as undefined/unknown
      if (title === "unknown" || title.includes("undefined")) {
        const meta = update._meta as { claudeCode?: { toolName?: string } } | undefined;
        const toolName = meta?.claudeCode?.toolName;
        const rawInput = update.rawInput as Record<string, unknown> | undefined;
        if (toolName === "WebSearch" && rawInput?.query) {
          title = `WebSearch: "${rawInput.query}"`;
        } else if (toolName === "WebFetch" && rawInput?.url) {
          title = `WebFetch: ${rawInput.url}`;
        } else if (toolName) {
          title = toolName;
        }
      }

      if (status === "pending" || status === "in_progress") {
        pendingTools.push(title);
        send({
          type: "tool_activity",
          name: title,
          status: "started",
          toolUseId: toolCallId,
        });

        // Extract input from rawInput if available
        const rawInput = update.rawInput as Record<string, unknown> | undefined;
        if (rawInput && Object.keys(rawInput).length > 0) {
          send({
            type: "tool_activity",
            name: title,
            status: "started",
            toolUseId: toolCallId,
            input: rawInput,
          });
        }

        logErr(`Tool started: ${title} (id=${toolCallId}, kind=${kind})`);
      }
      break;
    }

    case "tool_call_update": {
      const toolCallId = (update.toolCallId as string) ?? "";
      const status = (update.status as string) ?? "";
      let title = (update.title as string) ?? "unknown";

      // Recover real tool name (same logic as tool_call)
      if (title === "unknown" || title.includes("undefined")) {
        const meta = update._meta as { claudeCode?: { toolName?: string } } | undefined;
        const toolName = meta?.claudeCode?.toolName;
        if (toolName) {
          title = toolName;
        }
      }

      if (status === "completed" || status === "failed" || status === "cancelled") {
        // Remove from pending
        const idx = pendingTools.indexOf(title);
        if (idx >= 0) pendingTools.splice(idx, 1);

        send({
          type: "tool_activity",
          name: title,
          status: "completed",
          toolUseId: toolCallId,
        });

        // Check if this is an MCP tool error (isError flag from MCP protocol)
        const isError = !!(update.isError ?? (update as Record<string, unknown>).is_error);

        // Extract text output from content array or rawOutput.
        // ACP wraps MCP content items as {type:"content", content:{type:"text"|"image", ...}}.
        // We extract only text items and skip images to keep context small.
        let output = "";
        const contentArr = update.content as
          | Array<Record<string, unknown>>
          | undefined;
        if (contentArr && Array.isArray(contentArr)) {
          const texts: string[] = [];
          for (const item of contentArr) {
            // Direct MCP format: {type:"text", text:"..."}
            if (item.type === "text" && typeof item.text === "string") {
              texts.push(item.text as string);
            }
            // ACP-wrapped format: {type:"content", content:{type:"text", text:"..."}}
            const inner = item.content as Record<string, unknown> | undefined;
            if (inner && inner.type === "text" && typeof inner.text === "string") {
              texts.push(inner.text as string);
            }
          }
          output = texts.join("\n");
        }
        if (!output) {
          // Fallback to rawOutput, but extract only text items (skip base64 images)
          const rawOutput = update.rawOutput as unknown;
          if (Array.isArray(rawOutput)) {
            const texts: string[] = [];
            for (const item of rawOutput as Array<Record<string, unknown>>) {
              if (item.type === "text" && typeof item.text === "string") {
                texts.push(item.text as string);
              }
            }
            output = texts.join("\n");
          } else if (rawOutput && typeof rawOutput === "object") {
            output = JSON.stringify(rawOutput);
          }
        }

        // Log MCP tool errors prominently so they appear in Sentry breadcrumbs
        if (isError || status === "failed") {
          logErr(`Tool ERROR: ${title} (id=${toolCallId}) error=${output.slice(0, 500)}`);
        }
        // Also detect error patterns in tool output (e.g. MCP tools that return errors without isError flag)
        if (output && !isError && status !== "failed") {
          const outputLower = output.toLowerCase();
          if (
            (title.startsWith("mcp__playwright") || title.startsWith("mcp__macos-use")) &&
            (outputLower.includes("error") || outputLower.includes("failed") || outputLower.includes("connection closed") || outputLower.includes("timeout"))
          ) {
            logErr(`Tool soft-error: ${title} (id=${toolCallId}) output=${output.slice(0, 500)}`);
          }
        }

        if (output) {
          const truncated =
            output.length > 2000
              ? output.slice(0, 2000) + "\n... (truncated)"
              : output;
          send({
            type: "tool_result_display",
            toolUseId: toolCallId,
            name: title,
            output: truncated,
          });
        }

        logErr(
          `Tool completed: ${title} (id=${toolCallId}) output=${output ? output.length + " chars" : "none"}`
        );
      }
      break;
    }

    case "plan": {
      const entries = update.entries as
        | Array<{ content: string; status: string }>
        | undefined;
      if (entries && Array.isArray(entries)) {
        for (const entry of entries) {
          if (entry.content) {
            send({ type: "thinking_delta", text: entry.content + "\n" });
          }
        }
      }
      break;
    }

    // --- Forwarded events (previously dropped by acp-agent.js) ---

    case "compact_boundary": {
      const trigger = (update.trigger as string) ?? "auto";
      const preTokens = (update.preTokens as number) ?? 0;
      send({ type: "compact_boundary", trigger, preTokens });
      logErr(`Compact boundary: trigger=${trigger}, preTokens=${preTokens}`);
      break;
    }

    case "status_change": {
      const status = (update.status as string | null) ?? null;
      send({ type: "status_change", status });
      logErr(`Status change: ${status}`);
      break;
    }

    case "compaction_start": {
      send({ type: "status_change", status: "compacting" });
      logErr("Compaction stream started");
      break;
    }

    case "compaction_delta": {
      // High-frequency — status_change "compacting" is sufficient for UI
      break;
    }

    case "task_started": {
      const taskId = (update.taskId as string) ?? "";
      const description = (update.description as string) ?? "";
      send({ type: "task_started", taskId, description });
      logErr(`Task started: ${taskId} — ${description}`);
      break;
    }

    case "task_notification": {
      const taskId = (update.taskId as string) ?? "";
      const status = (update.status as string) ?? "";
      const summary = (update.summary as string) ?? "";
      send({ type: "task_notification", taskId, status, summary });
      logErr(`Task notification: ${taskId} ${status}`);
      break;
    }

    case "tool_progress": {
      const toolUseId = (update.toolUseId as string) ?? "";
      const toolName = (update.toolName as string) ?? "";
      const elapsed = (update.elapsedTimeSeconds as number) ?? 0;
      send({ type: "tool_progress", toolUseId, toolName, elapsedTimeSeconds: elapsed });
      break;
    }

    case "tool_use_summary": {
      const summary = (update.summary as string) ?? "";
      const ids = (update.precedingToolUseIds as string[]) ?? [];
      send({ type: "tool_use_summary", summary, precedingToolUseIds: ids });
      logErr(`Tool use summary: ${summary.slice(0, 100)}`);
      break;
    }

    default:
      logErr(
        `Unknown session update type: ${sessionUpdate} — ${JSON.stringify(update).slice(0, 200)}`
      );
  }
}

// --- Error handling ---

/** Write to /tmp/acp-bridge-crash.log as fallback when stderr might be lost */
function logCrash(msg: string): void {
  try {
    const ts = new Date().toISOString();
    appendFileSync("/tmp/acp-bridge-crash.log", `[${ts}] ${msg}\n`);
  } catch {
    // ignore
  }
}

process.on("unhandledRejection", (reason) => {
  logErr(`Unhandled rejection: ${reason}`);
  logCrash(`Unhandled rejection: ${reason}`);
});

process.on("uncaughtException", (err) => {
  const code = (err as NodeJS.ErrnoException).code;
  if (code === "EPIPE" || code === "ERR_STREAM_DESTROYED") {
    logErr(`Caught ${code} in uncaughtException (subprocess pipe closed)`);
    logCrash(`Caught ${code} (pipe closed)`);
    return;
  }
  logErr(`Uncaught exception: ${err.message}\n${err.stack ?? ""}`);
  logCrash(`Uncaught exception: ${err.message}\n${err.stack ?? ""}`);
  send({ type: "error", message: `Uncaught: ${err.message}` });
  process.exit(1);
});

process.stdout.on("error", (err) => {
  if ((err as NodeJS.ErrnoException).code === "EPIPE") {
    logErr("stdout pipe closed (parent process disconnected)");
    logCrash("stdout EPIPE — parent disconnected");
    process.exit(0);
  }
  logErr(`stdout error: ${err.message}`);
  logCrash(`stdout error: ${err.message}`);
});

// --- Main ---

async function main(): Promise<void> {
  // Log MCP server versions at startup for diagnostics
  let playwrightVersion = "unknown";
  try {
    const pkgPath = join(__dirname, "..", "node_modules", "@playwright", "mcp", "package.json");
    const pkg = JSON.parse((await import("fs")).readFileSync(pkgPath, "utf8"));
    playwrightVersion = pkg.version ?? "unknown";
  } catch { /* ignore */ }

  logErr(`Bridge main() starting (pid=${process.pid}, node=${process.version}, execPath=${process.execPath})`);
  logErr(`MCP versions: playwright=${playwrightVersion}, macos-use=${existsSync(macosUseBinary) ? "bundled" : "missing"}`);
  logErr(`Playwright MCP config: extension=${process.env.PLAYWRIGHT_USE_EXTENSION ?? "false"}, token=${process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN ? "set" : "unset"}, outputMode=file, imageResponses=omit, outputDir=/tmp/playwright-mcp`);

  // Log browser diagnostics for debugging Playwright connection issues
  try {
    const { execSync } = await import("child_process");
    const { readdirSync } = await import("fs");
    const { homedir } = await import("os");
    const home = homedir();
    const chromeVersion = execSync("/Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome --version 2>/dev/null || echo 'not installed'", { encoding: "utf8" }).trim();
    const chromeProcs = execSync("ps aux | grep -c '[G]oogle Chrome' 2>/dev/null || echo 0", { encoding: "utf8" }).trim();
    const port9222 = execSync("lsof -i :9222 2>/dev/null | head -1 || echo 'free'", { encoding: "utf8" }).trim();
    const singletonLock = existsSync(join(home, "Library/Application Support/Google/Chrome/SingletonLock")) ? "locked" : "unlocked";
    let extensionCount = 0;
    try { extensionCount = readdirSync(join(home, "Library/Application Support/Google/Chrome/Default/Extensions")).length; } catch { /* ignore */ }
    logErr(`Browser diagnostics: chrome="${chromeVersion}", processes=${chromeProcs}, port9222="${port9222}", profileLock=${singletonLock}, extensions=${extensionCount}`);
  } catch (err) {
    logErr(`Browser diagnostics failed: ${err}`);
  }

  // 0. Start screenshot resize watcher (prevents 2000px API limit errors)
  startScreenshotResizeWatcher();

  // 1. Start Unix socket for omi-tools relay
  omiToolsPipePath = await startOmiToolsRelay();
  logErr("omi-tools relay started");

  // 2. Start the ACP subprocess
  startAcpProcess();
  logErr("ACP subprocess spawned");

  // 3. Signal readiness
  send({ type: "init", sessionId: "" });
  logErr("ACP Bridge started, waiting for queries...");

  // 4. Read JSON lines from Swift
  const rl = createInterface({ input: process.stdin, terminal: false });

  rl.on("line", (line: string) => {
    if (!line.trim()) return;

    let msg: InboundMessage;
    try {
      msg = JSON.parse(line) as InboundMessage;
    } catch {
      logErr(`Invalid JSON: ${line}`);
      return;
    }

    switch (msg.type) {
      case "query":
        handleQuery(msg).catch((err) => {
          logErr(`Unhandled query error: ${err}`);
          send({ type: "error", message: String(err) });
        });
        break;

      case "warmup": {
        const wm = msg as WarmupMessage;
        if (wm.sessions && wm.sessions.length > 0) {
          logErr(`Warmup requested (cwd=${wm.cwd || "default"}, sessions=${wm.sessions.map(s => s.key).join(", ")})`);
          preWarmPromise = preWarmSession(wm.cwd, wm.sessions);
        } else {
          // Backward compat: models array or single model
          const models = wm.models ?? (wm.model ? [wm.model] : undefined);
          logErr(`Warmup requested (cwd=${wm.cwd || "default"}, models=${JSON.stringify(models) || "default"})`);
          preWarmPromise = preWarmSession(wm.cwd, undefined, models);
        }
        break;
      }

      case "tool_result":
        resolveToolCall(msg);
        break;

      case "interrupt":
        logErr("Interrupt requested by user");
        interruptRequested = true;
        if (activeAbort) activeAbort.abort();
        if (activeSessionId) {
          acpNotify("session/cancel", { sessionId: activeSessionId });
        }
        break;

      case "authenticate": {
        // Legacy fallback: OAuth flow now handles auth internally.
        // This handler is kept for backward compatibility.
        logErr(`Authentication message received from Swift (legacy fallback)`);
        send({ type: "auth_success" });
        if (authResolve) {
          authResolve();
          authResolve = null;
        }
        break;
      }

      case "resetSession": {
        const key = (msg as any).sessionKey;
        if (key && sessions.has(key)) {
          sessions.delete(key);
          imageTurnCounts.delete(key);
          logErr(`Session reset: ${key} (will create new on next query)`);
        }
        break;
      }

      case "stop":
        logErr("Received stop signal, exiting");
        if (activeAbort) activeAbort.abort();
        killAcpProcessTree();
        process.exit(0);
        break;

      default:
        logErr(`Unknown message type: ${(msg as any).type}`);
    }
  });

  rl.on("close", () => {
    logErr("stdin closed, exiting");
    logCrash("stdin closed, exiting");
    if (activeAbort) activeAbort.abort();
    killAcpProcessTree();
    process.exit(0);
  });
}

// Ensure child processes are cleaned up when this process is killed
for (const sig of ["SIGTERM", "SIGHUP", "SIGINT"] as const) {
  process.on(sig, () => {
    logErr(`Received ${sig}, cleaning up`);
    killAcpProcessTree();
    process.exit(0);
  });
}

main().catch((err) => {
  logErr(`Fatal error: ${err}`);
  logCrash(`Fatal error: ${err}`);
  send({ type: "error", message: `Fatal: ${err}` });
  killAcpProcessTree();
  process.exit(1);
});

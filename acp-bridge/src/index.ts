/**
 * ACP Bridge — translates between Fazm's JSON-lines protocol and the
 * Agent Client Protocol (ACP) used by claude-code-acp.
 *
 * THIS IS THE DESKTOP APP FLOW. This bridge runs locally on the user's Mac.
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
 * 1. Create Unix socket server for fazm-tools relay
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
import { tmpdir, homedir } from "os";
import { unlinkSync, appendFileSync, existsSync, watch, mkdirSync } from "fs";
import type {
  InboundMessage,
  OutboundMessage,
  QueryMessage,
  WarmupMessage,
  AuthMethod,
} from "./protocol.js";
import { startOAuthFlow, OAuthTokenExchangeError, type OAuthFlowHandle } from "./oauth-flow.js";

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

const fazmToolsStdioScript = join(__dirname, "fazm-tools-stdio.js");

// App bundle paths — FAZM_RESOURCES_PATH points to Contents/Resources/ (set by Swift).
// Falls back to process.execPath-relative paths for local dev where Node runs from the bundle.
const resourcesDir = process.env.FAZM_RESOURCES_PATH || join(dirname(process.execPath), "..", "..", "Resources");
const contentsDir = join(resourcesDir, "..");

const macosUseBinary = join(contentsDir, "MacOS", "mcp-server-macos-use");
const whatsappMcpBinary = join(contentsDir, "MacOS", "whatsapp-mcp");

// Google Workspace MCP — Python server bundled under Contents/Resources/google-workspace-mcp/
const googleWorkspaceMcpDir = join(resourcesDir, "google-workspace-mcp");
const googleWorkspaceMcpPython = join(googleWorkspaceMcpDir, ".venv", "bin", "python3");
const googleWorkspaceMcpMain = join(googleWorkspaceMcpDir, "main.py");


// --- Tool timeout watchdog ---
// Tracks running tools and enforces per-tool wall-clock limits.
// When a tool exceeds its timeout, a synthetic "completed" (with error) is
// emitted so the model can recover and the Swift bridge unblocks.

const TOOL_TIMEOUT_INTERNAL_MS = 10_000;   // ToolSearch and similar: 10s
const TOOL_TIMEOUT_MCP_MS = 120_000;       // MCP tools: 2 min
const TOOL_TIMEOUT_DEFAULT_MS = 300_000;   // Everything else: 5 min

// User-configurable override (seconds) via Settings > Advanced > Tool Timeout
const toolTimeoutOverrideSec = process.env.FAZM_TOOL_TIMEOUT_SECONDS
  ? parseInt(process.env.FAZM_TOOL_TIMEOUT_SECONDS, 10)
  : 0;

interface TrackedTool {
  toolCallId: string;
  title: string;
  isInternal: boolean;
  sessionId: string | undefined;
  timer: ReturnType<typeof setTimeout>;
}

const activeToolTimers = new Map<string, TrackedTool>();

function getToolTimeoutMs(title: string, isInternal: boolean): number {
  // User override applies to all tools (converted from seconds)
  if (toolTimeoutOverrideSec > 0) return toolTimeoutOverrideSec * 1000;
  if (isInternal) return TOOL_TIMEOUT_INTERNAL_MS;
  if (title.startsWith("mcp__")) return TOOL_TIMEOUT_MCP_MS;
  return TOOL_TIMEOUT_DEFAULT_MS;
}

function startToolTimer(
  toolCallId: string,
  title: string,
  isInternal: boolean,
  sessionId: string | undefined,
  pendingTools: string[],
): void {
  // Clear any existing timer for this tool (shouldn't happen, but be safe)
  clearToolTimer(toolCallId);

  const timeoutMs = getToolTimeoutMs(title, isInternal);
  const timer = setTimeout(() => {
    activeToolTimers.delete(toolCallId);

    logErr(`Tool TIMEOUT: ${title} (id=${toolCallId}) exceeded ${timeoutMs / 1000}s — synthesizing failure`);

    // Remove from pendingTools (same as normal completion path)
    const idx = pendingTools.indexOf(title);
    if (idx >= 0) pendingTools.splice(idx, 1);

    // Emit tool_activity completion so UI stops the spinner
    if (!isInternal) {
      sendWithSession(sessionId, {
        type: "tool_activity",
        name: title,
        status: "completed",
        toolUseId: toolCallId,
      });
    }

    // Emit a visible error so the user knows what happened
    const settingsHint = "Adjust timeout: fazm://settings/tool-timeouts";
    sendWithSession(sessionId, {
      type: "tool_result_display",
      toolUseId: toolCallId,
      name: title,
      output: `Tool "${title}" timed out after ${timeoutMs / 1000}s.\n${settingsHint}`,
    });

    // Log "Tool completed" so the Swift side decrements acpToolsRunning
    logErr(`Tool completed: ${title} (id=${toolCallId}) output=TIMEOUT after ${timeoutMs / 1000}s`);
  }, timeoutMs);

  activeToolTimers.set(toolCallId, { toolCallId, title, isInternal, sessionId, timer });
}

function clearToolTimer(toolCallId: string): void {
  const tracked = activeToolTimers.get(toolCallId);
  if (tracked) {
    clearTimeout(tracked.timer);
    activeToolTimers.delete(toolCallId);
  }
}

function clearAllToolTimers(): void {
  for (const [, tracked] of activeToolTimers) {
    clearTimeout(tracked.timer);
  }
  activeToolTimers.clear();
}

// --- Helpers ---

function send(msg: OutboundMessage): void {
  try {
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch {
    // Don't call logErr here — if pipes are broken, logErr throws too,
    // creating an infinite uncaughtException loop (see orphan bug).
  }
}

/** Send a message tagged with the query's sessionId and sessionKey for concurrent demuxing */
function sendWithSession(sessionId: string | undefined, msg: OutboundMessage): void {
  if (sessionId) {
    const sessionKey = sessionIdToKey.get(sessionId);
    send({ ...msg, sessionId, ...(sessionKey && { sessionKey }) } as OutboundMessage);
  } else {
    send(msg);
  }
}

function logErr(msg: string): void {
  try {
    process.stderr.write(`[acp-bridge] ${msg}\n`);
  } catch {
    // Pipe broken (parent process gone). Swallow to prevent infinite
    // uncaughtException recursion when this process is orphaned (PPID=1).
  }
}

// --- OMI tools relay via Unix socket ---

let fazmToolsPipePath = "";
let fazmToolsClients: Socket[] = [];

// Pending tool call promises — resolved when Swift sends back results
const pendingToolCalls = new Map<
  string,
  { resolve: (result: string) => void }
>();

let currentMode: "ask" | "act" = "act";

/** Per-query state for concurrent query support */
interface QueryContext {
  sessionId: string;
  sessionKey: string;
  abortController: AbortController;
  interruptRequested: boolean;
  lastTextContentBlockIndex: number;
  pendingBoundary: boolean;
  mode: "ask" | "act";
}

/** Active queries keyed by sessionKey */
const activeQueries = new Map<string, QueryContext>();

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

/** Start Unix socket server for fazm-tools stdio processes to connect to */
function startFazmToolsRelay(): Promise<string> {
  const pipePath = join(tmpdir(), `fazm-tools-${process.pid}.sock`);

  // Clean up any stale socket
  try {
    unlinkSync(pipePath);
  } catch {
    // ignore
  }

  return new Promise((resolve, reject) => {
    const server = createNetServer((client: Socket) => {
      fazmToolsClients.push(client);
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

            if (msg.type === "log") {
              // Forward log from fazm-tools subprocess to bridge stderr
              logErr(`[fazm-tools] ${(msg as Record<string, unknown>).message ?? ""}`);
            } else if (msg.type === "observer_card_ready") {
              // fazm-tools created an approval card mid-batch — poll immediately
              logErr("[fazm-tools] Observer card ready, triggering immediate poll");
              send({ type: "observer_poll" as any } as any);
            } else if (msg.type === "tool_use") {
              // Forward tool call to Swift via stdout, preserving session key
              const toolSessionKey = (msg as Record<string, unknown>).sessionKey as string | undefined;
              const toolMsg = {
                type: "tool_use" as const,
                callId: msg.callId,
                name: msg.name,
                input: msg.input,
              };
              if (toolSessionKey) {
                // Look up sessionId from sessionKey so sendWithSession can add both
                const entry = sessions.get(toolSessionKey);
                if (entry) {
                  sendWithSession(entry.sessionId, toolMsg);
                } else {
                  send({ ...toolMsg, sessionKey: toolSessionKey } as OutboundMessage);
                }
              } else {
                send(toolMsg as OutboundMessage);
              }

              // Create a promise that will be resolved when Swift responds
              const callId = msg.callId;
              pendingToolCalls.set(callId, {
                resolve: (result: string) => {
                  // Send result back to the fazm-tools stdio process
                  try {
                    client.write(
                      JSON.stringify({
                        type: "tool_result",
                        callId,
                        result,
                      }) + "\n"
                    );
                  } catch (err) {
                    logErr(`Failed to send tool result to fazm-tools: ${err}`);
                  }
                },
              });
            }
          } catch {
            logErr(`Failed to parse fazm-tools message: ${line.slice(0, 200)}`);
          }
        }
      });

      client.on("close", () => {
        fazmToolsClients = fazmToolsClients.filter((c) => c !== client);
      });

      client.on("error", (err) => {
        logErr(`fazm-tools client error: ${err.message}`);
      });
    });

    server.listen(pipePath, () => {
      logErr(`fazm-tools relay socket: ${pipePath}`);
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

// Per-session notification handlers — observer and other background sessions register here
// so that the main query's handler doesn't swallow their notifications.
const sessionNotificationHandlers = new Map<string, (method: string, params: unknown) => void>();

/** Look up which session a notification belongs to (ACP includes sessionId in update params) */
function getNotificationSessionId(params: unknown): string | undefined {
  const p = params as Record<string, unknown> | undefined;
  if (p?.sessionId) return p.sessionId as string;
  // Also check inside update object
  const update = p?.update as Record<string, unknown> | undefined;
  if (update?.sessionId) return update.sessionId as string;
  return undefined;
}
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

  const mode = env.ANTHROPIC_API_KEY ? "Mode A (Fazm API key)" : "Mode B (Your Claude Account / OAuth)";
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
        // Route to per-session handler if one exists (observer, background sessions)
        const notifSessionId = getNotificationSessionId(msg.params);
        const sessionHandler = notifSessionId ? sessionNotificationHandlers.get(notifSessionId) : undefined;
        if (sessionHandler) {
          sessionHandler(msg.method as string, msg.params as unknown);
        } else if (acpNotificationHandler) {
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

/** Detect ACP auth errors: explicit -32000 OR -32603 wrapping a 401/auth failure */
function isAcpAuthError(err: unknown): boolean {
  if (!(err instanceof AcpError)) return false;
  if (err.code === -32000) return true;
  // ACP sometimes wraps 401 as a generic -32603 internal error
  if (err.code === -32603) {
    const msg = err.message || "";
    return /401|failed to authenticate/i.test(msg);
  }
  return false;
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
/** Reverse map: ACP sessionId → sessionKey, for tagging outbound messages with sessionKey */
const sessionIdToKey = new Map<string, string>();

/** Register a session, maintaining the reverse map */
function registerSession(sessionKey: string, entry: { sessionId: string; cwd: string; model?: string }): void {
  // Clean up old reverse mapping if this sessionKey had a different sessionId
  const old = sessions.get(sessionKey);
  if (old && old.sessionId !== entry.sessionId) {
    sessionIdToKey.delete(old.sessionId);
  }
  sessions.set(sessionKey, entry);
  sessionIdToKey.set(entry.sessionId, sessionKey);
}

/** Unregister a session, maintaining the reverse map */
function unregisterSession(sessionKey: string): void {
  const entry = sessions.get(sessionKey);
  if (entry) {
    sessionIdToKey.delete(entry.sessionId);
  }
  sessions.delete(sessionKey);
}
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
/** Sessions that were interrupted (timeout/cancel) and may be in a broken state.
 *  When reusing such a session, we apply a TTFT watchdog — if ACP doesn't respond
 *  within 30s, the session is discarded and a fresh one is created. */
const interruptedSessions = new Set<string>();
let isInitialized = false;
let initPromise: Promise<void> | null = null;
let authMethods: AuthMethod[] = [];
let authResolve: (() => void) | null = null;
let preWarmPromise: Promise<void> | null = null;
let authRetryCount = 0;
const MAX_AUTH_RETRIES = 2;
let activeAuthPromise: Promise<void> | null = null;
let activeOAuthFlow: OAuthFlowHandle | null = null;
/** Last warmup config received from Swift — replayed after OAuth subprocess restart */
let lastWarmupConfig: { cwd?: string; sessions?: WarmupSessionConfig[] } | null = null;
/** Last api_retry info from the patched ACP entry point (carries HTTP status + typed error) */
let lastApiRetry: { httpStatus: number | null; errorType: string; attempt: number; maxRetries: number } | null = null;

// --- Auth flow (OAuth) ---

/** Restart the ACP subprocess so it picks up freshly-stored credentials.
 *  Warmup is replayed in the background — callers can proceed immediately
 *  and create their own session without waiting for all sessions to warm up. */
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

  // Replay warmup in the background so sessions are re-created/resumed.
  // Don't await — the caller (OAuth retry) should proceed immediately
  // and create its own session without waiting for unrelated sessions.
  if (lastWarmupConfig) {
    logErr("Replaying warmup after OAuth restart (background)...");
    preWarmPromise = preWarmSession(lastWarmupConfig.cwd, lastWarmupConfig.sessions);
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

      // Notify Swift immediately so it can cancel auto-reopen timers and
      // update the UI before the (slow) ACP restart + warmup completes.
      send({ type: "auth_success" });

      // Restart ACP subprocess so it picks up new credentials from Keychain
      await restartAcpProcess();
    } catch (err) {
      logErr(`OAuth flow failed: ${err}`);
      if (err instanceof OAuthTokenExchangeError) {
        // Token endpoint rejected the exchange (e.g. 403 forbidden) —
        // send a distinct message so Swift can show a specific error.
        send({ type: "auth_failed", reason: err.message, httpStatus: err.httpStatus });
      } else {
        const isTimeout = err instanceof Error && err.message.includes("timed out");
        send({ type: "auth_timeout", reason: isTimeout ? "timeout" : String(err) });
      }
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
  // Guard against concurrent calls (e.g. preWarmSession + handleQuery racing after OAuth restart)
  if (initPromise) return initPromise;

  initPromise = (async () => {
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
    if (isAcpAuthError(err)) {
      // AUTH_REQUIRED (or 401 wrapped as -32603)
      const data = (err as AcpError).data as {
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
  })();

  try {
    await initPromise;
  } finally {
    initPromise = null;
  }
}

// --- MCP server config builder ---

type McpServerConfigStdio = {
  name: string;
  command: string;
  args: string[];
  env: Array<{ name: string; value: string }>;
};

type McpServerConfigHttp = {
  name: string;
  type: "http";
  url: string;
  headers?: Array<{ name: string; value: string }>;
};

type McpServerConfig = McpServerConfigStdio | McpServerConfigHttp;

function buildMcpServers(mode: string, cwd?: string, sessionKey?: string): McpServerConfig[] {
  const servers: McpServerConfig[] = [];

  // fazm-tools (stdio, connects back via Unix socket)
  const fazmToolsEnv: Array<{ name: string; value: string }> = [
    { name: "FAZM_BRIDGE_PIPE", value: fazmToolsPipePath },
    { name: "FAZM_QUERY_MODE", value: mode },
  ];
  if (cwd) {
    fazmToolsEnv.push({ name: "FAZM_WORKSPACE", value: cwd });
  }
  if (sessionKey === "onboarding" || sessionKey === "browser-migration") {
    fazmToolsEnv.push({ name: "FAZM_ONBOARDING", value: "true" });
  }
  if (sessionKey === "observer") {
    fazmToolsEnv.push({ name: "FAZM_OBSERVER", value: "true" });
  }
  if (process.env.FAZM_VOICE_RESPONSE === "true") {
    fazmToolsEnv.push({ name: "FAZM_VOICE_RESPONSE", value: "true" });
  }
  if (sessionKey) {
    fazmToolsEnv.push({ name: "FAZM_SESSION_KEY", value: sessionKey });
  }
  servers.push({
    name: "fazm_tools",
    command: process.execPath,
    args: [fazmToolsStdioScript],
    env: fazmToolsEnv,
  });

  // Observer only gets fazm-tools — no browser/UI tools
  if (sessionKey === "observer") {
    return servers;
  }

  // Playwright MCP server
  const playwrightArgs = [playwrightCli];
  if (process.env.PLAYWRIGHT_USE_EXTENSION === "true") {
    playwrightArgs.push("--extension");
  }
  // Save snapshots to files and strip inline base64 screenshots to reduce context size
  playwrightArgs.push("--output-mode", "file", "--image-responses", "omit", "--output-dir", "/tmp/playwright-mcp");
  // Inject visual overlay on every page to indicate browser is controlled by Fazm
  const overlayInitPage = join(__dirname, "..", "browser-overlay-init-page.js");
  if (existsSync(overlayInitPage)) {
    playwrightArgs.push("--init-page", overlayInitPage);
    logErr(`Browser overlay init-page: ${overlayInitPage}`);
  } else {
    logErr(`Browser overlay init-page NOT FOUND: ${overlayInitPage}`);
  }
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

  // WhatsApp MCP (native macOS, controls WhatsApp Catalyst app via accessibility APIs)
  if (existsSync(whatsappMcpBinary)) {
    servers.push({
      name: "whatsapp",
      command: whatsappMcpBinary,
      args: [],
      env: [],
    });
  }

  // Google Workspace MCP (Python, stdio transport)
  if (existsSync(googleWorkspaceMcpPython) && existsSync(googleWorkspaceMcpMain)) {
    const googleWorkspaceMcpVenv = join(googleWorkspaceMcpDir, ".venv");
    const homeDir = process.env.HOME || "~";
    const gwsCredsDir = join(homeDir, "google_workspace_mcp");
    servers.push({
      name: "google-workspace",
      command: googleWorkspaceMcpPython,
      args: [googleWorkspaceMcpMain, "--transport", "stdio"],
      env: [
        // The bundled Python (from UV) has /install as its prefix. PYTHONHOME
        // redirects stdlib resolution to the bundled .venv which contains the
        // actual lib/python3.12 directory and site-packages.
        { name: "PYTHONHOME", value: googleWorkspaceMcpVenv },
        // Prevent Python from writing .pyc files into the app bundle, which
        // invalidates the code signature and breaks Sparkle auto-updates.
        { name: "PYTHONDONTWRITEBYTECODE", value: "1" },
        // Point to user-writable credential paths (the app bundle is read-only).
        // The google-cloud-oauth-setup skill stores client_secret.json here after
        // the user creates their personal Google Cloud OAuth app.
        { name: "GOOGLE_CLIENT_SECRET_PATH", value: join(gwsCredsDir, "client_secret.json") },
        { name: "WORKSPACE_MCP_CREDENTIALS_DIR", value: join(homeDir, ".google_workspace_mcp", "credentials") },
      ],
    });
  }

  return servers;
}

function buildMeta(systemPrompt?: string, sessionKey?: string): Record<string, unknown> {
  const meta: Record<string, unknown> = {
    claudeCode: { options: {} },
  };
  if (systemPrompt) {
    meta.systemPrompt = systemPrompt;
  }
  return { _meta: meta };
}

// --- Chat observer session: conversation batching ---

const chatObserverBuffer: Array<{ role: string; text: string }> = [];
const CHAT_OBSERVER_BATCH_SIZE = 10;       // Send batch every N turn pairs

function bufferChatObserverTurn(role: string, text: string): void {
  chatObserverBuffer.push({ role, text });
  const turnPairs = Math.floor(chatObserverBuffer.length / 2);
  logErr(`Chat observer: buffered ${role} turn (${turnPairs}/${CHAT_OBSERVER_BATCH_SIZE} pairs)`);
  if (turnPairs >= CHAT_OBSERVER_BATCH_SIZE) {
    flushChatObserverBatch();
  }
}

/** Whether the chat observer is currently processing a batch (prevents overlapping runs) */
let chatObserverRunning = false;

async function flushChatObserverBatch(): Promise<void> {
  if (chatObserverBuffer.length === 0) return;
  if (chatObserverRunning) {
    logErr("Chat observer: already running, will retry after current batch completes");
    return;
  }
  const chatObserverSession = sessions.get("observer");
  if (!chatObserverSession) {
    logErr("Chat observer: no session found, skipping batch");
    return;
  }

  chatObserverRunning = true;
  const batch = chatObserverBuffer.splice(0);
  const batchText = batch.map(t => `[${t.role}]: ${t.text}`).join("\n\n");
  const prompt = `Here are the latest conversation turns from the main session:\n\n${batchText}\n\nAnalyze these turns. Be conservative — only save things that are genuinely significant and useful for future conversations. Skip routine queries, transient context, and near-duplicates of things already saved. Each observation in this batch must cover a distinct topic — no overlapping or closely related saves. Read MEMORY.md first to check what's already known, then use your file tools (Read, Write, Edit) to save new memories as individual topic files and update MEMORY.md. Use save_observer_card to surface important observations to the user. If you detect a repeated workflow (3+ times), draft a skill.`;

  // Register a per-session notification handler so chat observer notifications
  // don't get swallowed by the main query's handler or vice versa.
  // The chat observer works silently — we only care about tool calls (which go
  // through acpResponseHandlers) and the final result. We log tool activity
  // but don't send it to Swift UI.
  sessionNotificationHandlers.set(chatObserverSession.sessionId, (method, params) => {
    if (method === "session/update") {
      const p = params as Record<string, unknown>;
      const update = p.update as Record<string, unknown> | undefined;
      const sessionUpdate = update?.sessionUpdate as string | undefined;
      // Log chat observer tool calls for debugging but don't send to Swift UI
      if (sessionUpdate === "tool_call") {
        const title = (update?.title as string) ?? "unknown";
        const status = (update?.status as string) ?? "";
        logErr(`Chat observer tool: ${title} (${status})`);
      } else if (sessionUpdate === "agent_message_chunk") {
        // Chat observer text output — silently accumulate for logging only
        const content = update?.content as { text?: string } | undefined;
        if (content?.text) {
          logErr(`Chat observer text: ${content.text.slice(0, 100)}`);
        }
      }
    }
  });

  try {
    logErr(`Chat observer: sending batch of ${batch.length} messages`);
    send({ type: "observer_status" as any, running: true } as any);
    await acpRequest("session/prompt", {
      sessionId: chatObserverSession.sessionId,
      prompt: [{ type: "text", text: prompt }],
    });
    logErr("Chat observer: batch processed successfully");

    // After chat observer completes, poll observer_activity for new cards
    // and send them to Swift. The chat observer writes cards via execute_sql.
    // Include batch metadata for PostHog tracking
    send({
      type: "observer_poll" as any,
      batchSize: batch.length,
      batchTurnCount: Math.floor(batch.length / 2),
    } as any);
  } catch (err) {
    logErr(`Chat observer: batch failed: ${err}`);
  } finally {
    sessionNotificationHandlers.delete(chatObserverSession.sessionId);
    chatObserverRunning = false;
    send({ type: "observer_status" as any, running: false } as any);

    // If new messages accumulated while we were running, flush again
    if (chatObserverBuffer.length > 0) {
      setTimeout(() => flushChatObserverBatch(), 1000);
    }
  }
}

// --- Session pre-warming ---

const DEFAULT_MODEL = "claude-sonnet-4-6";
const SONNET_MODEL = "claude-sonnet-4-6";

interface WarmupSessionConfig {
  key: string;
  model: string;
  systemPrompt?: string;
  resume?: string;  // if set, resume this session ID instead of creating a new one
}

// Stable default cwd for ACP sessions — ensures Claude Code's native memory system
// (MEMORY.md, auto memory) persists across app launches at a consistent path under
// ~/.claude/projects/. Using $HOME gives the broadest memory coverage — shared with
// CLI sessions started from home.
const DEFAULT_CWD = homedir();

async function preWarmSession(cwd?: string, sessionConfigs?: WarmupSessionConfig[], models?: string[]): Promise<void> {
  const warmCwd = cwd || DEFAULT_CWD;
  try { mkdirSync(warmCwd, { recursive: true }); } catch {}

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
            ...buildMeta(cfg.systemPrompt, cfg.key),
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
              // Set model after resume — without this the session uses the SDK default (possibly Haiku)
              await acpRequest("session/set_model", { sessionId, modelId: cfg.model });
              logErr(`Pre-warm set_model after resume: ${cfg.model}`);
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

          registerSession(cfg.key, { sessionId, cwd: warmCwd, model: cfg.model });
          await acpRequest("session/set_model", { sessionId, modelId: cfg.model });
        } catch (err) {
          if (isAcpAuthError(err)) {
            logErr(`Pre-warm failed with auth error (code=${(err as AcpError).code}), starting OAuth flow`);
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

/** Maximum number of recursive handleQuery retries (session resume + image-too-large combined) */
const MAX_QUERY_RETRIES = 2;

async function handleQuery(msg: QueryMessage, _retryDepth = 0): Promise<void> {
  // Per-session concurrency: only abort the previous query if it's the SAME sessionKey.
  // Different sessions can run concurrently.
  const incomingSessionKey = msg.sessionKey ?? (msg.model || DEFAULT_MODEL);
  const existingCtx = activeQueries.get(incomingSessionKey);
  if (existingCtx) {
    existingCtx.abortController.abort();
    sessionNotificationHandlers.delete(existingCtx.sessionId);
    activeQueries.delete(incomingSessionKey);
  }

  const abortController = new AbortController();
  // Keep legacy globals updated for backward compat (interrupt without sessionKey, etc.)
  activeAbort = abortController;
  interruptRequested = false;
  authRetryCount = 0;
  lastApiRetry = null; // Clear stale error info from previous queries

  let fullText = "";
  let fullPrompt = "";
  let isNewSession = false;
  let retryingWithHint = false;
  let sessionRetryCount = 0;
  const pendingTools: string[] = [];
  // Per-query text tracking is initialized in queryCtx below; keep legacy
  // globals for backward compat with any code paths that don't use ctx.
  lastTextContentBlockIndex = -1;
  pendingBoundary = false;

  // QueryContext will be fully initialized once we have the ACP sessionId
  let queryCtx: QueryContext | null = null;
  // Declared outside try so it's accessible in catch/finally for error reporting
  let sessionId = "";

  try {
    const mode = msg.mode ?? "act";
    currentMode = mode;
    logErr(`Query mode: ${mode}`);

    // Compute session key early so we can decide whether to wait for pre-warm
    const requestedModel = msg.model || DEFAULT_MODEL;
    const sessionKey = msg.sessionKey ?? requestedModel;

    // Wait for pre-warm only if the session we need is being warmed.
    // After OAuth restart, warmup runs in the background for main/floating/observer —
    // the retry query (e.g. onboarding) should proceed immediately without waiting.
    if (preWarmPromise) {
      const isBeingWarmed = lastWarmupConfig?.sessions?.some(s => s.key === sessionKey);
      if (sessions.has(sessionKey)) {
        // Already available, no need to wait
      } else if (isBeingWarmed) {
        logErr(`Waiting for pre-warm (need session: ${sessionKey})...`);
        await preWarmPromise;
        preWarmPromise = null;
      } else {
        logErr(`Pre-warm in progress but session ${sessionKey} not included, proceeding...`);
      }
    }

    // Ensure ACP is initialized
    await initializeAcp();
    const requestedCwd = msg.cwd || DEFAULT_CWD;

    const existing = sessions.get(sessionKey);
    if (existing) {
      // If cwd changed, invalidate this specific session
      if (existing.cwd !== requestedCwd) {
        logErr(`Cwd changed for ${sessionKey} (${existing.cwd} -> ${requestedCwd}), creating new session`);
        unregisterSession(sessionKey);
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
        registerSession(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
        isNewSession = false;
        // Set model after resume — without this the session uses the SDK default (possibly Haiku)
        await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
        logErr(`ACP session resumed: ${sessionId} (key=${sessionKey}, model=${requestedModel})`);
      } catch (resumeErr) {
        logErr(`ACP session resume failed (will create new session): ${resumeErr}`);
        // Fall through to session/new below
      }
    }
    if (!sessionId) {
      const sessionParams: Record<string, unknown> = {
        cwd: requestedCwd,
        mcpServers: buildMcpServers(mode, requestedCwd, sessionKey),
        ...buildMeta(msg.systemPrompt, sessionKey),
      };
      const sessionResult = (await acpRequest("session/new", sessionParams)) as { sessionId: string };

      sessionId = sessionResult.sessionId;
      registerSession(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
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

    // Initialize QueryContext now that we have the ACP sessionId
    queryCtx = {
      sessionId,
      sessionKey,
      abortController,
      interruptRequested: false,
      lastTextContentBlockIndex: -1,
      pendingBoundary: false,
      mode,
    };
    activeQueries.set(sessionKey, queryCtx);

    fullPrompt = msg.prompt;

    // Set up notification handler for this query, registered per-session
    // so concurrent queries don't clobber each other's handlers.
    let notificationCount = 0;
    let lastNotificationTime = Date.now();
    // Track task IDs started in THIS prompt turn vs stale ones from previous turns
    const currentTurnTaskIds = new Set<string>();
    let staleTaskNotificationCount = 0;
    const ctx = queryCtx; // capture for closure
    sessionNotificationHandlers.set(sessionId, (method: string, params: unknown) => {
      if (abortController.signal.aborted) return;

      if (method === "session/update") {
        // Ignore notifications from other sessions (e.g. stale cleanup from a
        // cancelled session).  Without this filter, stale notifications increment
        // notificationCount and defeat the TTFT watchdog, causing infinite hangs.
        const notifSessionId = getNotificationSessionId(params);
        if (notifSessionId && notifSessionId !== sessionId) {
          return;
        }

        notificationCount++;
        const now = Date.now();
        const gapMs = now - lastNotificationTime;
        lastNotificationTime = now;
        const p = params as Record<string, unknown>;
        const update = p.update as Record<string, unknown> | undefined;
        const sessionUpdate = update?.sessionUpdate as string | undefined;
        // Log every notification with gap time to detect stalls
        if (notificationCount <= 5 || gapMs > 10000 || notificationCount % 50 === 0) {
          logErr(`[NOTIFY] #${notificationCount} type=${sessionUpdate ?? "?"} gap=${gapMs}ms`);
        }
        handleSessionUpdate(p, pendingTools, (text) => {
          fullText += text;
        }, { currentTurnTaskIds, onStaleNotification: () => { staleTaskNotificationCount++; } }, ctx);
      }
    });

    // Send the prompt — retry with fresh session if stale
    const wasInterrupted = interruptedSessions.has(sessionId);
    let promptStartTime = Date.now();
    const sendPrompt = async (): Promise<void> => {
      const promptBlocks: Array<Record<string, unknown>> = [];
      // Cap image sends per session to avoid Claude's "many-image" stricter 2000px limit.
      // After MAX_IMAGE_TURNS images in a session, screenshots are silently dropped.
      const currentImageTurns = imageTurnCounts.get(sessionKey) ?? 0;
      // Screenshots are no longer sent inline — the path is appended to the prompt text
      // so the model can read the file via the Read tool if it decides the visual context is needed.
      promptBlocks.push({ type: "text", text: fullPrompt });

      const sessionPromptPayload = {
        sessionId,
        prompt: promptBlocks,
      };

      promptStartTime = Date.now();
      logErr(`[TIMING] session/prompt request sending (sessionId=${sessionId}, promptLength=${fullPrompt.length}${wasInterrupted ? ", TTFT watchdog active" : ""})`);

      // TTFT watchdog: if this session was previously interrupted, ACP may silently
      // drop the prompt (broken session state after cancel mid-tool-call). Race the
      // prompt against a 30s timer — if no notifications arrive, assume the session
      // is dead and throw so the outer retry logic can create a fresh session.
      const TTFT_WATCHDOG_MS = 5_000;
      let watchdogTimer: ReturnType<typeof setTimeout> | null = null;
      let watchdogReject: ((err: Error) => void) | null = null;

      const promptPromise = acpRequest("session/prompt", sessionPromptPayload);

      let racePromise: Promise<unknown>;
      if (wasInterrupted && !isNewSession) {
        const watchdogPromise = new Promise<never>((_, reject) => {
          watchdogReject = reject;
          watchdogTimer = setTimeout(() => {
            if (notificationCount === 0) {
              reject(new Error("TTFT_WATCHDOG: session unresponsive after interrupt — no notifications in 30s"));
            } else {
              // Notifications are flowing, session is alive — let the prompt finish normally
              watchdogTimer = null;
            }
          }, TTFT_WATCHDOG_MS);
        });
        racePromise = Promise.race([promptPromise, watchdogPromise]);
      } else {
        racePromise = promptPromise;
      }

      try {
        const promptResult = (await racePromise) as {
          stopReason: string;
          usage?: { inputTokens: number; outputTokens: number; cachedReadTokens?: number | null; cachedWriteTokens?: number | null; totalTokens: number };
          _meta?: { costUsd?: number };
        };

        // Session responded successfully — clear the interrupted mark
        if (wasInterrupted) {
          interruptedSessions.delete(sessionId);
          logErr(`Session ${sessionId} recovered after interrupt — cleared watchdog`);
        }

        const promptDurationMs = Date.now() - promptStartTime;
        const outputTokens = promptResult.usage?.outputTokens ?? 0;
        logErr(`Prompt completed: stopReason=${promptResult.stopReason} duration=${promptDurationMs}ms`);

        // Detect stale-task-response: prompt completed very fast with stale task
        // notifications and minimal output. This means Claude responded to a background
        // task completion from a previous turn instead of the user's actual question.
        // Auto-retry the prompt so the user gets a real answer.
        if (
          staleTaskNotificationCount > 0 &&
          promptDurationMs < 2000 &&
          outputTokens < 100 &&
          !isNewSession &&
          _retryDepth < 1
        ) {
          logErr(`[STALE-TASK-RETRY] Detected stale task response (duration=${promptDurationMs}ms, staleNotifications=${staleTaskNotificationCount}, outputTokens=${outputTokens}). Re-sending prompt.`);
          // Reset state for retry
          fullText = "";
          notificationCount = 0;
          staleTaskNotificationCount = 0;
          currentTurnTaskIds.clear();
          pendingTools.length = 0;
        clearAllToolTimers();
          clearAllToolTimers();
          // Re-send the same prompt; the stale task notification is now consumed
          promptStartTime = Date.now();
          const retryPayload = { sessionId, prompt: [{ type: "text", text: fullPrompt }] };
          const retryResult = (await acpRequest("session/prompt", retryPayload)) as {
            stopReason: string;
            usage?: { inputTokens: number; outputTokens: number; cachedReadTokens?: number | null; cachedWriteTokens?: number | null; totalTokens: number };
            _meta?: { costUsd?: number };
          };
          const retryDurationMs = Date.now() - promptStartTime;
          logErr(`Prompt completed (after stale-task retry): stopReason=${retryResult.stopReason} duration=${retryDurationMs}ms`);

          for (const name of pendingTools) {
            sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
        clearAllToolTimers();
          clearAllToolTimers();

          if (sessionKey !== "observer" && sessions.has("observer")) {
            bufferChatObserverTurn("user", fullPrompt);
            if (fullText.trim()) {
              bufferChatObserverTurn("assistant", fullText);
            }
          }

          const retryInputTokens = retryResult.usage?.inputTokens ?? 0;
          const retryOutputTokens = retryResult.usage?.outputTokens ?? 0;
          const retryCacheReadTokens = retryResult.usage?.cachedReadTokens ?? 0;
          const retryCacheWriteTokens = retryResult.usage?.cachedWriteTokens ?? 0;
          const retryCostUsd = retryResult._meta?.costUsd ?? 0;
          sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd: retryCostUsd, inputTokens: retryInputTokens, outputTokens: retryOutputTokens, cacheReadTokens: retryCacheReadTokens, cacheWriteTokens: retryCacheWriteTokens });
          return;
        }

        // Increment image turn counter so we know when to stop including screenshots.
        // Image turn counting removed — screenshots are now read by the model via Read tool

        // Mark any remaining pending tools as completed
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearAllToolTimers();

        // Buffer conversation turns for the observer session (skip if this IS the observer)
        if (sessionKey !== "observer" && sessions.has("observer")) {
          bufferChatObserverTurn("user", fullPrompt);
          if (fullText.trim()) {
            bufferChatObserverTurn("assistant", fullText);
          }
        }

        const inputTokens = promptResult.usage?.inputTokens ?? 0;
        const cacheReadTokens = promptResult.usage?.cachedReadTokens ?? 0;
        const cacheWriteTokens = promptResult.usage?.cachedWriteTokens ?? 0;
        const costUsd = promptResult._meta?.costUsd ?? 0;
        if (!promptResult.usage) {
          logErr(`[WARN] No usage data from ACP — cost/token tracking will be zero for this query`);
        }
        sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens });
      } catch (watchdogErr) {
        if (watchdogErr instanceof Error && watchdogErr.message.startsWith("TTFT_WATCHDOG")) {
          // Session is dead after interrupt — destroy it and retry with a fresh session
          logErr(`TTFT watchdog fired: session ${sessionId} is unresponsive after interrupt, creating fresh session`);
          unregisterSession(sessionKey);
          imageTurnCounts.delete(sessionKey);
          interruptedSessions.delete(sessionId);
          // Abort the dangling acpRequest (it will never resolve from ACP)
          if (activeAbort) activeAbort.abort();
          // Create a fresh session and retry
          const freshParams: Record<string, unknown> = {
            cwd: requestedCwd,
            mcpServers: buildMcpServers(currentMode, requestedCwd, sessionKey),
            ...buildMeta(msg.systemPrompt, sessionKey),
          };
          const freshResult = (await acpRequest("session/new", freshParams)) as { sessionId: string };
          sessionId = freshResult.sessionId;
          registerSession(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
          activeSessionId = sessionId;
          if (requestedModel) {
            await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
          }
          logErr(`Fresh session created: ${sessionId} (key=${sessionKey}) — retrying prompt`);
          // Reset notification state for the retry
          notificationCount = 0;
          // Retry the prompt on the fresh session (no watchdog needed — it's brand new)
          const retryPayload = { sessionId, prompt: [{ type: "text", text: fullPrompt }] };
          promptStartTime = Date.now();
          const retryResult = (await acpRequest("session/prompt", retryPayload)) as {
            stopReason: string;
            usage?: { inputTokens: number; outputTokens: number; cachedReadTokens?: number | null; cachedWriteTokens?: number | null; totalTokens: number };
            _meta?: { costUsd?: number };
          };
          const retryDurationMs = Date.now() - promptStartTime;
          logErr(`Prompt completed (after watchdog recovery): stopReason=${retryResult.stopReason} duration=${retryDurationMs}ms`);

          for (const name of pendingTools) {
            sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
        clearAllToolTimers();
          clearAllToolTimers();

          if (sessionKey !== "observer" && sessions.has("observer")) {
            bufferChatObserverTurn("user", fullPrompt);
            if (fullText.trim()) {
              bufferChatObserverTurn("assistant", fullText);
            }
          }

          const inputTokens = retryResult.usage?.inputTokens ?? 0;
          const outputTokens = retryResult.usage?.outputTokens ?? 0;
          const cacheReadTokens = retryResult.usage?.cachedReadTokens ?? 0;
          const cacheWriteTokens = retryResult.usage?.cachedWriteTokens ?? 0;
          const costUsd = retryResult._meta?.costUsd ?? 0;
          if (!retryResult.usage) {
            logErr(`[WARN] No usage data from ACP — cost/token tracking will be zero for this query`);
          }
          sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens });
        } else {
          throw watchdogErr;
        }
      } finally {
        if (watchdogTimer) clearTimeout(watchdogTimer);
      }
    };

    try {
      await sendPrompt();
    } catch (err) {
      const elapsedMs = Date.now() - promptStartTime;
      logErr(`[TIMING] Query failed after ${elapsedMs}ms, notifications received: ${notificationCount}, fullText: ${fullText.length} chars, error: ${err instanceof Error ? err.message : String(err)}`);
      if (abortController.signal.aborted) {
        if (queryCtx?.interruptRequested ?? interruptRequested) {
          for (const name of pendingTools) {
            sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
        clearAllToolTimers();
          clearAllToolTimers();
          logErr(
            `Query interrupted by user, sending partial result (${fullText.length} chars)`
          );
          sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 });
        } else {
          logErr("Query aborted (superseded by new query)");
        }
        return;
      }
      // AUTH_REQUIRED: -32000 explicitly, or -32603 wrapping a 401
      if (isAcpAuthError(err)) {
        if (authRetryCount >= MAX_AUTH_RETRIES) {
          logErr(`session/prompt auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
          sendWithSession(sessionId, { type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
          return;
        }
        authRetryCount++;
        logErr(`session/prompt failed with auth error (code=${(err as AcpError).code}), starting OAuth flow (attempt ${authRetryCount})`);
        unregisterSession(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        msg.resume = undefined;
        await startAuthFlow();
        return handleQuery(msg, _retryDepth + 1);
      }
      const errMsg = err instanceof Error ? err.message : String(err);

      // Credit/billing/rate limit exhausted — do NOT retry, surface immediately.
      // Prefer structured detection from api_retry (HTTP status + error type),
      // fall back to regex on error message text.
      const apiRetryInfo = lastApiRetry as { httpStatus: number | null; errorType: string } | null;
      const apiRetryErrorType = apiRetryInfo?.errorType;
      const apiRetryHttpStatus = apiRetryInfo?.httpStatus;
      const isStructuredCreditError = apiRetryErrorType === "billing_error" || apiRetryErrorType === "rate_limit"
        || apiRetryHttpStatus === 402 || apiRetryHttpStatus === 429;
      const isRegexCreditExhausted = /credit balance is too low|insufficient.*(credit|funds|balance)|you've hit your limit|you have hit your limit|hit your.*limit|rate.?limit.*rejected|out of extra usage|unable to verify.*membership/i.test(errMsg);
      if (isStructuredCreditError || isRegexCreditExhausted) {
        const detectionMethod = isStructuredCreditError
          ? `structured (httpStatus=${apiRetryHttpStatus}, errorType=${apiRetryErrorType})`
          : "regex";
        logErr(`Credit/rate limit exhausted (${detectionMethod}), not retrying: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearAllToolTimers();
        sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
        lastApiRetry = null;
        return;
      }

      // Image/content too large — retry on the SAME session without the image,
      // with a hint so the model can adjust its approach.
      const isImageError = apiRetryErrorType === "image_error"
        || /image.*(too large|too big|exceeds.*limit|dimension)|unable to resize image|content too long|at least one of the image/i.test(errMsg);
      if (isImageError && sessionId && !retryingWithHint) {
        logErr(`session/prompt failed with image error, retrying on same session without image: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearAllToolTimers();

        // Retry with a hint
        retryingWithHint = true;
        fullPrompt = `The previous request failed because an image was too large: "${errMsg}". Please continue with a different approach — avoid reading large image files directly. Use smaller outputs or text-based tools instead.`;
        try {
          await sendPrompt();
        } catch (retryErr) {
          const retryErrMsg = retryErr instanceof Error ? retryErr.message : String(retryErr);
          const isStillImageError = /image.*(too large|too big|exceeds.*limit|dimension)|unable to resize image|content too long|at least one of the image/i.test(retryErrMsg);
          if (isStillImageError && _retryDepth < MAX_QUERY_RETRIES) {
            // The session history itself contains oversized images — start a fresh session.
            logErr(`Retry without image also failed with image-too-large — session history poisoned, starting new session (depth=${_retryDepth}): ${retryErrMsg}`);
            unregisterSession(sessionKey);
            imageTurnCounts.delete(sessionKey);
            activeSessionId = "";
            msg.resume = undefined;
            fullPrompt = msg.prompt;
            return handleQuery(msg, _retryDepth + 1);
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
      // Skip retry for errors that are clearly not session-related (rate limits, usage errors,
      // etc.) — retrying just wastes time and can trigger spurious OAuth flows.
      const isStructuredNonRetryable = apiRetryErrorType === "billing_error" || apiRetryErrorType === "rate_limit"
        || apiRetryErrorType === "invalid_request";
      const isNonRetryable = isStructuredNonRetryable || /usage|limit|resets\s|credit|quota|exhausted|rejected/i.test(errMsg);
      if (!isNewSession && sessionId && sessionRetryCount === 0 && !isNonRetryable && _retryDepth < MAX_QUERY_RETRIES) {
        sessionRetryCount++;
        logErr(`session/prompt failed with existing session, retrying with session resume (depth=${_retryDepth}): ${err}`);
        const failedSessionId = sessionId;
        unregisterSession(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        // Attempt to resume the failed session — the ACP SDK can reload
        // conversation history from ~/.claude/projects/ session files.
        // If resume fails, the resume path falls back to session/new automatically.
        msg.resume = failedSessionId;
        return handleQuery(msg, _retryDepth + 1);
      }
      // Non-retryable errors: surface the raw message to the user.
      // Only use credit_exhausted for actual billing/rate errors;
      // everything else goes as a generic error so the user sees the real message.
      if (isNonRetryable) {
        logErr(`Non-retryable error, surfacing to user: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearAllToolTimers();
        const isBillingOrRate = isStructuredNonRetryable
          && (apiRetryErrorType === "billing_error" || apiRetryErrorType === "rate_limit");
        const isRegexBilling = /credit|balance|quota|exhausted|hit your.*limit|out of extra usage/i.test(errMsg);
        if (isBillingOrRate || isRegexBilling) {
          sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
        } else {
          sendWithSession(sessionId, { type: "error", message: errMsg });
        }
        lastApiRetry = null;
        return;
      }
      throw err;
    }
  } catch (err: unknown) {
    if (abortController.signal.aborted) {
      if (queryCtx?.interruptRequested ?? interruptRequested) {
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearAllToolTimers();
        sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 });
      }
      return;
    }
    // AUTH_REQUIRED: -32000 explicitly, or -32603 wrapping a 401
    if (isAcpAuthError(err)) {
      if (authRetryCount >= MAX_AUTH_RETRIES) {
        logErr(`Query auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
        sendWithSession(sessionId, { type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
        return;
      }
      authRetryCount++;
      logErr(`Query failed with auth error (code=${(err as AcpError).code}), starting OAuth flow (attempt ${authRetryCount})`);
      await startAuthFlow();
      return handleQuery(msg, _retryDepth + 1);
    }
    const errMsg = err instanceof Error ? err.message : String(err);
    // Credit balance or rate limit exhausted — surface as specific type (outer catch).
    // Use structured api_retry info when available, regex as fallback.
    const outerApiRetryInfo = lastApiRetry as { httpStatus: number | null; errorType: string } | null;
    const outerApiErrorType = outerApiRetryInfo?.errorType;
    const outerApiHttpStatus = outerApiRetryInfo?.httpStatus;
    const outerStructuredCredit = outerApiErrorType === "billing_error" || outerApiErrorType === "rate_limit"
      || outerApiHttpStatus === 402 || outerApiHttpStatus === 429;
    const outerRegexCredit = /credit balance is too low|insufficient.*(credit|funds|balance)|you've hit your limit|you have hit your limit|hit your.*limit|rate.?limit.*rejected|out of extra usage|unable to verify.*membership/i.test(errMsg);
    if (outerStructuredCredit || outerRegexCredit) {
      logErr(`Credit/rate limit exhausted (outer): ${errMsg}`);
      sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
      lastApiRetry = null;
      return;
    }
    logErr(`Query error: ${errMsg}`);
    // Show the raw error message so the user can see what actually went wrong
    sendWithSession(sessionId, { type: "error", message: errMsg });
    lastApiRetry = null;
  } finally {
    if (activeAbort === abortController) {
      activeAbort = null;
    }
    // Clean up per-session state
    if (queryCtx) {
      sessionNotificationHandlers.delete(queryCtx.sessionId);
      activeQueries.delete(queryCtx.sessionKey);
    }
    // Legacy: clear global handler if it's still set (backward compat)
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
  onText: (text: string) => void,
  taskTracking?: { currentTurnTaskIds: Set<string>; onStaleNotification: () => void },
  ctx?: QueryContext
): void {
  const sid = ctx?.sessionId;
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
            sendWithSession(sid, { type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
          clearAllToolTimers();
        }

        // Signal a boundary between text blocks:
        // - when content block index changes within a single response
        // - when resuming text after a tool call (pendingBoundary)
        const effPendingBoundary = ctx ? ctx.pendingBoundary : pendingBoundary;
        const effLastIndex = ctx ? ctx.lastTextContentBlockIndex : lastTextContentBlockIndex;
        if (effPendingBoundary || (blockIndex >= 0 && effLastIndex >= 0 && blockIndex !== effLastIndex)) {
          sendWithSession(sid, { type: "text_block_boundary" });
          if (ctx) ctx.pendingBoundary = false; else pendingBoundary = false;
        }
        if (blockIndex >= 0) {
          if (ctx) ctx.lastTextContentBlockIndex = blockIndex; else lastTextContentBlockIndex = blockIndex;
        }

        onText(text);
        sendWithSession(sid, { type: "text_delta", text });
      }
      break;
    }

    case "agent_thought_chunk": {
      const content = update.content as { type: string; text?: string } | undefined;
      const text = content?.text ?? "";
      if (text) {
        sendWithSession(sid, { type: "thinking_delta", text });
      }
      break;
    }

    case "tool_call": {
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

      // ToolSearch is an internal ACP tool for loading deferred tool schemas.
      // Hide it from the UI: don't set pendingBoundary (which would split
      // the text into separate bubbles) and don't send tool_activity events.
      const isInternalTool = title === "ToolSearch";
      if (!isInternalTool) {
        // Mark that text after tool use should get a boundary separator
        if (ctx) ctx.pendingBoundary = true; else pendingBoundary = true;
      }

      if (status === "pending" || status === "in_progress") {
        if (!isInternalTool) {
          pendingTools.push(title);
          sendWithSession(sid, {
            type: "tool_activity",
            name: title,
            status: "started",
            toolUseId: toolCallId,
          });

          // Extract input from rawInput if available
          const rawInput = update.rawInput as Record<string, unknown> | undefined;
          if (rawInput && Object.keys(rawInput).length > 0) {
            sendWithSession(sid, {
              type: "tool_activity",
              name: title,
              status: "started",
              toolUseId: toolCallId,
              input: rawInput,
            });
          }
        }

        // Log tool start with input summary so hung tools are diagnosable
        const rawInput = update.rawInput as Record<string, unknown> | undefined;
        const inputSummary = rawInput ? Object.entries(rawInput).map(([k, v]) => {
          const s = typeof v === "string" ? v : JSON.stringify(v);
          return `${k}=${s && s.length > 120 ? s.slice(0, 120) + "…" : s}`;
        }).join(", ") : "";
        logErr(`Tool started: ${title} (id=${toolCallId}, kind=${kind})${inputSummary ? ` [${inputSummary}]` : ""}`);

        // Start timeout watchdog for this tool
        startToolTimer(toolCallId, title, isInternalTool, sid, pendingTools);
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

      // ToolSearch is hidden from UI (see tool_call case)
      const isInternalTool = title === "ToolSearch";

      if (status === "completed" || status === "failed" || status === "cancelled") {
        // Cancel the timeout watchdog (tool finished normally)
        clearToolTimer(toolCallId);

        // Remove from pending
        const idx = pendingTools.indexOf(title);
        if (idx >= 0) pendingTools.splice(idx, 1);

        if (!isInternalTool) {
          sendWithSession(sid, {
            type: "tool_activity",
            name: title,
            status: "completed",
            toolUseId: toolCallId,
          });
        }

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

        if (output && !isInternalTool) {
          const truncated =
            output.length > 2000
              ? output.slice(0, 2000) + "\n... (truncated)"
              : output;
          sendWithSession(sid, {
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
            sendWithSession(sid, { type: "thinking_delta", text: entry.content + "\n" });
          }
        }
      }
      break;
    }

    // --- Forwarded events (previously dropped by acp-agent.js) ---

    case "compact_boundary": {
      const trigger = (update.trigger as string) ?? "auto";
      const preTokens = (update.preTokens as number) ?? 0;
      sendWithSession(sid, { type: "compact_boundary", trigger, preTokens });
      logErr(`Compact boundary: trigger=${trigger}, preTokens=${preTokens}`);
      break;
    }

    case "status_change": {
      const status = (update.status as string | null) ?? null;
      sendWithSession(sid, { type: "status_change", status });
      logErr(`Status change: ${status}`);
      break;
    }

    case "compaction_start": {
      sendWithSession(sid, { type: "status_change", status: "compacting" });
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
      if (taskTracking) taskTracking.currentTurnTaskIds.add(taskId);
      sendWithSession(sid, { type: "task_started", taskId, description });
      logErr(`Task started: ${taskId} — ${description}`);
      break;
    }

    case "task_notification": {
      const taskId = (update.taskId as string) ?? "";
      const status = (update.status as string) ?? "";
      const summary = (update.summary as string) ?? "";
      // Detect stale task notifications from previous turns
      if (taskTracking && !taskTracking.currentTurnTaskIds.has(taskId)) {
        taskTracking.onStaleNotification();
        logErr(`Task notification: ${taskId} ${status} [STALE — from previous turn]`);
        sendWithSession(sid, { type: "task_notification", taskId, status, summary });
        break;
      }
      sendWithSession(sid, { type: "task_notification", taskId, status, summary });
      logErr(`Task notification: ${taskId} ${status}`);
      break;
    }

    case "tool_progress": {
      const toolUseId = (update.toolUseId as string) ?? "";
      const toolName = (update.toolName as string) ?? "";
      const elapsed = (update.elapsedTimeSeconds as number) ?? 0;
      sendWithSession(sid, { type: "tool_progress", toolUseId, toolName, elapsedTimeSeconds: elapsed });
      break;
    }

    case "tool_use_summary": {
      const summary = (update.summary as string) ?? "";
      const ids = (update.precedingToolUseIds as string[]) ?? [];
      sendWithSession(sid, { type: "tool_use_summary", summary, precedingToolUseIds: ids });
      logErr(`Tool use summary: ${summary.slice(0, 100)}`);
      break;
    }

    case "rate_limit": {
      const rawStatus = (update.status as string) ?? "unknown";
      const status = (["allowed", "allowed_warning", "rejected"].includes(rawStatus) ? rawStatus : "unknown") as "allowed" | "allowed_warning" | "rejected" | "unknown";
      const resetsAt = (update.resetsAt as number) ?? null;
      const rateLimitType = (update.rateLimitType as string) ?? null;
      const utilization = (update.utilization as number) ?? null;
      const overageStatus = (update.overageStatus as string) ?? null;
      const overageDisabledReason = (update.overageDisabledReason as string) ?? null;
      const isUsingOverage = (update.isUsingOverage as boolean) ?? false;
      const surpassedThreshold = (update.surpassedThreshold as number) ?? null;
      sendWithSession(sid, {
        type: "rate_limit",
        status,
        resetsAt,
        rateLimitType,
        utilization,
        overageStatus,
        overageDisabledReason,
        isUsingOverage,
        surpassedThreshold,
      });
      logErr(`Rate limit: status=${status}, type=${rateLimitType}, utilization=${utilization}, resets=${resetsAt ? new Date(resetsAt * 1000).toISOString() : "n/a"}`);
      break;
    }

    case "api_retry": {
      // Structured error info from SDK: HTTP status code + typed error category
      const httpStatus = (update.httpStatus as number | null) ?? null;
      const errorType = (update.errorType as string) ?? "unknown";
      const attempt = (update.attempt as number) ?? 0;
      const maxRetries = (update.maxRetries as number) ?? 0;
      const retryDelayMs = (update.retryDelayMs as number) ?? 0;
      lastApiRetry = { httpStatus, errorType, attempt, maxRetries };
      logErr(`API retry: httpStatus=${httpStatus}, error=${errorType}, attempt=${attempt}/${maxRetries}, delay=${retryDelayMs}ms`);
      sendWithSession(sid, { type: "api_retry", httpStatus, errorType, attempt, maxRetries, retryDelayMs });
      break;
    }

    case "usage_update":
      // Token usage / context window update from ACP v0.25+ — handled by patched entry point
      break;

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
    logCrash(`Caught ${code} (pipe closed) — exiting`);
    process.exit(0);
  }
  logCrash(`Uncaught exception: ${err.message}\n${err.stack ?? ""}`);
  logErr(`Uncaught exception: ${err.message}\n${err.stack ?? ""}`);
  process.exit(1);
});

process.stderr.on("error", (err) => {
  const code = (err as NodeJS.ErrnoException).code;
  if (code === "EPIPE" || code === "ERR_STREAM_DESTROYED") {
    logCrash("stderr EPIPE — parent disconnected, exiting");
    process.exit(0);
  }
  logCrash(`stderr error: ${err.message}`);
});

process.stdout.on("error", (err) => {
  const code = (err as NodeJS.ErrnoException).code;
  if (code === "EPIPE" || code === "ERR_STREAM_DESTROYED") {
    logCrash("stdout EPIPE — parent disconnected, exiting");
    process.exit(0);
  }
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
  logErr(`MCP versions: playwright=${playwrightVersion}, macos-use=${existsSync(macosUseBinary) ? "bundled" : "missing"}, whatsapp=${existsSync(whatsappMcpBinary) ? "bundled" : "missing"}, google-workspace=${existsSync(googleWorkspaceMcpPython) ? "bundled" : "missing"}`);
  logErr(`Playwright MCP config: extension=${process.env.PLAYWRIGHT_USE_EXTENSION ?? "false"}, token=${process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN ? "set" : "unset"}, outputMode=file, imageResponses=omit, outputDir=/tmp/playwright-mcp`);

  // Check Google Workspace MCP availability (venv bundled in app)
  logErr(`Google Workspace MCP: ${existsSync(googleWorkspaceMcpPython) ? "ready" : "not available"}`);

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

  // 1. Start Unix socket for fazm-tools relay
  fazmToolsPipePath = await startFazmToolsRelay();
  logErr("fazm-tools relay started");

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

      case "interrupt": {
        const targetKey = (msg as { sessionKey?: string }).sessionKey;
        if (targetKey) {
          // Per-session interrupt: only abort the targeted session
          const ctx = activeQueries.get(targetKey);
          if (ctx) {
            logErr(`Interrupt requested for session key=${targetKey} (sessionId=${ctx.sessionId})`);
            ctx.interruptRequested = true;
            ctx.abortController.abort();
            acpNotify("session/cancel", { sessionId: ctx.sessionId });
            interruptedSessions.add(ctx.sessionId);
            logErr(`Session ${ctx.sessionId} marked as interrupted (will apply TTFT watchdog on next reuse)`);
          } else {
            logErr(`Interrupt requested for session key=${targetKey} but no active query found`);
          }
        } else {
          // Legacy: no sessionKey specified, interrupt all active queries
          logErr("Interrupt requested by user (all sessions)");
          interruptRequested = true;
          if (activeAbort) activeAbort.abort();
          for (const [key, ctx] of activeQueries) {
            ctx.interruptRequested = true;
            ctx.abortController.abort();
            acpNotify("session/cancel", { sessionId: ctx.sessionId });
            interruptedSessions.add(ctx.sessionId);
            logErr(`Session ${ctx.sessionId} (key=${key}) marked as interrupted`);
          }
          if (activeSessionId && !activeQueries.size) {
            // Fallback for legacy single-query path
            acpNotify("session/cancel", { sessionId: activeSessionId });
            interruptedSessions.add(activeSessionId);
            logErr(`Session ${activeSessionId} marked as interrupted (legacy fallback)`);
          }
        }
        break;
      }

      case "cancel_auth":
        logErr("Cancel auth requested by user");
        if (activeOAuthFlow) {
          activeOAuthFlow.cancel();
          activeOAuthFlow = null;
        }
        activeAuthPromise = null;
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

      case "transferSession": {
        const { fromKey, toKey } = msg as import("./protocol.js").TransferSessionMessage;
        if (fromKey && toKey && sessions.has(fromKey)) {
          const entry = sessions.get(fromKey)!;
          unregisterSession(fromKey);
          registerSession(toKey, entry);
          // Transfer image turn count too
          const imgCount = imageTurnCounts.get(fromKey);
          if (imgCount !== undefined) {
            imageTurnCounts.delete(fromKey);
            imageTurnCounts.set(toKey, imgCount);
          }
          logErr(`Session transferred: ${fromKey} -> ${toKey} (sessionId=${entry.sessionId})`);
        } else {
          logErr(`Session transfer skipped: ${fromKey} not found`);
        }
        break;
      }

      case "resetSession": {
        const key = (msg as any).sessionKey;
        if (key && sessions.has(key)) {
          const oldSessionId = sessions.get(key)?.sessionId;
          if (oldSessionId) interruptedSessions.delete(oldSessionId);
          unregisterSession(key);
          imageTurnCounts.delete(key);
          logErr(`Session reset: ${key}`);

          // Immediately pre-warm a new session so the first query doesn't wait
          const savedCfg = lastWarmupConfig?.sessions?.find((s) => s.key === key);
          if (savedCfg) {
            // Strip resume — we want a fresh session, not the old one.
            // Also strip <conversation_history> from the system prompt so the
            // new chat starts without context from the previous conversation.
            let freshPrompt = savedCfg.systemPrompt;
            if (freshPrompt) {
              freshPrompt = freshPrompt.replace(/\n\n<conversation_history>[\s\S]*?<\/conversation_history>/, "");
            }
            const freshCfg = { ...savedCfg, resume: undefined, systemPrompt: freshPrompt };
            logErr(`Pre-warming new session for ${key} after reset...`);
            preWarmSession(lastWarmupConfig!.cwd, [freshCfg]).catch((err) =>
              logErr(`Post-reset pre-warm failed for ${key}: ${err}`)
            );
          }
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

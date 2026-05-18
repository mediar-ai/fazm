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
import { unlinkSync, appendFileSync, existsSync, watch, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync, renameSync, copyFileSync } from "fs";
import type {
  InboundMessage,
  OutboundMessage,
  QueryMessage,
  WarmupMessage,
  AuthMethod,
} from "./protocol.js";
import { startOAuthFlow, OAuthTokenExchangeError, readStoredCredentials, type OAuthFlowHandle } from "./oauth-flow.js";
import { startCodexOAuthFlow, type CodexOAuthFlowHandle } from "./codex-oauth-flow.js";
import { CodexProvider } from "./codex-provider.js";
import {
  handleCodexQuery,
  isCodexModel,
  dropCodexSession,
  interruptCodexSession,
  interruptAllCodexSessions,
  codexSessionCount,
  clearCodexSessions,
} from "./codex-query.js";
import { classifyApiFailure } from "./api-failure.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

// --- Parent-death watchdog ---
// If the Fazm Swift app dies (crash, force-kill, run.sh restart without graceful
// shutdown), our PPID flips to 1 (launchd) and we'd otherwise live forever, dragging
// the whole patched-acp-entry + claude CLI + 4 MCP servers chain with us. Poll PPID
// every 5s; on parent death, walk the descendant tree, SIGTERM everyone, then exit.
// Root cause of the 20+ orphan ACP bridges observed Apr 30 2026.
const __watchdogStartPpid = process.ppid;
function __killBridgeTreeAndExit(reason: string): void {
  console.error(`[bridge] watchdog: ${reason}, killing children and exiting`);
  function killTree(pid: number) {
    try {
      const out = execSync(`pgrep -P ${pid}`, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      const children = out.trim().split("\n").filter(Boolean).map(Number);
      for (const c of children) killTree(c);
      try { process.kill(pid, "SIGTERM"); } catch (_) {}
    } catch (_) { /* pgrep returns 1 when no children — ignore */ }
  }
  try { killTree(process.pid); } catch (_) {}
  setTimeout(() => process.exit(0), 1500).unref();
}
setInterval(() => {
  if (process.ppid === 1 && __watchdogStartPpid !== 1) {
    __killBridgeTreeAndExit("parent (Swift app) died, PPID flipped to 1");
  }
}, 5000).unref();

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

// browser-harness MCP — Python server bundled under Contents/Resources/browser-harness/
// Provides direct CDP browser control via a managed Chrome with a persistent
// profile at ~/.fazm/browser-harness/profile. Mutually exclusive with the
// playwright-extension flow: when FAZM_BROWSER_MODE=managed, playwright is
// dropped from the MCP list and browser-harness takes its place.
const browserHarnessMcpDir = join(resourcesDir, "browser-harness");
const browserHarnessMcpPython = join(browserHarnessMcpDir, ".venv", "bin", "python3");
const browserHarnessMcpServer = join(browserHarnessMcpDir, "server.py");

// ai-browser-profile — Python lib for importing cookies/localStorage from
// real Chromium browsers (Chrome/Arc/Brave/Edge) into the browser-harness Chrome.
const aiBrowserProfileDir = join(resourcesDir, "ai-browser-profile");
const aiBrowserProfilePython = join(aiBrowserProfileDir, ".venv", "bin", "python3");

// Which browser automation flow is active. "extension" = the existing
// Playwright + Chrome-extension flow (default). "managed" = browser-harness
// driving its own Chrome instance, optionally seeded with cookies via
// ai-browser-profile.
const browserMode = (process.env.FAZM_BROWSER_MODE || "extension").toLowerCase();


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
  // Auto-cancel disabled (May 12 2026): killed too many legitimate long-running
  // Task subagents and Bash deploys, leaving a silent empty AI bubble. Re-enable
  // by removing this early return.
  void toolCallId; void title; void isInternal; void sessionId; void pendingTools;
  return;
  // eslint-disable-next-line no-unreachable
  clearToolTimer(toolCallId);

  const timeoutMs = getToolTimeoutMs(title, isInternal);
  const timer = setTimeout(() => {
    activeToolTimers.delete(toolCallId);

    // Defensive: if the tool already completed in the brief window between
    // the timer firing and this callback executing, don't synthesize a
    // failure or kill the session. inFlightTools.delete() runs in the
    // tool_call_update terminal branch; absence here means the tool finished.
    if (!inFlightTools.has(toolCallId)) {
      logErr(`Tool watchdog: ${title} (id=${toolCallId}) already completed — skipping synthetic timeout`);
      return;
    }

    logErr(`Tool TIMEOUT: ${title} (id=${toolCallId}) exceeded ${timeoutMs / 1000}s — synthesizing failure`);

    // Drop from inFlightTools so the long-running-tool heartbeat stops
    // emitting `Tool heartbeat: ... still running, elapsed=Ns` forever.
    // Before this delete, stale entries accumulated across timeouts and the
    // heartbeat kept logging tools for days (saw elapsed=73522s in prod).
    // Each heartbeat also surfaced as `status_change` → Swift logged a
    // spurious "Context compaction finished" every 30s per stuck entry.
    inFlightTools.delete(toolCallId);

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

    // Unblock the agent loop. Without this, the SDK is still waiting for the
    // hung MCP tool's response, the model can't continue, and the parent
    // ACPBridge.waitForMessage falls through to its 180s inactivity timeout.
    // Mirror the user-interrupt cleanup path: abort the in-flight query,
    // notify the SDK to cancel the session, mark it dirty, and unregister so
    // the next prompt forces a fresh session via priorContext replay.
    if (sessionId) {
      const sessionKey = sessionIdToKey.get(sessionId);
      const ctx = sessionKey ? activeQueries.get(sessionKey) : undefined;
      if (ctx && !ctx.interruptRequested) {
        logErr(
          `Tool watchdog auto-interrupting session ${sessionId} (key=${sessionKey ?? "?"}) ` +
            `due to ${title} hang — aborting query and forcing fresh session next prompt`,
        );
        ctx.interruptRequested = true;
        ctx.abortController.abort();
        acpNotify("session/cancel", { sessionId: ctx.sessionId });
        interruptedSessions.add(ctx.sessionId);
        if (sessionKey) {
          unregisterSession(sessionKey);
          imageTurnCounts.delete(sessionKey);
        }

        // Surface the cancel as a structured event so the UI can render a
        // distinct card. The user wanted tool-hang detection to "cancel
        // cleanly and visibly" — this is the visible part. tool_result_display
        // already shows the error inline; this gives the renderer a card.
        sendWithSession(sessionId, {
          type: "tool_hang_canceled",
          toolName: title,
          toolUseId: toolCallId,
          durationSeconds: timeoutMs / 1000,
          reason: `The "${title}" tool didn't respond within ${timeoutMs / 1000}s, so I canceled this turn. You can retry, or adjust the timeout in Settings.`,
          sessionKey,
        });
      } else if (!ctx) {
        logErr(
          `Tool watchdog: no active query for session ${sessionId} ` +
            `(already cleaned up?) — UI notified, agent loop unaffected`,
        );
      }
    }
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

// Clear watchdogs only for tools that belong to the given session. The query
// success/error paths in handleQuery used to call clearAllToolTimers(), which
// wiped watchdogs for every other session's in-flight tools. With multiple
// detached pop-out chats open, ANY session ending its turn would nuke the
// 120s tool watchdog for tools running on the others — Playwright browser_tabs
// in another pop-out would then hang forever instead of getting auto-cancelled
// (May 11 2026 investigation: every long-hang pattern in /tmp/fazm.log traced
// back to a peer session's success or error path firing clearAllToolTimers).
function clearToolTimersForSession(sessionId: string | undefined): void {
  if (!sessionId) return;
  const toRemove: string[] = [];
  for (const [id, tracked] of activeToolTimers) {
    if (tracked.sessionId === sessionId) {
      clearTimeout(tracked.timer);
      toRemove.push(id);
    }
  }
  for (const id of toRemove) {
    activeToolTimers.delete(id);
    inFlightTools.delete(id);
  }
  // Tasks (Task subagents) are tracked separately — clear their timers too
  // when the parent session ends, so dead subagents from prior turns don't
  // fire on a fresh turn.
  clearTaskTimersForSession(sessionId);
}

// --- Subagent task watchdog (Task tool / local_agent) ---
//
// Why this exists: when the model invokes the `Task` tool to spawn a
// subagent, the Claude Agent SDK holds the parent `prompt()` open until the
// subagent fires its `task_notification`. If the subagent dies silently
// (process killed, crashed mid-init, hit a path that exits without writing
// its `.output` file), no notification ever arrives. The SDK's
// `hasRunningDeferrableTasks` keeps returning true forever, `state` never
// transitions to `idle`, the ACP adapter's `prompt()` loop never returns,
// and the bridge's `await acpRequest("session/prompt", …)` hangs. From the
// UI: pop-out spinner forever, no AI response saved, no recovery.
//
// This is a known upstream gap — see agentclientprotocol/claude-agent-acp
// #336 / #497 / #603 / #630 and anthropics/claude-code #44783 / #58637.
// No upstream fix has shipped (as of May 13 2026). Maintainer's recommended
// workaround is "don't use background tasks for long work" — not usable
// here because subagents are a default tool.
//
// Why this is liveness-aware (and not a fixed timer): we already tried
// blanket timers twice — the 60s Swift hang detector (removed May 3) and
// the per-tool auto-cancel (disabled May 12). Both killed legitimate slow
// work because they fired on stream silence alone. This watchdog only
// declares the subagent dead when there's positive evidence: the
// `.output` file the SDK creates for the subagent is 0 bytes AND has not
// been touched for > TASK_STALE_THRESHOLD_MS. If the file is growing (or
// recently touched), we re-arm and check again later — so a legitimate
// 90-minute subagent run won't get killed.
//
// Path layout per the Claude Agent SDK:
//   /private/tmp/claude-501/<cwd-with-slashes-replaced-by-dashes>/<subagent-session-uuid>/tasks/<task-id>.output
//
// We don't have the cwd or subagent session UUID handy in the bridge, so
// we glob across the tree by task-id. The set is small (tens of dirs).

interface TrackedTask {
  taskId: string;
  description: string;
  sessionId: string;
  sessionKey: string;
  startedAt: number;
  timer: ReturnType<typeof setTimeout>;
}

const activeTaskTimers = new Map<string, TrackedTask>();

// How often to check whether a still-tracked subagent task is alive.
// Conservative — re-arms after each "still alive" check, so this is the
// granularity of the death check, not a hard deadline.
const TASK_LIVENESS_CHECK_MS = 30 * 60 * 1000; // 30 min

// The .output file must be 0 bytes AND its mtime older than this for us
// to declare the subagent dead. 10 min gives plenty of headroom for a
// slow-starting subagent that takes a while before its first write.
const TASK_STALE_THRESHOLD_MS = 10 * 60 * 1000; // 10 min

// User-configurable override (seconds) — set to 0 to disable the watchdog.
const taskWatchdogOverrideSec = process.env.FAZM_TASK_LIVENESS_CHECK_SECONDS
  ? parseInt(process.env.FAZM_TASK_LIVENESS_CHECK_SECONDS, 10)
  : 0;
const taskWatchdogDisabled = taskWatchdogOverrideSec < 0;

function getTaskLivenessCheckMs(): number {
  if (taskWatchdogOverrideSec > 0) return taskWatchdogOverrideSec * 1000;
  return TASK_LIVENESS_CHECK_MS;
}

const CLAUDE_TMP_ROOT = "/private/tmp/claude-501";

// Walk /private/tmp/claude-501/*/*/tasks/<taskId>.output and return the first
// match. Cheap — directory count is small. Returns null if not found.
function findTaskOutputFile(taskId: string): string | null {
  if (!taskId) return null;
  let cwdDirs: string[];
  try {
    cwdDirs = readdirSync(CLAUDE_TMP_ROOT);
  } catch {
    return null;
  }
  const target = `${taskId}.output`;
  for (const cwd of cwdDirs) {
    const cwdPath = join(CLAUDE_TMP_ROOT, cwd);
    let sessionDirs: string[];
    try {
      sessionDirs = readdirSync(cwdPath);
    } catch {
      continue;
    }
    for (const session of sessionDirs) {
      const candidate = join(cwdPath, session, "tasks", target);
      try {
        statSync(candidate);
        return candidate;
      } catch {
        // not in this session dir
      }
    }
  }
  return null;
}

// Returns one of: "alive" (re-arm), "dead" (cancel), "unknown" (no file yet
// AND task has been tracked for less than TASK_STALE_THRESHOLD_MS — re-arm
// but only for one more cycle; on the second unknown we declare dead).
function checkTaskFileLiveness(taskId: string, trackedSinceMs: number): { state: "alive" | "dead" | "unknown"; reason: string } {
  const file = findTaskOutputFile(taskId);
  if (!file) {
    const ageMs = Date.now() - trackedSinceMs;
    if (ageMs > TASK_STALE_THRESHOLD_MS) {
      return { state: "dead", reason: `no .output file found ${Math.round(ageMs / 1000)}s after task_started` };
    }
    return { state: "unknown", reason: "no .output file yet (still warming up)" };
  }
  let stats;
  try {
    stats = statSync(file);
  } catch {
    return { state: "unknown", reason: "stat failed on .output file" };
  }
  const ageMs = Date.now() - stats.mtimeMs;
  if (stats.size === 0 && ageMs > TASK_STALE_THRESHOLD_MS) {
    return { state: "dead", reason: `.output is 0 bytes, untouched for ${Math.round(ageMs / 1000)}s` };
  }
  return { state: "alive", reason: stats.size > 0 ? `.output has ${stats.size} bytes` : `.output empty but mtime ${Math.round(ageMs / 1000)}s ago` };
}

function startTaskTimer(
  taskId: string,
  description: string,
  sessionId: string,
  sessionKey: string,
): void {
  if (taskWatchdogDisabled) return;
  if (!taskId || !sessionId || !sessionKey) return;
  clearTaskTimer(taskId);

  const startedAt = Date.now();
  const armTimer = (): ReturnType<typeof setTimeout> =>
    setTimeout(() => {
      // The timer fired without a matching task_notification — run the
      // liveness check before doing anything destructive.
      const tracked = activeTaskTimers.get(taskId);
      if (!tracked) return; // already cleared (race)

      const liveness = checkTaskFileLiveness(taskId, tracked.startedAt);

      if (liveness.state !== "dead") {
        logErr(
          `Task watchdog: ${taskId} still tracked after ${Math.round((Date.now() - tracked.startedAt) / 1000)}s — ` +
            `liveness=${liveness.state} (${liveness.reason}); re-arming`,
        );
        tracked.timer = armTimer();
        return;
      }

      // Declared dead — same cleanup path as the (currently disabled) tool
      // watchdog. Abort the in-flight query, notify the SDK to cancel,
      // unregister the session so the next prompt forces a fresh session
      // via priorContext replay, and emit a structured event so the UI can
      // surface "task hung, turn canceled" instead of an opaque silence.
      activeTaskTimers.delete(taskId);

      const ctx = activeQueries.get(tracked.sessionKey);
      if (!ctx) {
        logErr(`Task watchdog: ${taskId} dead (${liveness.reason}) but no active query for ${tracked.sessionKey} — leaving alone`);
        return;
      }
      if (ctx.interruptRequested) {
        logErr(`Task watchdog: ${taskId} dead (${liveness.reason}) — session ${tracked.sessionKey} already interrupted, skipping`);
        return;
      }

      const elapsedSec = (Date.now() - tracked.startedAt) / 1000;
      logErr(
        `Task watchdog auto-interrupting session ${tracked.sessionId} (key=${tracked.sessionKey}) ` +
          `due to dead subagent task ${taskId} "${tracked.description}" (${liveness.reason}, ` +
          `elapsed=${Math.round(elapsedSec)}s) — aborting query and forcing fresh session next prompt`,
      );
      ctx.interruptRequested = true;
      ctx.abortController.abort();
      acpNotify("session/cancel", { sessionId: ctx.sessionId });
      interruptedSessions.add(ctx.sessionId);
      unregisterSession(tracked.sessionKey);
      imageTurnCounts.delete(tracked.sessionKey);

      sendWithSession(tracked.sessionId, {
        type: "task_hang_canceled",
        taskId,
        description: tracked.description,
        durationSeconds: elapsedSec,
        reason:
          `The background task "${tracked.description}" appears to have died ` +
          `silently (${liveness.reason}), so I canceled this turn. ` +
          `You can retry — the next prompt will start a fresh session.`,
        sessionKey: tracked.sessionKey,
      });
    }, getTaskLivenessCheckMs());

  activeTaskTimers.set(taskId, {
    taskId,
    description,
    sessionId,
    sessionKey,
    startedAt,
    timer: armTimer(),
  });
}

function clearTaskTimer(taskId: string): void {
  const tracked = activeTaskTimers.get(taskId);
  if (tracked) {
    clearTimeout(tracked.timer);
    activeTaskTimers.delete(taskId);
  }
}

function clearTaskTimersForSession(sessionId: string | undefined): void {
  if (!sessionId) return;
  const toRemove: string[] = [];
  for (const [id, tracked] of activeTaskTimers) {
    if (tracked.sessionId === sessionId) {
      clearTimeout(tracked.timer);
      toRemove.push(id);
    }
  }
  for (const id of toRemove) activeTaskTimers.delete(id);
}

// --- In-flight tool diagnostic tracking ---
// Keeps a snapshot of every tool call seen on the wire so that when an
// interrupt fires we can dump what the stuck tool(s) were trying to do
// (e.g. the exact Bash command or Write target). Cleared on tool completion.
interface InFlightTool {
  title: string;
  kind: string;
  sessionId: string | undefined;
  sessionKey: string | undefined;
  startedAt: number;
  rawInput: Record<string, unknown> | undefined;
  lastStatus: string;
  lastLoggedInputFingerprint: string;
}
const inFlightTools = new Map<string, InFlightTool>();

function summarizeToolInput(
  title: string,
  rawInput: Record<string, unknown> | undefined,
): string {
  if (!rawInput || Object.keys(rawInput).length === 0) return "";
  const lower = title.toLowerCase();
  const pick = (k: string): string | undefined => {
    const v = rawInput[k];
    return typeof v === "string" ? v : v !== undefined ? JSON.stringify(v) : undefined;
  };
  const snip = (s: string, n: number): string =>
    s.length > n ? s.slice(0, n) + "…" : s;
  if (lower === "bash" || lower === "terminal") {
    const cmd = pick("command");
    const desc = pick("description");
    const parts: string[] = [];
    if (cmd) parts.push(`command=${snip(cmd, 300)}`);
    if (desc) parts.push(`description=${snip(desc, 120)}`);
    if (parts.length) return parts.join(", ");
  }
  if (lower === "write") {
    const fp = pick("file_path");
    const content = pick("content");
    const parts: string[] = [];
    if (fp) parts.push(`file_path=${fp}`);
    if (content) parts.push(`content=${content.length}chars`);
    if (parts.length) return parts.join(", ");
  }
  if (lower === "edit") {
    const fp = pick("file_path");
    const oldStr = pick("old_string");
    const parts: string[] = [];
    if (fp) parts.push(`file_path=${fp}`);
    if (oldStr) parts.push(`old=${snip(oldStr, 80)}`);
    if (parts.length) return parts.join(", ");
  }
  if (lower === "read") {
    const fp = pick("file_path");
    if (fp) return `file_path=${fp}`;
  }
  // Generic fallback: first 3 fields, values truncated
  return Object.entries(rawInput)
    .slice(0, 3)
    .map(([k, v]) => {
      const s = typeof v === "string" ? v : JSON.stringify(v);
      return `${k}=${s && s.length > 120 ? s.slice(0, 120) + "…" : s}`;
    })
    .join(", ");
}

function fingerprintInput(rawInput: Record<string, unknown> | undefined): string {
  if (!rawInput) return "";
  try {
    return JSON.stringify(rawInput);
  } catch {
    return String(Object.keys(rawInput).length);
  }
}

function logStuckToolsOnInterrupt(reason: string, sessionId?: string): void {
  if (inFlightTools.size === 0) return;
  const now = Date.now();
  for (const [toolCallId, tool] of inFlightTools) {
    if (sessionId && tool.sessionId !== sessionId) continue;
    const elapsedMs = now - tool.startedAt;
    const summary = summarizeToolInput(tool.title, tool.rawInput);
    logErr(
      `Tool STUCK on ${reason}: ${tool.title} (id=${toolCallId}, kind=${tool.kind}, ` +
        `session=${tool.sessionKey ?? tool.sessionId ?? "?"}, ` +
        `elapsed=${(elapsedMs / 1000).toFixed(1)}s, lastStatus=${tool.lastStatus})` +
        (summary ? ` [${summary}]` : " [no input captured]"),
    );
  }
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
  pendingBoundary: boolean;
  mode: "ask" | "act";
  // Harness-leak suppression: in some setups (Plan mode + personal Claude
  // account on Opus), the model echoes its own injected `(your turn — ...)`
  // resume prompt and `<system-reminder>...</system-reminder>` blocks at the
  // start of its assistant text. We buffer the leading bytes of each turn
  // and strip those before forwarding to the UI / persistence.
  prefixStripDone: boolean;
  prefixBuffer: string;
}

/**
 * Streaming-safe stripper for the harness-leak prefix at the start of an
 * assistant message. Returns:
 *   - { done: true,  suffix }   → past the harness; emit `suffix` and stop buffering
 *   - { done: false }           → still inside (or possibly inside) the harness;
 *                                  caller should keep buffering and not emit yet
 *
 * Patterns recognised at the start of `buf`, in order, all optional:
 *   1. leading whitespace
 *   2. one parenthesised template-placeholder line (`(your turn — …)`,
 *      `(your response here)`, `(my response)`, etc. — see HARNESS_PAREN_OPENERS)
 *   3. zero or more `<system-reminder>...</system-reminder>` blocks
 *
 * If `buf` clearly does NOT start with one of these markers, we exit fast with
 * the buffer unchanged so we don't add latency to normal responses.
 */
// [POISON-FIX-PLAN] L2b — SHIPPED 2026-05-12. Recognises additional
// template-placeholder openers beyond `(your turn`, fixes the chunk-boundary
// bug for a lone "(" first delta, and keeps buffering until the buffer is
// long enough to disambiguate against every known opener.
const HARNESS_PAREN_OPENERS = [
  "(your turn",
  "(your response",
  "(your reply",
  "(your answer",
  "(insert your response",
  "(insert response",
  "(insert reply",
  "(response here",
  "(reply here",
  "(answer here",
  "(my response",
  "(my reply",
  "(my answer",
  "(assistant response",
  "(assistant reply",
] as const;
const MAX_PAREN_OPENER_LEN = Math.max(...HARNESS_PAREN_OPENERS.map((s) => s.length));

function matchParenOpener(buf: string, pos: number): string | null {
  for (const opener of HARNESS_PAREN_OPENERS) {
    if (buf.startsWith(opener, pos)) return opener;
  }
  return null;
}

function isPartialParenOpener(s: string): boolean {
  // True iff `s` is a non-empty proper prefix of some known opener (so more
  // bytes could complete it into a real match). Allows e.g. "(" or "(your"
  // to keep buffering until enough has arrived to disambiguate.
  if (s.length === 0) return false;
  for (const opener of HARNESS_PAREN_OPENERS) {
    if (s.length < opener.length && opener.startsWith(s)) return true;
  }
  return false;
}

function stripHarnessPrefix(buf: string): { done: true; suffix: string } | { done: false } {
  const trimmed = buf.trimStart();

  // Fast path: doesn't even look like a harness leak. Be careful about partial
  // matches though — if the buffer is short and starts with `(` or `<`, the
  // marker may still be arriving in the next chunk.
  const startsWithHarness =
    matchParenOpener(trimmed, 0) !== null ||
    trimmed.startsWith("<system-reminder>") ||
    // partial markers we should keep buffering for
    isPartialParenOpener(trimmed) ||
    (trimmed.startsWith("<") && trimmed.length < "<system-reminder>".length);

  if (!startsWithHarness) {
    return { done: true, suffix: buf };
  }

  // We *might* be inside a harness leak. Walk through known shapes.
  let pos = 0;
  while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;

  // Optional `(<opener> ...)` line. Match any single-line parenthesised
  // preamble whose opener is one of the known template placeholders.
  if (matchParenOpener(buf, pos) !== null) {
    const close = buf.indexOf(")", pos);
    if (close === -1) return { done: false }; // wait for more
    pos = close + 1;
    while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;
  } else if (
    buf.startsWith("(", pos) &&
    buf.length - pos < MAX_PAREN_OPENER_LEN
  ) {
    // Buffer starts with `(` but we haven't seen enough bytes yet to know
    // whether it's a real opener (e.g. `(your turn`) or just user prose in
    // parens. Keep buffering.
    return { done: false };
  }

  // Zero-or-more `<system-reminder>...</system-reminder>` blocks
  while (buf.startsWith("<system-reminder>", pos)) {
    const close = buf.indexOf("</system-reminder>", pos);
    if (close === -1) return { done: false }; // wait for closing tag
    pos = close + "</system-reminder>".length;
    while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;
  }

  // Past the harness. If real content has arrived, emit the rest.
  // Otherwise keep buffering — more harness blocks may follow.
  if (pos < buf.length) {
    // If the very next non-whitespace char is `<`, it could be a partial
    // `<system-reminder>` still arriving. Keep buffering until we know.
    const next = buf.charAt(pos);
    if (next === "<" && buf.length - pos < "<system-reminder>".length) {
      return { done: false };
    }
    return { done: true, suffix: buf.slice(pos) };
  }
  return { done: false };
}

// Hard cap on prefix-buffer growth. If the model legitimately starts a turn
// with weird-looking content that resembles harness (unlikely), we don't want
// to swallow the entire response. Once the buffer exceeds this many bytes
// without resolving, we give up and emit it as-is.
const PREFIX_BUFFER_FLUSH_BYTES = 8 * 1024;

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

// --- Codex provider (Phase 2.1) ---
// Lazily instantiated; only spawned when first needed (probe or codex-prefixed
// model query). Until then, zero impact on the existing Claude-only flow.
let codexProvider: CodexProvider | null = null;

function getCodexProvider(): CodexProvider {
  if (!codexProvider) {
    codexProvider = new CodexProvider({
      logErr: (m) => logErr(`[codex] ${m}`),
      onNotification: (method, params) => {
        // Phase 2.1: log unrouted codex notifications. Per-session routing is
        // wired in Phase 2.3 when query handlers register their own handlers.
        const p = params as Record<string, unknown> | undefined;
        const sid = (p?.sessionId as string | undefined)
          ?? ((p?.update as Record<string, unknown> | undefined)?.sessionId as string | undefined);
        logErr(`[codex] unrouted notification method=${method} sessionId=${sid ?? "?"}`);
      },
    });
  }
  return codexProvider;
}

function readCodexAuthMode(): "chatgpt" | "api_key" | "none" {
  try {
    const path = join(homedir(), ".codex", "auth.json");
    if (!existsSync(path)) return "none";
    const data = JSON.parse(readFileSync(path, "utf8")) as { auth_mode?: string };
    if (data.auth_mode === "chatgpt") return "chatgpt";
    if (data.auth_mode) return "api_key";
    return "none";
  } catch {
    return "none";
  }
}

async function handleCodexInitProbe(): Promise<void> {
  try {
    const provider = getCodexProvider();
    provider.start();
    const init = await provider.initialize();
    // Open a transient session purely to learn the default model id + the
    // available models list (codex-acp returns both on session/new but not on
    // initialize).
    let currentModelId: string | undefined;
    let availableModels: Array<{ modelId: string; name: string; description?: string }> | undefined;
    try {
      const probeSession = (await provider.request("session/new", {
        cwd: homedir(),
        mcpServers: [],
      })) as {
        sessionId: string;
        models?: {
          currentModelId?: string;
          availableModels?: Array<{ modelId: string; name: string; description?: string }>;
        };
      };
      currentModelId = probeSession.models?.currentModelId;
      availableModels = probeSession.models?.availableModels;
      // No need to clean up — codex-acp drops the session when this provider is shut down.
    } catch (probeErr) {
      logErr(`[codex] probe session/new failed: ${probeErr}`);
    }
    send({
      type: "codex_probe_result",
      ok: true,
      agent: init.agentInfo ? `${init.agentInfo.name}@${init.agentInfo.version}` : undefined,
      authMethods: init.authMethods?.map((m) => m.id),
      currentModelId,
      availableModels,
      authMode: readCodexAuthMode(),
    });
  } catch (err) {
    send({
      type: "codex_probe_result",
      ok: false,
      authMode: readCodexAuthMode(),
      error: err instanceof Error ? err.message : String(err),
    });
  }
}

// Active Codex login flow handle (only one at a time)
let activeCodexLogin: CodexOAuthFlowHandle | null = null;

async function handleCodexLogout(): Promise<void> {
  if (activeCodexLogin) {
    activeCodexLogin.cancel();
    activeCodexLogin = null;
  }
  if (codexProvider?.isRunning()) {
    try { codexProvider.shutdown(); } catch { /* already gone */ }
  }
  codexProvider = null;
  // The cached session pool points at sessionIds that just died with the
  // subprocess; wipe it so the next prompt starts a fresh session.
  clearCodexSessions();
  const authPath = join(homedir(), ".codex", "auth.json");
  try {
    if (existsSync(authPath)) {
      unlinkSync(authPath);
      logErr("[codex-oauth] auth.json deleted");
    }
  } catch (err) {
    logErr(`[codex-oauth] failed to delete auth.json: ${err}`);
  }
  await handleCodexInitProbe();
}

async function handleCodexLogin(): Promise<void> {
  // Cancel any in-progress login
  if (activeCodexLogin) {
    activeCodexLogin.cancel();
    activeCodexLogin = null;
  }
  try {
    const flow = await startCodexOAuthFlow((msg) => logErr(`[codex-oauth] ${msg}`));
    activeCodexLogin = flow;
    // Send URL to Swift so it can open the browser
    send({ type: "codex_login_url", url: flow.authUrl });
    // Wait for the user to complete the OAuth flow in the browser
    await flow.complete;
    activeCodexLogin = null;
    // Recycle the codex-acp subprocess so the next probe/query picks up the
    // freshly written auth.json. The existing subprocess was spawned without
    // auth and won't re-read auth.json on its own — leaving it in place causes
    // every post-OAuth request to fail with "Authentication required" until a
    // logout/login cycle restarts it.
    if (codexProvider) {
      try { codexProvider.shutdown(); } catch { /* already gone */ }
      codexProvider = null;
    }
    // Drop cached session entries — they reference sessionIds on the now-dead
    // codex-acp subprocess and would trip "Resource not found" on the next prompt.
    clearCodexSessions();
    send({ type: "codex_login_complete" });
    logErr("[codex-oauth] login complete, auth.json written");
  } catch (err) {
    activeCodexLogin = null;
    const msg = err instanceof Error ? err.message : String(err);
    send({ type: "codex_login_error", error: msg });
    logErr(`[codex-oauth] login failed: ${msg}`);
  }
}

let acpProcess: ChildProcess | null = null;
let acpStdinWriter: ((line: string) => void) | null = null;

/**
 * Ring buffer of recent claude-agent-acp subprocess stderr lines. Surfaced in
 * `warmup_complete` when warmup fails so we can diagnose hung MCP spawns / auth
 * stalls remotely instead of needing the user's local log file.
 */
const acpStderrRing: string[] = [];
const ACP_STDERR_RING_MAX = 80;
function recordAcpStderr(text: string): void {
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    acpStderrRing.push(line);
    if (acpStderrRing.length > ACP_STDERR_RING_MAX) acpStderrRing.shift();
  }
}
function getAcpStderrTail(maxLines = 40): string {
  return acpStderrRing.slice(-maxLines).join("\n");
}
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
          // Legacy global fallback. Routing here when there IS a sessionId means
          // the per-session handler was missing; that is the signature of the
          // cross-session routing bug we're hunting.
          if (notifSessionId) {
            const methodStr = msg.method as string;
            const p = msg.params as Record<string, unknown> | undefined;
            const u = p?.update as Record<string, unknown> | undefined;
            logErr(
              `[ROUTE-MISS] notification for sessionId=${notifSessionId} had no registered handler; ` +
                `falling back to global. method=${methodStr} update=${u?.sessionUpdate ?? "?"} ` +
                `activeHandlers=[${Array.from(sessionNotificationHandlers.keys()).join(",")}]`,
            );
          }
          acpNotificationHandler(
            msg.method as string,
            msg.params as unknown
          );
        } else if (notifSessionId) {
          // No handler at all — notification silently dropped. Prior to this log
          // line, dropped notifications were invisible; this is the pathological
          // case where tool_call_update lands after the session already cleaned up.
          const methodStr = msg.method as string;
          const p = msg.params as Record<string, unknown> | undefined;
          const u = p?.update as Record<string, unknown> | undefined;
          const su = u?.sessionUpdate as string | undefined;
          const toolCallId = u?.toolCallId as string | undefined;

          // Session-agnostic notifications: forward to Swift even when no
          // per-session handler is registered. `available_commands_update`
          // fires from the agent right after `session/new`, which happens
          // during warmup before any query loop has installed a handler, so
          // it would otherwise be dropped on every cold start.
          if (su === "available_commands_update") {
            const rawCmds =
              (u?.availableCommands as unknown[] | undefined) ??
              (u?.available_commands as unknown[] | undefined) ??
              [];
            const commands = rawCmds
              .filter((c): c is Record<string, unknown> => typeof c === "object" && c !== null)
              .map((c) => {
                const name = typeof c.name === "string" ? c.name : "";
                const description = typeof c.description === "string" ? c.description : "";
                const inputObj = c.input as Record<string, unknown> | undefined;
                const inputHint =
                  inputObj && typeof inputObj.hint === "string" ? inputObj.hint : undefined;
                return { name, description, inputHint };
              })
              .filter((c) => c.name.length > 0);
            logErr(
              `[ROUTE-DROP-RESCUED] available_commands_update sessionId=${notifSessionId} count=${commands.length}`,
            );
            sendWithSession(notifSessionId, { type: "available_commands_update", commands });
            return;
          }

          logErr(
            `[ROUTE-DROP] notification dropped: sessionId=${notifSessionId} method=${methodStr} ` +
              `update=${su ?? "?"}${toolCallId ? ` toolId=${toolCallId}` : ""} ` +
              `activeHandlers=[${Array.from(sessionNotificationHandlers.keys()).slice(0, 5).join(",")}]`,
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
      recordAcpStderr(text);
      logErr(`ACP stderr: ${text}`);
    }
  });

  acpProcess.on("exit", (code) => {
    recordAcpStderr(`[acp-process-exit] code=${code}`);
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

/** True when the bridge is running in built-in (bundled API key) mode.
 *  In this mode, an auth failure means the bundled key is invalid (rotated,
 *  revoked, or block-listed); it does NOT mean the user's personal Claude
 *  account needs re-authentication. We signal Swift via `builtin_key_invalid`
 *  so it can refetch the key from the backend and silently retry, instead of
 *  pushing the user into an OAuth flow they were never using. */
function isBuiltinKeyMode(): boolean {
  return !!process.env.ANTHROPIC_API_KEY;
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
// `uncommitted` marks a session handed out from the spare pool that has not
// yet served a real query. Its `cwd` is the spare's warm cwd (homedir), not
// the pop-out's real workspace — so the pop-out's first query can switch cwd
// silently (no recovery preamble) because there is no conversation to lose.
const sessions = new Map<string, { sessionId: string; cwd: string; model?: string; uncommitted?: boolean }>();
/** Reverse map: ACP sessionId → sessionKey, for tagging outbound messages with sessionKey */
const sessionIdToKey = new Map<string, string>();

/** Register a session, maintaining the reverse map */
function registerSession(sessionKey: string, entry: { sessionId: string; cwd: string; model?: string; uncommitted?: boolean }): void {
  // Clean up any stale reverse-map entries that pointed to this key from a
  // prior unregister. unregisterSession intentionally leaves them so that a
  // late result/cancellation message for the unregistered sessionId can still
  // be routed back to its sessionKey (otherwise the per-pop-out continuation
  // never gets resumed and the loading spinner spins for the full 180s
  // inactivity timeout). When the same key gets a new sessionId we drop the
  // dangling pointers.
  for (const [sid, k] of sessionIdToKey) {
    if (k === sessionKey && sid !== entry.sessionId) {
      sessionIdToKey.delete(sid);
    }
  }
  sessions.set(sessionKey, entry);
  sessionIdToKey.set(entry.sessionId, sessionKey);
  // Persist sessionId → cwd so resume after bridge restart can pass the
  // original cwd to the Claude Agent SDK (it uses cwd to locate the JSONL).
  recordPersistedSession(sessionKey, entry.sessionId, entry.cwd, entry.model);
  logErr(`[SESSIONS] registered key=${sessionKey} sid=${entry.sessionId.slice(0, 8)} total=${sessions.size}`);
}

/** Unregister a session. Keeps the sessionId→sessionKey reverse mapping so
 *  any in-flight or deferred messages (e.g. the cancellation `result` emitted
 *  from a catch block after this unregister ran) can still be tagged with the
 *  correct sessionKey by sendWithSession. registerSession prunes stale
 *  entries when the key is reused.
 */
function unregisterSession(sessionKey: string): void {
  sessions.delete(sessionKey);
  logErr(`[SESSIONS] unregistered key=${sessionKey} total=${sessions.size}`);
}

/** Cooldown window during which a second credit_exhausted event will not
 *  trigger another subprocess restart. The first restart already replaced the
 *  poisoned SDK process; subsequent credit errors before the limit refreshes
 *  just need to surface to the offending pop-out, not thrash the bridge. */
let lastCreditExhaustedRestartAt: number | null = null;
const CREDIT_EXHAUSTED_RESTART_COOLDOWN_MS = 30_000;

/** Recover from a credit_exhausted event by restarting the ACP subprocess
 *  rather than scrubbing in-memory state. The previous "scrub-all-sessions"
 *  approach (deleted 2026-05-12) flagged every sessionId with
 *  `interruptedSessions`, which permanently forced future queries through
 *  `session/new` + priorContext replay — losing the original sessionId,
 *  prompt cache hits, and full SDK fidelity. Worse, it aborted in-flight
 *  queries on collateral sessions without emitting a terminal notification,
 *  so Swift's busy flag stayed true and pop-outs got stuck even after the
 *  limit refreshed.
 *
 *  The new approach mirrors what Claude Code CLI does: kill the subprocess
 *  so any drain-state poisoning dies with it, then let the next query on
 *  each session naturally `session/resume` from the on-disk transcript on
 *  the fresh subprocess. Same sessionId, same cache, same SDK state.
 *
 *  In-flight queries on collateral sessions are sent an `error` notification
 *  BEFORE their controllers are aborted, so Swift unbusies cleanly. The
 *  trigger session is excluded (its caller already sent `credit_exhausted`).
 *
 *  Cooldown prevents thrashing when the user types another message before
 *  the limit refreshes and hits the limit again on the just-restarted
 *  subprocess. */
function restartAfterCreditExhausted(triggerKey: string): void {
  const now = Date.now();
  if (lastCreditExhaustedRestartAt !== null
      && now - lastCreditExhaustedRestartAt < CREDIT_EXHAUSTED_RESTART_COOLDOWN_MS) {
    logErr(`[CREDIT-RESTART] cooldown active (${now - lastCreditExhaustedRestartAt}ms since last restart, key=${triggerKey}) — skipping subprocess restart, prior restart already cleared SDK state`);
    return;
  }
  lastCreditExhaustedRestartAt = now;

  // Notify Swift for each in-flight collateral query, THEN abort. The order
  // matters: the abort makes session/prompt throw, hitting the silent-return
  // branch at line ~3203 ("Query aborted (superseded by new query)"). That
  // branch is correct for genuine supersession but would leave Swift's busy
  // flag stuck on a scrub-induced abort. Emitting `error` first means Swift
  // has already cleared isAILoading by the time the silent-return runs.
  const collateralKeys: string[] = [];
  for (const [k, ctx] of activeQueries) {
    if (k === triggerKey) continue;
    if (ctx.abortController.signal.aborted) continue;
    collateralKeys.push(k);
    const entry = sessions.get(k);
    if (entry) {
      sendWithSession(entry.sessionId, {
        type: "error",
        // Stay cause-neutral: this branch fires for genuine billing exhaustion
        // (built-in cap, Anthropic monthly spend) AND for Claude.ai subscription
        // session windows (which reset on their own — no credit was spent). The
        // old wording "ran out of credit" misled personal-mode users into
        // thinking their OAuth account had a balance problem.
        message: "Reconnecting after another window hit Claude's usage limit. Send your message again to continue.",
      });
    }
    ctx.abortController.abort();
  }

  logErr(`[CREDIT-RESTART] triggered by key=${triggerKey} — restarting ACP subprocess (collateral aborted: ${collateralKeys.length}${collateralKeys.length ? ` [${collateralKeys.join(",")}]` : ""})`);

  // Fire-and-forget: don't block the caller's handleQuery. The acpProcess
  // exit handler at line ~1066 clears `sessions`/`activeSessionId`/
  // `isInitialized`, so the next handleQuery transparently does
  // `session/resume` on the fresh subprocess (transcripts on disk).
  // restartAcpProcess also kicks off warmup replay in the background.
  void restartAcpProcess().catch((err) => {
    logErr(`[CREDIT-RESTART] subprocess restart failed: ${err}`);
  });
}

// --- Persistent sessionId → cwd map ---------------------------------------
// The Claude Agent SDK stores transcripts under
// `~/.claude/projects/<encoded(cwd)>/<sessionId>.jsonl`. On session/resume the
// SDK looks the file up using the cwd we pass. If we pass a different cwd
// from the one that was used at session/new, the lookup misses and the SDK
// throws "Resource not found", which we then translate into a session_expired
// event with priorContext replay. The replay path itself has bugs (leaked
// `[Interrupted]` turns, stale conversation_history in the system prompt,
// auto-completed `User:` lines) so the right fix is to never let resume
// fail in the first place.
//
// We persist `{sessionId, sessionKey, cwd, model, updatedAt}` rows to
// `~/.fazm/acp-sessions.json` so the mapping survives bridge restarts. On
// every resume we look up the recorded cwd by sessionId and override the
// requested cwd if it disagrees. As a backstop for sessions created before
// this code shipped, we also extract `cwd` from the JSONL itself the first
// time we see one (the SDK writes it into nearly every line).
type PersistedSession = {
  sessionId: string;
  sessionKey: string;
  cwd: string;
  model?: string;
  updatedAt: number;
};
const PERSISTED_SESSIONS_PATH = join(homedir(), ".fazm", "acp-sessions.json");
const PERSISTED_MAX = 200;
/** All historical sessions we have seen, keyed by sessionId. Survives restart. */
const persistedSessions = new Map<string, PersistedSession>();
let persistDebounceTimer: NodeJS.Timeout | null = null;

function loadPersistedSessions(): void {
  try {
    if (!existsSync(PERSISTED_SESSIONS_PATH)) return;
    const raw = readFileSync(PERSISTED_SESSIONS_PATH, "utf-8");
    const arr = JSON.parse(raw) as PersistedSession[];
    if (!Array.isArray(arr)) return;
    for (const r of arr) {
      if (r && typeof r.sessionId === "string" && typeof r.cwd === "string") {
        persistedSessions.set(r.sessionId, r);
      }
    }
    logErr(`[SESSIONS] loaded ${persistedSessions.size} persisted records`);
  } catch (err) {
    logErr(`[SESSIONS] failed to load persisted sessions: ${err}`);
  }
}

function persistSessionsNow(): void {
  try {
    const dir = dirname(PERSISTED_SESSIONS_PATH);
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    // Cap to most-recent PERSISTED_MAX by updatedAt so the file stays small.
    const arr = Array.from(persistedSessions.values())
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, PERSISTED_MAX);
    // Drop trimmed entries from the in-memory map too.
    if (persistedSessions.size > arr.length) {
      const keep = new Set(arr.map((r) => r.sessionId));
      for (const id of persistedSessions.keys()) {
        if (!keep.has(id)) persistedSessions.delete(id);
      }
    }
    const tmp = `${PERSISTED_SESSIONS_PATH}.tmp`;
    writeFileSync(tmp, JSON.stringify(arr, null, 2), "utf-8");
    renameSync(tmp, PERSISTED_SESSIONS_PATH);
  } catch (err) {
    logErr(`[SESSIONS] failed to persist: ${err}`);
  }
}

function schedulePersistSessions(): void {
  if (persistDebounceTimer) clearTimeout(persistDebounceTimer);
  persistDebounceTimer = setTimeout(persistSessionsNow, 500);
}

function recordPersistedSession(sessionKey: string, sessionId: string, cwd: string, model?: string): void {
  if (!sessionId || !cwd) return;
  persistedSessions.set(sessionId, { sessionId, sessionKey, cwd, model, updatedAt: Date.now() });
  schedulePersistSessions();
}

/** Recorded cwd for a sessionId, checking live in-memory then on-disk. */
function lookupCwdForSessionId(sessionId: string): string | null {
  const liveKey = sessionIdToKey.get(sessionId);
  if (liveKey) {
    const s = sessions.get(liveKey);
    if (s?.cwd) return s.cwd;
  }
  const p = persistedSessions.get(sessionId);
  return p?.cwd ?? null;
}

/** Extract `"cwd":"..."` from the first matching line of a JSONL transcript.
 *  Used as a backstop for sessions that exist on disk but pre-date this
 *  persistence code. Reads up to 64 KB to keep the cost bounded. */
function extractCwdFromJsonlFile(path: string): string | null {
  try {
    const fd = readFileSync(path, { encoding: "utf-8", flag: "r" });
    // Bound the work — we only need the first few lines.
    const head = fd.length > 65536 ? fd.slice(0, 65536) : fd;
    const m = head.match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)+)"/);
    if (m) {
      try { return JSON.parse(`"${m[1]}"`); } catch { return m[1]; }
    }
  } catch { /* unreadable — caller will fall through to default */ }
  return null;
}

// Boot-time load. Safe to call before any registerSession.
loadPersistedSessions();

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
/** [POISON-FIX-PLAN] — May 6 2026 — anchor for two pending fixes around
 *  credit-limit-induced session poisoning. If you're triaging a stuck pop-out
 *  after a credit/rate limit reset, or a leaking `(your turn — respond to
 *  the current message above)` line at the start of an assistant reply, this
 *  block is the plan of record. Sister breadcrumbs (also tagged
 *  [POISON-FIX-PLAN]) sit at each code site below.
 *
 *  HYPOTHESIS (under verification via [POISON-DIAG] log below)
 *    When ANY pop-out hits credit_exhausted, the Claude Code SDK enters a
 *    drain state that poisons unrelated healthy sessions on their next
 *    session/resume — they return end_turn at 0ms with output tokens but
 *    0 streaming notifications. Field evidence: fazm.log May 6 2026 15:41,
 *    pop-out E29B50EC hit limit at T+0; pop-out 90908EB6's healthy session
 *    a68427af (running cleanly since T-2.5h) returned poisoned at T+88s.
 *    Today the bridge unregisters only the offending sessionKey on
 *    credit_exhausted; every other registered session stays trusted, and
 *    they all silently turn into landmines.
 *
 *  L1 FIX REVISED 2026-05-12 — subprocess restart instead of in-memory scrub
 *    The May 11 `scrubAllSessionsAfterPoisoning` approach worked at preventing
 *    silent end_turn=0ms cross-session poisoning, but had two follow-on bugs:
 *      (1) Collateral in-flight queries were aborted with no terminal
 *          notification to Swift (the silent-return branch at line ~3203
 *          fires for non-user-interrupt aborts), so pop-outs stayed busy
 *          forever — even after the limit refreshed.
 *      (2) Every scrubbed sessionId was flagged in `interruptedSessions`,
 *          permanently forcing future queries through `session/new` +
 *          priorContext replay. The user lost the original sessionId,
 *          prompt cache hits, and full SDK fidelity — a one-shot
 *          "Session restored" banner replaced what should have been
 *          seamless continuation.
 *    Replacement: `restartAfterCreditExhausted(triggerKey)` (defined just
 *    below `unregisterSession`) sends an `error` to in-flight collateral
 *    sessions (clears Swift busy), then kills + restarts the ACP subprocess.
 *    The fresh process has no drain-state poisoning to clear. The next
 *    query on each session naturally does `session/resume` from the on-disk
 *    transcript, preserving sessionId and cache fidelity — the same way
 *    `claude --resume <id>` works in the CLI. A 30s cooldown prevents
 *    thrashing when the user types again before the limit refreshes.
 *
 *  L2 FIX (defensive) — independent of L1
 *    L2a — SHIPPED 2026-05-12. The recovery preamble in handleQuery
 *    (search "Session restored from local history") used to use `User:`/
 *    `Assistant:` role labels, `--- RECENT TRANSCRIPT ---` markers, and a
 *    `User's current message:` label. Opus 4.7 pattern-matched that as a
 *    stage-direction template and emitted `(your turn — …)` or
 *    `(your response here)` as the literal start of its reply (field
 *    evidence: fazm.log 2026-05-12 10:50 PT, session detached-E4D72AA8…).
 *    Reshape: prose framing ("The user said…" / "You replied…"), no
 *    transcript markers, current message unlabeled at the bottom, plus
 *    an explicit "do not begin with template-placeholder text" line.
 *
 *    L2b — SHIPPED 2026-05-12. `stripHarnessPrefix` now recognises a
 *    list of template-placeholder openers beyond `(your turn` — it also
 *    strips `(your response`, `(your reply`, `(my response`, etc. The
 *    partial-buffering guard at the top of the function uses
 *    `isPartialParenOpener` so a lone `(` first chunk keeps buffering
 *    until enough bytes arrive to disambiguate against every known
 *    opener. Coverage in scripts/test-strip.mjs.
 *
 *  [POISON-DIAG] — diagnostic state written at every credit_exhausted emit
 *  site. Was originally read by the [STUCK-EMPTY-TURN] empty-end_turn
 *  recovery (removed: ACP defines end_turn as success). Kept because
 *  restartAcpAfterCreditExhausted uses lastCreditExhaustedRestartAt to
 *  rate-limit subprocess restarts, and the *At/*SessionKey fields remain
 *  useful for any future cross-session poisoning diagnostic. */
let lastCreditExhaustedAt: number | null = null;
let lastCreditExhaustedSessionKey: string | null = null;
/** Sessions that were interrupted (timeout/cancel) and may be in a broken state.
 *  When reusing such a session, we apply a TTFT watchdog — if ACP doesn't respond
 *  within 30s, the session is discarded and a fresh one is created. */
const interruptedSessions = new Set<string>();
let isInitialized = false;
let initPromise: Promise<void> | null = null;
let authMethods: AuthMethod[] = [];
let authResolve: (() => void) | null = null;
let preWarmPromise: Promise<WarmupResult> | null = null;
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
    preWarmPromise = preWarmSession(lastWarmupConfig.cwd, lastWarmupConfig.sessions, undefined, true);
  }
}

/**
 * True when an error thrown from `startAuthFlow()` represents the user
 * declining or letting the OAuth flow time out (vs. a real failure like a
 * token-endpoint rejection or network error). Used by the query path to
 * synthesise a helpful assistant reply instead of letting "OAuth flow
 * cancelled" surface as a generic agent error in the chat bubble.
 */
function isUserAbortedAuth(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /OAuth flow cancelled|timed out/i.test(msg);
}

/**
 * Send a friendly `result` event in place of a generic error when the user
 * cancelled or timed out the Claude OAuth flow mid-query. Without this, the
 * chat bubble shows a cryptic "OAuth flow cancelled" and the turn is
 * recorded as a failed AI response (chat_agent_error in PostHog). Returning
 * a result lets the turn complete coherently and gives the user a clear
 * next step.
 */
function sendAuthCancelledResult(sessionId: string, err: unknown): void {
  const isTimeout = err instanceof Error && /timed out/i.test(err.message);
  const text = isTimeout
    ? "Connecting to your Claude account timed out, so I couldn't run that. Open Settings → Claude Account to reconnect, then resend your message."
    : "I couldn't run that because connecting to your Claude account was cancelled. Open Settings → Claude Account to reconnect, then resend your message.";
  sendWithSession(sessionId, {
    type: "result",
    text,
    sessionId,
    costUsd: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
  });
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
      // Built-in mode: bundled API key is invalid. Don't trigger OAuth — emit
      // a global signal so Swift can refetch the key. Throw so bridge.start()
      // rejects and the next ensureBridgeStarted() picks up the new key.
      if (isBuiltinKeyMode()) {
        const errMsg = err instanceof Error ? err.message : String(err);
        logErr(`ACP init auth error in builtin mode (key may be rotated/invalid): ${errMsg}`);
        send({ type: "builtin_key_invalid", message: errMsg });
        throw err;
      }
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
  if (sessionKey === "onboarding" || sessionKey === "browser-migration" || sessionKey === "graph-exploration" || sessionKey === "profile-exploration") {
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

  // --- Browser automation: extension flow (Playwright) vs managed flow (browser-harness) ---
  // The two flows are mutually exclusive to avoid dual-Chrome state confusion.
  // Default = "extension" (existing behavior). Override via FAZM_BROWSER_MODE=managed.
  if (browserMode === "managed") {
    if (existsSync(browserHarnessMcpPython) && existsSync(browserHarnessMcpServer)) {
      const browserHarnessVenv = join(browserHarnessMcpDir, ".venv");
      servers.push({
        name: "browser-harness",
        command: browserHarnessMcpPython,
        args: [browserHarnessMcpServer],
        env: [
          { name: "PYTHONHOME", value: browserHarnessVenv },
          { name: "PYTHONDONTWRITEBYTECODE", value: "1" },
        ],
      });
      logErr(`Browser mode: managed (browser-harness MCP loaded)`);
    } else {
      logErr(
        `[FAZM-BROWSER-MISSING] FAZM_BROWSER_MODE=managed but bundled browser-harness ` +
          `not found at ${browserHarnessMcpPython} / ${browserHarnessMcpServer}. ` +
          `Falling back to no browser server (agent will have no browser tools).`,
      );
    }
    // Skip Playwright entirely when in managed mode.
    // (continue below to macos-use, whatsapp, google-workspace, user servers)
  } else {
  // Playwright MCP server
  const playwrightArgs = [playwrightCli];
  if (process.env.PLAYWRIGHT_USE_EXTENSION === "true") {
    playwrightArgs.push("--extension");
  }
  // Save snapshots to files and strip inline base64 screenshots to reduce context size
  playwrightArgs.push("--output-mode", "file", "--image-responses", "omit", "--output-dir", "/tmp/playwright-mcp");
  // Inject visual overlay on every page to indicate browser is controlled by Fazm.
  // This depends on THREE things being present at runtime:
  //   1. browser-overlay-init-page.cjs       (passed via Playwright --init-page)
  //   2. browser-overlay-init.js             (read at runtime by both .cjs and patched extensionContextFactory)
  //   3. extensionContextFactory.js patched  (postinstall step injects overlay in extension/CDP mode)
  // If any of these are missing, the overlay silently no-ops. Log loudly here so we
  // see it in Sentry breadcrumbs / dev logs instead of silently shipping a binary
  // without the "Browser controlled by Fazm" indicator (regression hit in v2.6.4).
  const overlayInitPage = join(__dirname, "..", "browser-overlay-init-page.cjs");
  const overlayInitJs = join(__dirname, "..", "browser-overlay-init.js");
  const extensionFactoryJs = join(
    __dirname,
    "..",
    "node_modules",
    "playwright",
    "lib",
    "mcp",
    "extension",
    "extensionContextFactory.js",
  );
  const hasInitPage = existsSync(overlayInitPage);
  const hasInitJs = existsSync(overlayInitJs);
  let extensionFactoryPatched = false;
  try {
    if (existsSync(extensionFactoryJs)) {
      extensionFactoryPatched = readFileSync(extensionFactoryJs, "utf-8").includes("_fazmOverlayScript");
    }
  } catch {
    // ignore — treated as unpatched
  }
  if (hasInitPage) {
    playwrightArgs.push("--init-page", overlayInitPage);
    logErr(`Browser overlay init-page: ${overlayInitPage}`);
  } else {
    logErr(`[FAZM-OVERLAY-MISSING] Browser overlay init-page NOT FOUND: ${overlayInitPage}`);
  }
  if (!hasInitJs) {
    logErr(`[FAZM-OVERLAY-MISSING] browser-overlay-init.js NOT FOUND at ${overlayInitJs} — overlay will silently no-op in extension mode`);
  }
  if (!extensionFactoryPatched) {
    logErr(`[FAZM-OVERLAY-MISSING] extensionContextFactory.js is NOT patched (no _fazmOverlayScript) — overlay will silently no-op in extension mode`);
  }
  if (hasInitPage && hasInitJs && extensionFactoryPatched) {
    logErr(`Browser overlay assets verified: init-page + init-js + patched extensionContextFactory`);
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
  } // end else (browserMode !== "managed")

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

  // Append user-defined MCP servers from ~/.fazm/mcp-servers.json
  // Format mirrors Claude Code's mcpServers: { "name": { "command": "...", "args": [...], "env": {...}, "enabled": true } }
  const userMcpConfigPath = join(homedir(), ".fazm", "mcp-servers.json");
  try {
    if (existsSync(userMcpConfigPath)) {
      const raw = readFileSync(userMcpConfigPath, "utf-8");
      const userServers = JSON.parse(raw) as Record<string, {
        command: string;
        args?: string[];
        env?: Record<string, string>;
        enabled?: boolean;
      }>;
      for (const [name, cfg] of Object.entries(userServers)) {
        if (cfg.enabled === false) continue;
        if (!cfg.command) {
          logErr(`User MCP server "${name}" skipped: missing command`);
          continue;
        }
        const envArr: Array<{ name: string; value: string }> = [];
        if (cfg.env) {
          for (const [k, v] of Object.entries(cfg.env)) {
            envArr.push({ name: k, value: String(v) });
          }
        }
        servers.push({
          name,
          command: cfg.command,
          args: cfg.args || [],
          env: envArr,
        });
        logErr(`User MCP server loaded: ${name} (${cfg.command})`);
      }
    }
  } catch (err) {
    logErr(`Failed to load user MCP servers from ${userMcpConfigPath}: ${err}`);
  }

  // Inherit global Claude Code MCP servers from ~/.claude.json (top-level mcpServers).
  // Precedence: bundled > ~/.fazm/mcp-servers.json > ~/.claude.json. Duplicates by name
  // are skipped so Fazm's bundled / user-overridden configs always win.
  // Opt out by setting FAZM_DISABLE_CLAUDE_CODE_MCP=true.
  if (process.env.FAZM_DISABLE_CLAUDE_CODE_MCP !== "true") {
    const claudeCodeConfigPath = join(homedir(), ".claude.json");
    try {
      if (existsSync(claudeCodeConfigPath)) {
        const raw = readFileSync(claudeCodeConfigPath, "utf-8");
        const parsed = JSON.parse(raw) as {
          mcpServers?: Record<string, {
            type?: "stdio" | "http";
            command?: string;
            args?: string[];
            env?: Record<string, string>;
            url?: string;
            headers?: Record<string, string>;
            enabled?: boolean;
          }>;
        };
        const claudeServers = parsed.mcpServers ?? {};
        const existingNames = new Set(servers.map((s) => s.name));
        for (const [name, cfg] of Object.entries(claudeServers)) {
          if (cfg.enabled === false) continue;
          if (existingNames.has(name)) {
            logErr(`Claude Code MCP server "${name}" skipped: already configured by Fazm`);
            continue;
          }
          const inferredType = cfg.type ?? (cfg.url ? "http" : "stdio");
          if (inferredType === "http") {
            if (!cfg.url) {
              logErr(`Claude Code MCP server "${name}" skipped: http type but no url`);
              continue;
            }
            const headersArr: Array<{ name: string; value: string }> = [];
            if (cfg.headers) {
              for (const [k, v] of Object.entries(cfg.headers)) {
                headersArr.push({ name: k, value: String(v) });
              }
            }
            servers.push({
              name,
              type: "http",
              url: cfg.url,
              headers: headersArr,
            });
            existingNames.add(name);
            logErr(`Claude Code MCP server loaded (http): ${name} (${cfg.url})`);
          } else {
            if (!cfg.command) {
              logErr(`Claude Code MCP server "${name}" skipped: stdio type but no command`);
              continue;
            }
            const envArr: Array<{ name: string; value: string }> = [];
            if (cfg.env) {
              for (const [k, v] of Object.entries(cfg.env)) {
                envArr.push({ name: k, value: String(v) });
              }
            }
            servers.push({
              name,
              command: cfg.command,
              args: cfg.args || [],
              env: envArr,
            });
            existingNames.add(name);
            logErr(`Claude Code MCP server loaded (stdio): ${name} (${cfg.command})`);
          }
        }
      }
    } catch (err) {
      logErr(`Failed to load Claude Code MCP servers from ${claudeCodeConfigPath}: ${err}`);
    }
  }

  emitMcpServers(servers);
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

// --- Dynamic model list from ACP SDK ---
let lastEmittedModelsJson = "";
let lastEmittedMcpServersJson = "";

function emitMcpServers(servers: McpServerConfig[]): void {
  const payload = servers.map(s => ({
    name: s.name,
    command: "command" in s ? s.command : ("url" in s ? s.url : "unknown"),
    builtin: !isUserMcpServer(s.name),
  }));
  const json = JSON.stringify(payload);
  if (json === lastEmittedMcpServersJson) return;
  lastEmittedMcpServersJson = json;
  send({ type: "mcp_servers_available", servers: payload });
  logErr(`Emitted mcp_servers_available: ${payload.map(s => `${s.name}(${s.builtin ? "builtin" : "user"})`).join(", ")}`);
}

// Names of built-in MCP servers (hardcoded in buildMcpServers)
const BUILTIN_MCP_NAMES = new Set(["fazm_tools", "playwright", "macos-use", "whatsapp", "google-workspace", "browser-harness"]);
function isUserMcpServer(name: string): boolean {
  return !BUILTIN_MCP_NAMES.has(name);
}

function emitModelsIfChanged(availableModels: Array<{ modelId: string; name: string; description?: string }>): void {
  logErr(`Raw models from ACP SDK: ${JSON.stringify(availableModels)}`);
  // Filter out the "default" pseudo-model — it's not a real selectable model
  const filtered = availableModels.filter(m => m.modelId !== "default");
  if (filtered.length === 0) return;
  const json = JSON.stringify(filtered);
  if (json === lastEmittedModelsJson) return;
  lastEmittedModelsJson = json;
  send({ type: "models_available", models: filtered });
  logErr(`Emitted models_available: ${filtered.map(m => `${m.modelId}=${m.name}`).join(", ")}`);
}

interface WarmupSessionConfig {
  key: string;
  model: string;
  systemPrompt?: string;
  resume?: string;  // if set, resume this session ID instead of creating a new one
}

/** Outcome of a `preWarmSession` call — which session keys warmed and which did not. */
interface WarmupResult {
  completedKeys: string[];
  failedSessions: Array<{ key: string; error: string }>;
}

/**
 * Hard ceiling on warmup. Without this, a hung `session/new` (e.g. an MCP server
 * that never answers its handshake, or an Anthropic auth stall) leaves
 * `preWarmSession` pending forever and `warmup_complete` never fires — the user
 * sits on an empty window indefinitely. Generous on purpose: a healthy warmup is
 * well under a minute, but slow networks have been observed in the 3-4 min range,
 * so this only converts a true infinite hang into a reported failure.
 */
const WARMUP_TOTAL_TIMEOUT_MS = 240_000;

/** Reject if `p` doesn't settle within `ms`. The underlying promise keeps running. */
function withTimeout<T>(p: Promise<T>, ms: number, label: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${ms}ms`)),
      ms,
    );
    p.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); },
    );
  });
}

/** Coarse bucket for a failed warmup, derived from the per-session error strings. */
function classifyWarmupFailure(failed: Array<{ key: string; error: string }>): string {
  const errs = failed.map((f) => f.error.toLowerCase()).join(" || ");
  if (errs.includes("timed out") || errs.includes("timeout")) return "timeout";
  if (errs.includes("credit") || errs.includes("401") || errs.includes("403") ||
      errs.includes("unauthorized") || errs.includes("auth")) return "auth";
  if (errs.includes("mcp") || errs.includes("spawn") || errs.includes("enoent")) return "mcp_spawn";
  if (errs.includes("session/new") || errs.includes("session/resume")) return "session_new";
  return "unknown";
}

// Stable default cwd for ACP sessions — ensures Claude Code's native memory system
// (MEMORY.md, auto memory) persists across app launches at a consistent path under
// ~/.claude/projects/. Using $HOME gives the broadest memory coverage — shared with
// CLI sessions started from home.
const DEFAULT_CWD = homedir();

/**
 * Encode a cwd path the same way the Claude Agent SDK does for ~/.claude/projects/<dir>.
 * Replaces every non-alphanumeric character with '-'. Mirrors the `A1()` function in
 * @anthropic-ai/claude-agent-sdk/sdk.mjs (truncation+hash branch is omitted because no
 * Fazm cwd exceeds 200 chars, but we keep the behavior strict enough to match real paths).
 *
 * Used to locate the JSONL transcript for a given sessionId, so we can pre-flight a
 * session/resume request and detect "phantom" session IDs — IDs that the bridge handed
 * out (via session/new) and persisted upstream in UserDefaults, but for which the SDK
 * never wrote a turn to disk (because no prompt completed before bridge restart). On
 * the next bridge boot, session/resume against a phantom ID is guaranteed to fail with
 * "Resource not found", which currently propagates as a session_expired event to the
 * user even though no real conversation history was lost.
 */
function encodeCwdForClaudeProjects(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}

/**
 * Returns the absolute path to the on-disk transcript for a sessionId, or null if
 * the session has no transcript anywhere.
 *
 * Two backends to consider:
 *   1. Claude Agent SDK writes JSONLs at `~/.claude/projects/<encoded-cwd>/<id>.jsonl`.
 *      We check the encoded-cwd path first, then fall back to scanning all sibling
 *      project dirs (mirroring the SDK's own `w0()` fallback when cwd was different
 *      at session creation).
 *   2. Codex (openai-codex via codex-acp) writes JSONLs at
 *      `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`. Different naming —
 *      timestamp-prefixed and date-bucketed. We scan the most recent date dirs first
 *      since that's where 99% of recent sessions live.
 *
 * `cwd` is only used for the Claude fast-path; passing an empty string still works
 * (we'll fall through to the project-dir scan and the codex scan).
 */
function findSessionJsonlPath(sessionId: string, cwd: string): string | null {
  if (!sessionId) return null;
  // 1) Claude SDK fast path
  const projectsRoot = join(homedir(), ".claude", "projects");
  if (cwd) {
    const primary = join(projectsRoot, encodeCwdForClaudeProjects(cwd), `${sessionId}.jsonl`);
    try {
      const st = statSync(primary);
      if (st.isFile() && st.size > 0) return primary;
    } catch { /* not found — fall through to scan */ }
  }
  // 2) Claude SDK fallback scan across sibling project dirs
  try {
    for (const dir of readdirSync(projectsRoot)) {
      const candidate = join(projectsRoot, dir, `${sessionId}.jsonl`);
      try {
        const st = statSync(candidate);
        if (st.isFile() && st.size > 0) return candidate;
      } catch { /* keep scanning */ }
    }
  } catch { /* projects root missing — that's fine, try codex next */ }
  // 3) Codex sessions: ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<sessionId>.jsonl
  // Walk newest dates first so a recent session resolves quickly. Bail after a few
  // empty days to avoid scanning years of old data.
  const codexRoot = join(homedir(), ".codex", "sessions");
  try {
    const years = readdirSync(codexRoot).filter((y: string) => /^\d{4}$/.test(y)).sort().reverse();
    for (const year of years) {
      const yearDir = join(codexRoot, year);
      const months = readdirSync(yearDir).filter((m: string) => /^\d{2}$/.test(m)).sort().reverse();
      for (const month of months) {
        const monthDir = join(yearDir, month);
        const days = readdirSync(monthDir).filter((d: string) => /^\d{2}$/.test(d)).sort().reverse();
        for (const day of days) {
          const dayDir = join(monthDir, day);
          let entries: string[];
          try { entries = readdirSync(dayDir); } catch { continue; }
          // Filename pattern: rollout-<isoTs>-<sessionId>.jsonl. Match on the suffix.
          const suffix = `${sessionId}.jsonl`;
          const hit = entries.find((e: string) => e.endsWith(suffix));
          if (hit) {
            const candidate = join(dayDir, hit);
            try {
              const st = statSync(candidate);
              if (st.isFile() && st.size > 0) return candidate;
            } catch { /* keep walking */ }
          }
        }
      }
    }
  } catch { /* no codex sessions dir or unreadable */ }
  return null;
}

/** True if either backend (Claude SDK or Codex) has a real transcript for this id. */
function sessionJsonlExists(sessionId: string, cwd: string): boolean {
  return findSessionJsonlPath(sessionId, cwd) !== null;
}

/**
 * Carry a Claude SDK transcript across a workspace (cwd) change so the session
 * can be resumed with its FULL history instead of a capped priorContext
 * summary.
 *
 * The Claude Agent SDK addresses transcripts by an encoded-cwd directory
 * (`~/.claude/projects/<encoded-cwd>/<id>.jsonl`), so when a pop-out's cwd
 * changes we physically relocate the JSONL into the new workspace's project
 * dir; `session/resume` under the new cwd then finds it and replays everything.
 *
 * Best-effort: returns false (caller falls back to priorContext replay) when
 * there is no transcript, the path is a Codex rollout (date-bucketed, not
 * cwd-addressed), or the filesystem move fails. Copy-then-unlink rather than
 * rename so a partial failure still leaves a usable transcript at the dest.
 */
function migrateJsonlForCwdChange(sessionId: string, oldCwd: string, newCwd: string): boolean {
  if (!sessionId || !oldCwd || !newCwd || oldCwd === newCwd) return false;
  try {
    const src = findSessionJsonlPath(sessionId, oldCwd);
    if (!src) return false;
    const projectsRoot = join(homedir(), ".claude", "projects");
    // Only Claude SDK transcripts are cwd-addressed under ~/.claude/projects.
    // A Codex rollout path must never be touched.
    if (!src.startsWith(projectsRoot + "/")) return false;
    const destDir = join(projectsRoot, encodeCwdForClaudeProjects(newCwd));
    const dest = join(destDir, `${sessionId}.jsonl`);
    if (src === dest) return true;
    mkdirSync(destDir, { recursive: true });
    copyFileSync(src, dest);
    try { unlinkSync(src); } catch { /* stale duplicate is harmless — lookup keys on requested cwd */ }
    logErr(`[JSONL-MIGRATE] ${sessionId.slice(0, 8)}: ${src} -> ${dest}`);
    return true;
  } catch (err) {
    logErr(`[JSONL-MIGRATE] ${sessionId.slice(0, 8)} (${oldCwd} -> ${newCwd}) failed: ${err}`);
    return false;
  }
}

async function preWarmSession(cwd?: string, sessionConfigs?: WarmupSessionConfig[], models?: string[], stagger?: boolean): Promise<WarmupResult> {
  const warmCwd = cwd || DEFAULT_CWD;
  try { mkdirSync(warmCwd, { recursive: true }); } catch {}

  // Save config so it can be replayed after an OAuth-triggered subprocess restart.
  // Merge by key (don't replace) so a single-session re-warm — e.g. the
  // post-resetSession re-warm below — doesn't drop the other warmed sessions.
  // Ephemeral `detached-*` keys are never persisted: a closed pop-out window
  // must not be re-warmed on a post-OAuth restart.
  if (sessionConfigs && sessionConfigs.length > 0) {
    const merged = new Map<string, WarmupSessionConfig>(
      (lastWarmupConfig?.sessions ?? []).map((s) => [s.key, s])
    );
    for (const s of sessionConfigs) {
      if (!s.key.startsWith("detached-")) merged.set(s.key, s);
    }
    lastWarmupConfig = { cwd: cwd ?? lastWarmupConfig?.cwd, sessions: [...merged.values()] };
  }

  // Build the list of sessions to warm: new format (sessionConfigs) takes priority over legacy (models array)
  const toWarm: WarmupSessionConfig[] = sessionConfigs && sessionConfigs.length > 0
    ? sessionConfigs.filter((s) => !sessions.has(s.key))
    : (models && models.length > 0 ? models : [DEFAULT_MODEL, SONNET_MODEL])
        .filter((m) => !sessions.has(m))
        .map((m) => ({ key: m, model: m }));

  if (toWarm.length === 0) {
    logErr("All requested sessions already pre-warmed");
    return { completedKeys: [], failedSessions: [] };
  }

  // Per-session warmup outcome — lets warmup_complete report exactly which
  // session(s) hung or failed instead of an opaque all-or-nothing flag.
  const completedKeys: string[] = [];
  const failedSessions: Array<{ key: string; error: string }> = [];

  try {
    await initializeAcp();

    if (stagger && toWarm.length > 1) {
      logErr(`Pre-warming ${toWarm.length} sessions with stagger (post-OAuth restart)...`);
    }
    await withTimeout(Promise.all(
      toWarm.map(async (cfg, i) => {
        if (stagger && i > 0) {
          await new Promise((r) => setTimeout(r, i * 500));
        }
        const sessionStartMs = Date.now();
        try {
          const sessionParams: Record<string, unknown> = {
            cwd: warmCwd,
            mcpServers: buildMcpServers("act", warmCwd, cfg.key),
            ...buildMeta(cfg.systemPrompt, cfg.key),
          };

          // Resume existing session if ID provided, otherwise create a new one
          let sessionId: string;
          // Resolve the cwd this session was originally created with (handles
          // bridge-restart case where warmCwd no longer matches the cwd at
          // session/new time). Falls back to warmCwd if we have no record.
          let warmResumeCwd = warmCwd;
          if (cfg.resume) {
            const recordedCwd = lookupCwdForSessionId(cfg.resume);
            if (recordedCwd && recordedCwd !== warmCwd) {
              logErr(`[CWD-RECOVERY] pre-warm ${cfg.resume.slice(0, 8)}: using recorded cwd ${recordedCwd} (warmCwd=${warmCwd}, key=${cfg.key})`);
              warmResumeCwd = recordedCwd;
            }
          }
          // Phantom-session pre-check: an ID can be persisted upstream (in UserDefaults)
          // even though the SDK never wrote a turn to disk for it. Resuming such an ID
          // is guaranteed to throw "Resource not found"; skip the round-trip and go
          // straight to session/new without alarming the user.
          const resumeJsonlPath = cfg.resume ? findSessionJsonlPath(cfg.resume, warmResumeCwd) : null;
          const isPhantomResume = !!cfg.resume && !resumeJsonlPath;
          if (isPhantomResume) {
            logErr(`Pre-warm: phantom session id ${cfg.resume} (no JSONL on disk for cwd=${warmResumeCwd}); skipping resume, going to session/new (key=${cfg.key})`);
          }
          // Backstop: if we found the JSONL but had no recorded cwd, extract
          // it from the file so the resume call below points the SDK at the
          // right project dir.
          if (cfg.resume && resumeJsonlPath && warmResumeCwd === warmCwd) {
            const extracted = extractCwdFromJsonlFile(resumeJsonlPath);
            if (extracted && extracted !== warmCwd) {
              logErr(`[CWD-RECOVERY] pre-warm ${cfg.resume.slice(0, 8)}: extracted cwd ${extracted} from JSONL (warmCwd=${warmCwd}, key=${cfg.key})`);
              warmResumeCwd = extracted;
              recordPersistedSession(cfg.key, cfg.resume, extracted, cfg.model);
            }
          }
          if (cfg.resume && !isPhantomResume) {
            try {
              await acpRequest("session/resume", {
                sessionId: cfg.resume,
                cwd: warmResumeCwd,
                mcpServers: buildMcpServers("act", warmResumeCwd, cfg.key),
              });
              sessionId = cfg.resume;
              logErr(`Pre-warm resumed session: ${sessionId} (key=${cfg.key}, model=${cfg.model}, cwd=${warmResumeCwd}, jsonl=${resumeJsonlPath})`);
              // Set model after resume — without this the session uses the SDK default (possibly Haiku)
              await acpRequest("session/set_model", { sessionId, modelId: cfg.model });
              logErr(`Pre-warm set_model after resume: ${cfg.model}`);
            } catch (resumeErr) {
              logErr(`Pre-warm session/resume failed for ${cfg.key} (jsonl existed: ${resumeJsonlPath}), falling back to session/new: ${resumeErr}`);
              const result = (await acpRequest("session/new", sessionParams)) as { sessionId: string; models?: { availableModels?: Array<{ modelId: string; name: string; description?: string }> } };
              sessionId = result.sessionId;
              if (result.models?.availableModels) emitModelsIfChanged(result.models.availableModels);
              logErr(`Pre-warmed new session: ${sessionId} (key=${cfg.key}, model=${cfg.model}, hasSystemPrompt=${!!cfg.systemPrompt})`);
            }
          } else if (cfg.resume && isPhantomResume) {
            // Phantom path: directly create a fresh session, same as the no-resume branch.
            const result = (await acpRequest("session/new", sessionParams)) as { sessionId: string; models?: { availableModels?: Array<{ modelId: string; name: string; description?: string }> } };
            sessionId = result.sessionId;
            if (result.models?.availableModels) emitModelsIfChanged(result.models.availableModels);
            logErr(`Pre-warmed new session (after phantom skip): ${sessionId} (key=${cfg.key}, model=${cfg.model}, hasSystemPrompt=${!!cfg.systemPrompt})`);
          } else {
            // Retry once after a short delay if session/new fails
            let result: { sessionId: string; models?: { availableModels?: Array<{ modelId: string; name: string; description?: string }> } };
            try {
              result = (await acpRequest("session/new", sessionParams)) as typeof result;
            } catch (firstErr) {
              logErr(`Pre-warm session/new failed for ${cfg.key}, retrying in 2s: ${firstErr}`);
              await new Promise((r) => setTimeout(r, 2000));
              result = (await acpRequest("session/new", sessionParams)) as typeof result;
            }
            sessionId = result.sessionId;
            if (result.models?.availableModels) emitModelsIfChanged(result.models.availableModels);
            logErr(`Pre-warmed session: ${sessionId} (key=${cfg.key}, model=${cfg.model}, hasSystemPrompt=${!!cfg.systemPrompt})`);
          }

          // Register with warmCwd (what Swift asked for). The persisted
          // sessionId→cwd map already captured the SDK's actual cwd via
          // recordPersistedSession during JSONL extraction (above), so a
          // future resume with this id resolves correctly even if warmCwd
          // and the SDK's original cwd differ.
          registerSession(cfg.key, { sessionId, cwd: warmCwd, model: cfg.model });
          await acpRequest("session/set_model", { sessionId, modelId: cfg.model });
          // Tell the Swift client about the pre-warmed sessionId NOW, even though
          // no user prompt has run yet. Without this, the very first prompt against
          // a pre-warmed session that immediately rate-limits would lose its
          // sessionId — handleQuery hits the "Reusing existing ACP session" branch
          // (which doesn't emit session_started), so Swift never banks the id.
          // Defense-in-depth on top of handleQuery's own session_started emission.
          sendWithSession(sessionId, { type: "session_started", isResume: !!cfg.resume });
          completedKeys.push(cfg.key);
          logErr(`Pre-warm session '${cfg.key}' ready in ${Date.now() - sessionStartMs}ms`);
        } catch (err) {
          if (isAcpAuthError(err)) {
            failedSessions.push({ key: cfg.key, error: "auth_error" });
            // Built-in mode: bundled API key is invalid. Don't trigger OAuth —
            // emit a signal so Swift can refetch + restart. Pre-warm is best-
            // effort, so just log and bail; the next user query will trigger
            // the same path and Swift's retry logic will refetch the key.
            if (isBuiltinKeyMode()) {
              const errMsg = err instanceof Error ? err.message : String(err);
              logErr(`Pre-warm auth error in builtin mode (key may be rotated/invalid) for ${cfg.key}: ${errMsg}`);
              send({ type: "builtin_key_invalid", message: errMsg });
              return;
            }
            logErr(`Pre-warm failed with auth error (code=${(err as AcpError).code}), starting OAuth flow`);
            try {
              const creds = readStoredCredentials();
              const tokenAgeSec = creds?.storedAt
                ? Math.round((Date.now() - new Date(creds.storedAt).getTime()) / 1000)
                : null;
              logErr(`[AUTH-DIAG] pre-warm sessions=${sessions.size} warmup, activeQueries=${activeQueries.size} concurrent, tokenAge=${tokenAgeSec != null ? tokenAgeSec + "s" : "unknown"}, key=${cfg.key}`);
            } catch { /* ignore diagnostic errors */ }
            await startAuthFlow();
            return;
          }
          const errMsg = err instanceof Error ? err.message : String(err);
          failedSessions.push({ key: cfg.key, error: errMsg });
          logErr(`Pre-warm session '${cfg.key}' FAILED after ${Date.now() - sessionStartMs}ms: ${errMsg}`);
        }
      })
    ), WARMUP_TOTAL_TIMEOUT_MS, "Warmup");
  } catch (err) {
    // A throw here is the timeout (or initializeAcp failing) — the per-session
    // bodies above swallow their own errors, so this only fires for the hard
    // ceiling. Sessions still absent from completedKeys are the ones that hung.
    const errMsg = err instanceof Error ? err.message : String(err);
    logErr(`Pre-warm failed (will create on first query): ${errMsg}`);
    for (const cfg of toWarm) {
      if (!completedKeys.includes(cfg.key) && !failedSessions.some((f) => f.key === cfg.key)) {
        failedSessions.push({ key: cfg.key, error: errMsg });
      }
    }
  }

  return { completedKeys, failedSessions };
}

// --- Handle query from Swift ---

/** Maximum number of recursive handleQuery retries (session resume + image-too-large combined) */
const MAX_QUERY_RETRIES = 2;

async function handleQuery(msg: QueryMessage, _retryDepth = 0): Promise<void> {
  // Phase 2.3: route Codex models to the codex-acp adapter. The Claude path
  // below is unchanged — codex models simply never reach it.
  if (isCodexModel(msg.model)) {
    await handleCodexQuery(msg, {
      logErr,
      send,
      sendWithSession,
      getProvider: getCodexProvider,
      buildMcpServers,
      registerSession,
    });
    return;
  }

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

    // Recovery state for the priorContext-replay block below. Hoisted above the
    // existing-session check so the cwd-change branch can also signal recovery.
    let resumeFailedFromId: string | null = null;
    // Source of the recovery: how should the user-facing notice be phrased?
    let recoveryCause: "stuck_session" | "resume_failed" | "workspace_changed" | null = null;
    // The cwd recorded on the *old* session before we tore it down — used in
    // the workspace_changed user notice so the UI can say "X → Y".
    let priorCwdForRecovery: string | null = null;
    // P2: when set, msg.resume points at a transcript we deliberately relocated
    // into the new workspace dir (migrateJsonlForCwdChange). The two cwd-recovery
    // overrides below must NOT second-guess it back to the old workspace.
    let cwdMigrationResumeId: string | null = null;

    const existing = sessions.get(sessionKey);
    // P4: a session handed out from the spare pool carries the spare's warm cwd
    // (homedir), not the pop-out's real workspace. Its first query "changes"
    // cwd, but there is no conversation to preserve — that switch is silent.
    const existingWasUncommitted = existing?.uncommitted === true;
    if (existing) {
      // If cwd changed, invalidate this specific session
      if (existing.cwd !== requestedCwd) {
        logErr(`Cwd changed for ${sessionKey} (${existing.cwd} -> ${requestedCwd})`);
        // Tear down the old SDK subprocess before unregistering. Without this,
        // each cwd change for a sessionKey leaves an orphaned claude SDK process
        // running at 70-90% CPU forever. Observed 2026-05-13: pop-out session
        // detached-447BA654 toggled cwd between `social-autoposter-website` and
        // `/Users/matthewdi` three times, accumulating 3 zombie SDK subprocesses
        // for one logical session. unregisterSession only drops the in-memory
        // entry; it does NOT call teardownSession in claude-agent-acp.
        // Fire-and-forget: don't block the new session/new on cleanup.
        acpRequest("session/close", { sessionId: existing.sessionId }).catch((err) => {
          logErr(`session/close on cwd-change cleanup failed for ${existing.sessionId.slice(0, 8)}: ${err}`);
        });
        unregisterSession(sessionKey);
        imageTurnCounts.delete(sessionKey);

        if (existingWasUncommitted) {
          // P4: spare-pool session, no real conversation yet. Recreate silently
          // in the requested cwd — nothing to recover, so no resume, no
          // priorContext preamble, no session_expired notice.
          logErr(`  (uncommitted spare session — silent recreate, nothing to preserve)`);
          msg.resume = undefined;
        } else {
          // Real cwd flap on a session that holds conversation history.
          priorCwdForRecovery = existing.cwd;
          // P2: carry the FULL transcript across the workspace switch. The SDK
          // addresses transcripts by cwd-encoded dir, so relocating the JSONL
          // into the new workspace's project dir lets us session/resume it
          // intact instead of replaying a capped priorContext summary.
          //
          // The carry id is the live in-memory session (`existing.sessionId`),
          // not Swift's `msg.resume`: when an in-memory session exists it is
          // authoritative for "what conversation is in this pop-out", and a
          // stale `msg.resume` from before a mid-chat rollover would migrate an
          // older, shorter transcript. Best-effort — any failure falls through
          // to priorContext replay.
          const carryId = existing.sessionId;
          if (migrateJsonlForCwdChange(carryId, existing.cwd, requestedCwd)) {
            logErr(`  (migrated transcript ${carryId.slice(0, 8)} into ${requestedCwd} — will resume with full history)`);
            msg.resume = carryId;
            // Record the new cwd so [CWD-RECOVERY] resumes at requestedCwd, and
            // flag the id so the JSONL-internal-cwd backstop below does not drag
            // it back to the old workspace.
            recordPersistedSession(sessionKey, carryId, requestedCwd, requestedModel);
            cwdMigrationResumeId = carryId;
          } else {
            // No transcript to carry — discard the resume id (it would restore
            // the old cwd) and route through session/new + priorContext replay
            // so the conversation history still survives the workspace switch.
            logErr(`  (no transcript to migrate — falling back to priorContext replay)`);
            msg.resume = undefined;
            resumeFailedFromId = existing.sessionId;
            recoveryCause = "workspace_changed";
          }
        }
      } else {
        sessionId = existing.sessionId;
        // P4: the spare has now served a real query at its warm cwd — it is
        // committed. Clear the flag so a later genuine cwd flap on this session
        // goes through full recovery instead of a silent reset.
        if (existing.uncommitted) existing.uncommitted = false;
      }
    }

    // Reuse existing session if alive, resume a persisted one, or create a new one
    // Stuck-session recovery: if a prior turn detected the SDK session was
    // poisoned (empty text, stopReason=end_turn) and recursed with this field
    // set, skip the normal resume attempt entirely and treat it as if the
    // resume had failed → forces session/new with priorContext replay and
    // emits a session_expired notice so the user sees what happened.
    if (msg._priorStuckSessionId && !sessionId) {
      resumeFailedFromId = msg._priorStuckSessionId;
      recoveryCause = "stuck_session";
      logErr(`Stuck-session recovery: forcing session/new for key=${sessionKey} (dead session was ${msg._priorStuckSessionId})`);
    }
    // If the persisted resume id was previously interrupted (timeout / user
    // cancel / mid-tool-call abort), the upstream SDK session is dirty: the
    // next session/resume + session/prompt would replay the cancelled prior
    // prompt's chunks as the response to the NEW prompt (Apr 29 2026 incident).
    // Skip resume entirely and route through the existing stuck-session
    // recovery: session/new + priorContext replay + session_expired notice.
    if (msg.resume && !sessionId && interruptedSessions.has(msg.resume)) {
      logErr(`Skipping resume of interrupted session ${msg.resume} (would replay stale chunks); forcing fresh session with priorContext replay (key=${sessionKey})`);
      resumeFailedFromId = msg.resume;
      recoveryCause = "stuck_session";
      interruptedSessions.delete(msg.resume);
      msg.resume = undefined;
    }
    // The cwd we will pass to session/resume. Starts at requestedCwd, but we
    // override it below if we have a recorded original cwd for this sessionId
    // (either from our in-memory/persisted store, or extracted from the JSONL).
    // This is the fix for the resume-after-bridge-restart bug: the SDK locates
    // transcripts under `~/.claude/projects/<encoded(cwd)>/<id>.jsonl`, so if
    // we pass a cwd that doesn't match the one used at session/new, the
    // resume call throws "Resource not found".
    let resolvedResumeCwd = requestedCwd;
    if (msg.resume && !sessionId && msg.resume !== cwdMigrationResumeId) {
      const recordedCwd = lookupCwdForSessionId(msg.resume);
      if (recordedCwd && recordedCwd !== requestedCwd) {
        logErr(`[CWD-RECOVERY] resume ${msg.resume.slice(0, 8)}: using recorded cwd ${recordedCwd} (requestedCwd=${requestedCwd}, key=${sessionKey})`);
        resolvedResumeCwd = recordedCwd;
      }
    }
    if (msg.resume && !sessionId) {
      // Phantom-session pre-check: an ID can be persisted upstream (in UserDefaults)
      // even though the SDK never wrote a turn to disk for it. Resuming such an ID is
      // guaranteed to throw "Resource not found" → which would cascade as a
      // user-facing session_expired notice and a priorContext replay even though no
      // real conversation history was lost. When the JSONL is missing, treat the
      // persisted ID as never-realized and silently start a fresh session.
      // findSessionJsonlPath checks the encoded(resolvedResumeCwd) path first
      // and then scans sibling project dirs as a fallback.
      const resumeJsonlPath = findSessionJsonlPath(msg.resume, resolvedResumeCwd);
      if (!resumeJsonlPath) {
        logErr(`session/resume skipped: phantom id ${msg.resume} has no JSONL on disk (cwd=${resolvedResumeCwd}); going straight to session/new without session_expired (key=${sessionKey})`);
        msg.resume = undefined;
        // Note: NOT setting resumeFailedFromId — this is a silent recovery, the user
        // never had a real session in the first place.
      } else {
        // Backstop for sessions that exist on disk but pre-date the persisted
        // cwd map: extract the original cwd from the JSONL itself (the SDK
        // writes "cwd":"<path>" into nearly every line). This makes the
        // resume path lossless even after a bridge upgrade with no record.
        //
        // Skipped for a P2 cwd-migration: there the transcript was deliberately
        // relocated into the NEW workspace, but its lines still carry the OLD
        // cwd — honoring the extracted value would resume in the old workspace
        // and (worse) fail to find the JSONL we just moved.
        if (resolvedResumeCwd === requestedCwd && msg.resume !== cwdMigrationResumeId) {
          const extracted = extractCwdFromJsonlFile(resumeJsonlPath);
          if (extracted && extracted !== requestedCwd) {
            logErr(`[CWD-RECOVERY] resume ${msg.resume.slice(0, 8)}: extracted cwd ${extracted} from JSONL (requestedCwd=${requestedCwd}, key=${sessionKey})`);
            resolvedResumeCwd = extracted;
            // Backfill the persisted store so we don't have to re-extract.
            recordPersistedSession(sessionKey, msg.resume, extracted, requestedModel);
          }
        }
      }
    }
    if (msg.resume && !sessionId) {
      // Resume a persisted session by ID (survives process restarts via ~/.claude/projects/)
      // Fall back to session/new if the session file is gone or resume fails
      try {
        await acpRequest("session/resume", {
          sessionId: msg.resume,
          cwd: resolvedResumeCwd,
          mcpServers: buildMcpServers(mode, resolvedResumeCwd, sessionKey),
        });
        sessionId = msg.resume;
        // Track Swift's requestedCwd in the live sessions Map (it drives the
        // cwd-mismatch invalidation check on subsequent prompts). The SDK's
        // actual original cwd lives in the persisted store via
        // recordPersistedSession, which registerSession calls below.
        registerSession(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
        // If we used a recovered cwd (resolvedResumeCwd != requestedCwd), make
        // sure the persisted record reflects the SDK's true cwd, not Swift's.
        if (resolvedResumeCwd !== requestedCwd) {
          recordPersistedSession(sessionKey, sessionId, resolvedResumeCwd, requestedModel);
        }
        isNewSession = false;
        // Set model after resume — without this the session uses the SDK default (possibly Haiku)
        await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
        logErr(`ACP session resumed: ${sessionId} (key=${sessionKey}, model=${requestedModel}, sdkCwd=${resolvedResumeCwd}, swiftCwd=${requestedCwd})`);
        // Tell the client that this session is alive and resumable, BEFORE the prompt
        // runs. If the prompt hits a rate limit / credit-exhausted / network error
        // mid-stream, the client has already banked the sessionId in UserDefaults,
        // so the next attempt resumes instead of starting a fresh empty session.
        sendWithSession(sessionId, { type: "session_started", isResume: true });
      } catch (resumeErr) {
        logErr(`ACP session resume failed (will create new session): ${resumeErr}`);
        // Remember the lost session id so we can emit session_expired and (if
        // the client supplied priorContext) prepend a recovery preamble below.
        resumeFailedFromId = msg.resume;
        recoveryCause = "resume_failed";
        // Fall through to session/new below
      }
    }
    if (!sessionId) {
      const sessionParams: Record<string, unknown> = {
        cwd: requestedCwd,
        mcpServers: buildMcpServers(mode, requestedCwd, sessionKey),
        ...buildMeta(msg.systemPrompt, sessionKey),
      };
      const sessionResult = (await acpRequest("session/new", sessionParams)) as { sessionId: string; models?: { availableModels?: Array<{ modelId: string; name: string; description?: string }> } };

      sessionId = sessionResult.sessionId;
      if (sessionResult.models?.availableModels) emitModelsIfChanged(sessionResult.models.availableModels);
      registerSession(sessionKey, { sessionId, cwd: requestedCwd, model: requestedModel });
      isNewSession = true;
      if (requestedModel) {
        await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
      }
      logErr(`ACP session created: ${sessionId} (key=${sessionKey}, model=${requestedModel || "default"}, cwd=${requestedCwd})`);
      // Tell the client that this session is alive and resumable, BEFORE the prompt
      // runs. Critical for popouts: if the very first long task hits a rate limit,
      // without this the client never sees the sessionId and the follow-up starts a
      // brand-new session with no memory.
      sendWithSession(sessionId, { type: "session_started", isResume: false });
    } else {
      isNewSession = false;
      // If the requested model differs from the session's current model, switch it
      const existingModel = sessions.get(sessionKey)?.model;
      if (requestedModel && requestedModel !== existingModel) {
        await acpRequest("session/set_model", { sessionId, modelId: requestedModel });
        const s = sessions.get(sessionKey);
        if (s) s.model = requestedModel;
        logErr(`Reusing existing ACP session: ${sessionId} (key=${sessionKey}, switched model ${existingModel} -> ${requestedModel})`);
      } else {
        logErr(`Reusing existing ACP session: ${sessionId} (key=${sessionKey})`);
      }
    }
    activeSessionId = sessionId;

    // Initialize QueryContext now that we have the ACP sessionId
    queryCtx = {
      sessionId,
      sessionKey,
      abortController,
      interruptRequested: false,
      pendingBoundary: false,
      mode,
      prefixStripDone: false,
      prefixBuffer: "",
    };
    activeQueries.set(sessionKey, queryCtx);

    fullPrompt = msg.prompt;

    // If session/resume failed and we just created a fresh session, the upstream
    // conversation history is gone. Tell the UI immediately, and (if the client
    // supplied recent local history) prepend a compact recovery preamble so the
    // model can pick up the thread instead of replying as a stranger.
    if (resumeFailedFromId && isNewSession) {
      const ctxEntries = Array.isArray(msg.priorContext) ? msg.priorContext : [];
      // Cap replay to keep token cost bounded; most "what was I doing" recoveries
      // only need the last handful of turns. Trim from the END (most recent kept).
      const MAX_REPLAY = 20;
      let replay = ctxEntries.slice(-MAX_REPLAY);
      // Drop ALL trailing assistant turns. When recovery fires, the prior
      // assistant turn is by definition unreliable: it was either interrupted
      // mid-stream or replayed stale chunks from a previous turn. Even when
      // its text looks plausible (normal prose, no toxic markers), replaying
      // it primes the
      // recovery model so heavily that a low-information new message like
      // "Hello" gets a continuation of the prior topic instead of a direct
      // answer (May 5 2026 incident: pop-out user typed "Hello" after a long
      // tool-heavy task; model continued the prior task instead of greeting).
      // The user's current message (appended below) is the source of truth;
      // the prior user turns provide context, the prior assistant turn does not.
      // This subsumes the earlier toxic-pattern filter (empty / [Interrupted] /
      // leaked User:/Assistant: markers) — those were special cases of the
      // same general problem.
      while (
        replay.length > 0 &&
        replay[replay.length - 1].role === "assistant"
      ) {
        replay = replay.slice(0, -1);
      }
      const restoredCount = replay.length;

      // [POISON-FIX-PLAN] L2a — SHIPPED 2026-05-12. Recovery preamble used to
      // use `User:` / `Assistant:` role labels, `--- RECENT TRANSCRIPT ---`
      // markers, and a `User's current message:` label. Opus 4.7 occasionally
      // pattern-matched that as a stage-direction template and emitted
      // `(your turn — …)` or `(your response here)` as the literal start of
      // its reply (see fazm.log 2026-05-12 10:50 PT, session
      // detached-E4D72AA8…). New shape: prose framing ("Earlier, the user
      // said…" / "You replied…"), no transcript markers, and the user's
      // current message sits unlabeled at the bottom.
      //
      // [POISON-FIX-PLAN] L2b — SHIPPED 2026-05-12 (later same day). L2a kept
      // the drop-trailing-assistant behavior from May 5, which means the
      // transcript ends with `The user said: <prior>` and the new user
      // message is appended right after, unlabeled. The model read that as
      // a transcript with a missing assistant turn and "completed" it by
      // emitting `[No assistant response recorded for this user message.]`
      // as its reply (fazm.log 2026-05-12 13:50 PT, session
      // detached-FF5BC803…, msg 1E3EE157). Fix: place an explicit boundary
      // marker between the replayed transcript and the new user message
      // so the model can't pattern-match the dangling-user-turn shape.
      if (restoredCount > 0) {
        const transcript = replay
          .map((e) => {
            const who = e.role === "assistant" ? "You replied" : "The user said";
            // Hard-cap each entry to avoid one huge tool dump dominating the preamble.
            const text = (e.text ?? "").slice(0, 4000);
            return `${who}: ${text}`;
          })
          .join("\n\n");
        const preamble =
          `[Session restored from local history.]\n` +
          `The previous session (${resumeFailedFromId}) was interrupted before ` +
          `it could finish. Below is recent conversation context replayed from ` +
          `the user's local message store — treat it as background only. The ` +
          `prior assistant turn (if any) was dropped because it was incomplete ` +
          `or unreliable.\n\n` +
          `Answer the user's new message at the bottom directly and naturally, ` +
          `in your own voice. Do NOT narrate, quote, or echo the context above. ` +
          `Do NOT begin your reply with any template-placeholder text such as ` +
          `"(your response here)", "(your turn)", "[No assistant response ` +
          `recorded ...]", or similar — write the actual answer. If the new ` +
          `message is a short greeting, an unrelated question, or a fresh ` +
          `topic, treat it as such and do not assume it continues the prior ` +
          `task unless the user explicitly references it.\n\n` +
          `Earlier in this conversation (${restoredCount} message${restoredCount === 1 ? "" : "s"}, oldest first):\n` +
          transcript +
          `\n\n[End of restored context. The user has just sent the message ` +
          `below — write your actual reply to it. Do not continue, summarize, ` +
          `or quote the transcript above, and do not emit any bracketed ` +
          `placeholder text in place of a real reply.]\n\n` +
          fullPrompt;
        fullPrompt = preamble;
        logErr(`Session expired: replayed ${restoredCount} prior messages into new session ${sessionId}`);
      } else {
        logErr(`Session expired: no priorContext provided, starting fresh (key=${sessionKey})`);
      }

      // User-facing reason text. Tailored per cause so the inline notice in
      // the chat tells the user WHY the session was reset, not just that it was.
      // `stuck_session` now covers only SDK-state-corruption cases: a session
      // that was interrupted mid-stream, or one that replayed stale chunks from
      // a previous turn. Empty end_turn no longer routes here — per ACP it is
      // a successful turn and is delivered to the UI as-is.
      // `workspace_changed` is the cwd-flap recovery: the SDK can't run
      // commands in two workspaces from one session, so a new session is
      // unavoidable; the conversation continues via priorContext replay.
      let reasonText: string;
      if (recoveryCause === "stuck_session") {
        reasonText = "The previous session's response was unreliable, so I restarted this chat.";
      } else if (recoveryCause === "workspace_changed") {
        const from = priorCwdForRecovery ? ` from ${priorCwdForRecovery.replace(/^\/Users\/[^/]+/, "~")}` : "";
        const to = requestedCwd.replace(/^\/Users\/[^/]+/, "~");
        reasonText = `Workspace changed${from} to ${to}; conversation continues with prior context.`;
      } else {
        reasonText = "The upstream chat session expired and was replaced.";
      }
      sendWithSession(sessionId, {
        type: "session_expired",
        reason: reasonText,
        oldSessionId: resumeFailedFromId,
        newSessionId: sessionId,
        contextRestored: restoredCount > 0,
        restoredMessageCount: restoredCount,
        sessionKey,
      });
    }

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
        const isToolEvent =
          sessionUpdate === "tool_call" || sessionUpdate === "tool_call_update";
        const toolCallId = isToolEvent ? (update?.toolCallId as string | undefined) : undefined;
        const toolTitle = isToolEvent ? (update?.title as string | undefined) : undefined;
        const toolStatus = isToolEvent ? (update?.status as string | undefined) : undefined;
        // Log every notification with gap time to detect stalls; include tool
        // identity so cross-session routing (and stuck-tool progression) is
        // visible in one grep.
        if (
          notificationCount <= 5 ||
          gapMs > 10000 ||
          notificationCount % 50 === 0 ||
          isToolEvent // always log tool lifecycle notifications
        ) {
          const suffix = isToolEvent
            ? ` toolId=${toolCallId ?? "?"} name=${toolTitle ?? "?"} status=${toolStatus ?? "?"}`
            : "";
          logErr(
            `[NOTIFY] #${notificationCount} key=${sessionKey} sid=${sessionId.slice(0, 8)} ` +
              `type=${sessionUpdate ?? "?"} gap=${gapMs}ms${suffix}`,
          );
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

      // Add user-attached files as native content blocks (images, PDFs, text).
      // Binary/unknown types are never read into memory; only their path is sent.
      const MAX_INLINE_SIZE = 20 * 1024 * 1024; // 20 MB for images/PDFs
      const MAX_TEXT_SIZE = 10 * 1024 * 1024;    // 10 MB for text files
      if (msg.attachments && msg.attachments.length > 0) {
        for (const att of msg.attachments) {
          try {
            if (!existsSync(att.path)) {
              logErr(`[ATTACH] File not found: ${att.path}`);
              continue;
            }
            const stats = statSync(att.path);
            const mime = att.mimeType.toLowerCase();
            const sizeMB = (stats.size / 1024 / 1024).toFixed(1);

            // 1) Unknown/binary types: send path only, never read the file
            if (mime === "application/octet-stream" || (!mime.startsWith("image/") && !mime.startsWith("text/") && mime !== "application/pdf")) {
              logErr(`[ATTACH] Binary file, sending path only: ${att.name} (${sizeMB}MB, ${mime})`);
              promptBlocks.push({
                type: "text",
                text: `[Attached file: ${att.name} (${sizeMB}MB, ${mime}) at path: ${att.path}]`,
              });
              continue;
            }

            // 2) Size gate: reject files too large to inline
            const isInlineBinary = mime.startsWith("image/") || mime === "application/pdf";
            const sizeLimit = isInlineBinary ? MAX_INLINE_SIZE : MAX_TEXT_SIZE;
            if (stats.size > sizeLimit) {
              const limitMB = (sizeLimit / 1024 / 1024).toFixed(0);
              logErr(`[ATTACH] File too large (${sizeMB}MB > ${limitMB}MB limit), sending path only: ${att.name}`);
              promptBlocks.push({
                type: "text",
                text: `[Attached file: ${att.name} (${sizeMB}MB, ${mime}) at path: ${att.path}]\nNote: File is too large to inline. The file path is provided so you can reference it in tool calls if needed.`,
              });
              continue;
            }

            // 3) Read the file (only images, PDFs, and text reach here, all within size limits)
            const fileData = readFileSync(att.path);

            if (mime.startsWith("image/")) {
              // ACP expects flat {type, data, mimeType}, NOT the Anthropic API nested {source: {type, media_type, data}} format
              promptBlocks.push({
                type: "image",
                data: fileData.toString("base64"),
                mimeType: mime,
              });
            } else if (mime === "application/pdf") {
              // ACP has no "document" content type; inline PDFs as base64-encoded text reference
              // so the model can use the Read tool on the file path instead
              const sizeMBStr = (stats.size / 1024 / 1024).toFixed(1);
              promptBlocks.push({
                type: "text",
                text: `[Attached PDF: ${att.name} (${sizeMBStr}MB) at path: ${att.path}]\nPlease use the Read tool to read this PDF file.`,
              });
            } else {
              // text/* files: inline as UTF-8
              promptBlocks.push({
                type: "text",
                text: `[File: ${att.name}]\n${fileData.toString("utf-8")}`,
              });
            }
            logErr(`[ATTACH] Added ${mime} attachment: ${att.name} (${stats.size} bytes)`);
          } catch (err) {
            logErr(`[ATTACH] Failed to read attachment ${att.path}: ${err}`);
          }
        }
      }

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

      // Abort race: when the user clicks Stop, the interrupt handler calls
      // ctx.abortController.abort() and sends session/cancel to ACP. But
      // acpRequest doesn't listen for the abort signal — it just keeps
      // awaiting the SDK's reply. When a tool is mid-execution and the SDK
      // ignores session/cancel (Terminal subprocess keeps running, no
      // stopReason ever returned), the await hangs forever, the result event
      // never gets emitted to Swift, sendingSessionKeys never clears, and
      // the user's follow-up message gets enqueued behind a query that will
      // never complete (May 5 2026 incident: pop-out user clicked Stop on a
      // 77s Terminal tool, then sent a follow-up — the follow-up sat
      // enqueued while the Terminal kept emitting heartbeats for another
      // ~80s).
      //
      // Resolution: race the prompt against the abort signal directly so an
      // explicit user interrupt always unblocks the await. The catch block
      // below detects abortController.signal.aborted and emits the partial
      // result, freeing Swift to accept the next prompt. The underlying
      // tool subprocess may keep running on the user's machine — we can't
      // kill SDK-spawned subprocesses from here — but the conversation is
      // no longer wedged.
      const abortPromise = new Promise<never>((_, reject) => {
        if (abortController.signal.aborted) {
          reject(new Error("ABORT: signal already aborted before race"));
          return;
        }
        abortController.signal.addEventListener(
          "abort",
          () => reject(new Error("ABORT: user interrupt")),
          { once: true }
        );
      });

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
        racePromise = Promise.race([promptPromise, watchdogPromise, abortPromise]);
      } else {
        racePromise = Promise.race([promptPromise, abortPromise]);
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

        // Detect interrupt-replay: this session was previously interrupted
        // (mid-stream cancel) and the prompt completed in a way that suggests
        // the SDK delivered the cancelled prior prompt's deferred chunks as
        // this prompt's response. Defense in depth — Fix 1 (interrupt
        // invalidates session) should already have routed us through stuck-
        // session recovery before getting here, but if a session got marked
        // wasInterrupted via other paths (e.g., a session lingering in
        // interruptedSessions from a prior process state), catch the replay
        // here. Signal: previously-interrupted session, fast completion, and
        // either no streaming chunks (input=8 tokens means prompt-shell only)
        // or token counts that don't match the user's prompt size.
        if (
          wasInterrupted &&
          !isNewSession &&
          // Cap at one cascade per user prompt (May 4 2026): previously this
          // used `< MAX_QUERY_RETRIES` (=2) which let recovery sessions trigger
          // additional recoveries, producing 3 sessions in ~13s for one prompt.
          // The cascade is also what enabled toxic-preamble feedback (each
          // recovery's partial assistant turn became next recovery's
          // priorContext). One recovery is enough; if that also fails we
          // deliver the empty result and let the UI surface the error.
          _retryDepth < 1
        ) {
          const inputTokens = promptResult.usage?.inputTokens ?? 0;
          // Heuristic: a real prompt has at least ~5 input tokens of overhead
          // plus the user content. If inputTokens is tiny (≤ 20) AND the
          // prompt was non-trivial (> 50 chars), the SDK didn't actually send
          // our prompt — it's replaying a deferred result.
          const looksLikeReplay = inputTokens <= 20 && fullPrompt.length > 50;
          if (looksLikeReplay) {
            logErr(`[INTERRUPT-REPLAY] Detected deferred-response replay on previously-interrupted session ${sessionId} (duration=${promptDurationMs}ms, inputTokens=${inputTokens}, outputTokens=${outputTokens}, fullTextLen=${fullText.length}, promptLen=${fullPrompt.length}). Forcing fresh session with priorContext replay (depth=${_retryDepth}).`);
            const stuckSessionId = sessionId;
            // Silence in-flight notification draining from the dead session.
            // The SDK keeps emitting buffered chunks for ~tens of ms after we
            // detect the replay; without abort, those textDeltas reach Swift
            // and the stale reply is rendered in the UI before the new
            // session's real response can replace it.
            abortController.abort();
            unregisterSession(sessionKey);
            imageTurnCounts.delete(sessionKey);
            interruptedSessions.delete(sessionId);
            activeSessionId = "";
            for (const name of pendingTools) {
              sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
            }
            pendingTools.length = 0;
            clearToolTimersForSession(sessionId);
            // Skip resume entirely; recurse with stuck-session marker so the
            // next call goes straight to session/new + priorContext replay.
            msg.resume = undefined;
            msg._priorStuckSessionId = stuckSessionId;
            return handleQuery(msg, _retryDepth + 1);
          }
        }

        // Detect deferred-replay (no prior interrupt): the SDK returned an
        // entire turn in <50ms with tokenized input way smaller than the
        // user's prompt. Real Claude generation can't complete this fast
        // even with a fully cached prefix — the SDK is flushing buffered
        // notifications from a previous turn as this prompt's response.
        //
        // Reproducing case (May 8 2026, session 6b1f7981): two consecutive
        // user messages got duration=1ms responses. The reply text answered
        // the *previous* turn's question instead of the user's current one
        // (e.g. user asked "Why Sonnet?" and got pipeline-status text;
        // follow-up "I asked about Sonnet versus Opus" got the actual
        // Sonnet explanation). INTERRUPT-REPLAY missed this because the
        // session was never explicitly cancelled and prompts were short
        // (<50 chars); STALE-TASK-RETRY missed it because outputTokens was
        // hundreds, not <100.
        //
        // Recovery is the same as INTERRUPT-REPLAY: destroy the leaking
        // session and recreate fresh with priorContext replay, so the new
        // session starts from a clean SDK state.
        if (!isNewSession && _retryDepth < 1) {
          const inputTokens = promptResult.usage?.inputTokens ?? 0;
          const looksLikeDeferredReplay =
            promptDurationMs < 50 &&
            outputTokens > 0 &&
            inputTokens <= 20 &&
            fullPrompt.length > 0;
          if (looksLikeDeferredReplay) {
            logErr(`[DEFERRED-REPLAY] Detected deferred-response replay on session ${sessionId} (duration=${promptDurationMs}ms, inputTokens=${inputTokens}, outputTokens=${outputTokens}, fullTextLen=${fullText.length}, promptLen=${fullPrompt.length}). Forcing fresh session with priorContext replay (depth=${_retryDepth}).`);
            const stuckSessionId = sessionId;
            // Silence in-flight notification draining (see INTERRUPT-REPLAY above).
            abortController.abort();
            unregisterSession(sessionKey);
            imageTurnCounts.delete(sessionKey);
            interruptedSessions.delete(sessionId);
            activeSessionId = "";
            for (const name of pendingTools) {
              sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
            }
            pendingTools.length = 0;
            clearToolTimersForSession(sessionId);
            msg.resume = undefined;
            msg._priorStuckSessionId = stuckSessionId;
            return handleQuery(msg, _retryDepth + 1);
          }
        }

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
          clearToolTimersForSession(sessionId);
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
          clearToolTimersForSession(sessionId);

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

        // Empty assistant turn (fullText.length === 0 + stopReason=end_turn):
        // we trust ACP semantics here. Per the spec, `end_turn` is a success
        // reason — "the language model finishes responding without requesting
        // more tools" — and the schema explicitly defines it as "the turn
        // ended successfully." There is no protocol-level distinction between
        // a verbose end_turn and a content-less one; both are valid outcomes.
        //
        // Previously this branch detected empty end_turn and force-spawned a
        // fresh session with priorContext replay, on the theory that empty
        // content meant the SDK was poisoned (e.g. drain state after a prior
        // credit_exhausted). That heuristic was a) not in the protocol, and
        // b) lossy: the replay carries text only, so MCP tool state (active
        // browser tab, VM context, etc.) is destroyed and the new session
        // operates with no knowledge of the work in flight. The replay
        // preamble itself has also been a steady source of model-pattern-
        // matching bugs (L2a/L2b May 12 2026 incidents).
        //
        // If the underlying SDK actually has a drain-state bug after
        // credit_exhausted, the fix belongs upstream (or in the
        // credit_exhausted handler that already restarts the subprocess at
        // line 1245+), not in the success-path of session/prompt. An empty
        // assistant turn now flows through to the UI as an empty result,
        // which is an honest representation of what the agent returned.
        //
        // INTERRUPT-REPLAY and DEFERRED-REPLAY above remain — they catch
        // SDK-state-corruption cases where the SDK lies about what happened
        // (replays stale chunks from a cancelled prior turn, completes in
        // <50ms, etc.). Those are protocol-contract violations, not empty
        // successes, so the recovery there is justified.

        // Increment image turn counter so we know when to stop including screenshots.
        // Image turn counting removed — screenshots are now read by the model via Read tool

        // Mark any remaining pending tools as completed
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearToolTimersForSession(sessionId);

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
          clearToolTimersForSession(sessionId);

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
          clearToolTimersForSession(sessionId);
          logErr(
            `Query interrupted by user, sending partial result (${fullText.length} chars)`
          );
          sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, interrupted: true });
        } else {
          logErr("Query aborted (superseded by new query)");
        }
        return;
      }
      // AUTH_REQUIRED: -32000 explicitly, or -32603 wrapping a 401
      if (isAcpAuthError(err)) {
        // Built-in mode: bundled API key is invalid. Don't push the user into
        // OAuth — they were never using a personal account. Signal Swift so it
        // can refetch the key from /v1/keys, restart the bridge with the new
        // key, and silently retry. Drop the session so the retry creates a
        // fresh session/new with the new credentials.
        if (isBuiltinKeyMode()) {
          const errMsg = err instanceof Error ? err.message : String(err);
          logErr(`session/prompt auth error in builtin mode (key may be rotated/invalid): ${errMsg}`);
          for (const name of pendingTools) {
            sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;
          clearToolTimersForSession(sessionId);
          sendWithSession(sessionId, { type: "builtin_key_invalid", message: errMsg });
          unregisterSession(sessionKey);
          imageTurnCounts.delete(sessionKey);
          activeSessionId = "";
          return;
        }
        if (authRetryCount >= MAX_AUTH_RETRIES) {
          logErr(`session/prompt auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
          sendWithSession(sessionId, { type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
          return;
        }
        authRetryCount++;
        logErr(`session/prompt failed with auth error (code=${(err as AcpError).code}), starting OAuth flow (attempt ${authRetryCount})`);
        // Diagnostics: log concurrent session state and token age to help identify root cause
        try {
          const creds = readStoredCredentials();
          const tokenAgeSec = creds?.storedAt
            ? Math.round((Date.now() - new Date(creds.storedAt).getTime()) / 1000)
            : null;
          logErr(`[AUTH-DIAG] sessions=${sessions.size} warmup, activeQueries=${activeQueries.size} concurrent, tokenAge=${tokenAgeSec != null ? tokenAgeSec + "s" : "unknown"}, sessionKey=${sessionKey}`);
        } catch { /* ignore diagnostic errors */ }
        unregisterSession(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        msg.resume = undefined;
        try {
          await startAuthFlow();
        } catch (authErr) {
          if (isUserAbortedAuth(authErr)) {
            logErr(`session/prompt OAuth flow ${authErr instanceof Error ? authErr.message : String(authErr)} — surfacing as assistant result`);
            sendAuthCancelledResult(sessionId, authErr);
            return;
          }
          throw authErr;
        }
        return handleQuery(msg, _retryDepth + 1);
      }
      const errMsg = err instanceof Error ? err.message : String(err);

      // Classify the failure (overloaded / credit / other). See classifyApiFailure
      // for why 529 needs special-casing despite the SDK labelling it rate_limit.
      const apiRetryInfo = lastApiRetry as { httpStatus: number | null; errorType: string } | null;
      const apiRetryErrorType = apiRetryInfo?.errorType;
      const apiRetryHttpStatus = apiRetryInfo?.httpStatus;
      const failureKind = classifyApiFailure(errMsg, apiRetryInfo);

      // Upstream overload: transient, surface to the trigger session ONLY, do
      // NOT restart the subprocess or abort other in-flight pop-outs. Anthropic
      // will recover on its own; killing collateral queries just costs the user
      // their work for no reason (production incident 2026-05-14).
      if (failureKind === "overloaded") {
        logErr(`Upstream overload (httpStatus=${apiRetryHttpStatus}, errorType=${apiRetryErrorType}), not retrying: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearToolTimersForSession(sessionId);
        sendWithSession(sessionId, { type: "upstream_overloaded", message: errMsg });
        lastApiRetry = null;
        return;
      }

      if (failureKind === "credit") {
        logErr(`Credit/rate limit exhausted (structured httpStatus=${apiRetryHttpStatus}, errorType=${apiRetryErrorType}), not retrying: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearToolTimersForSession(sessionId);
        sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
        lastCreditExhaustedAt = Date.now();
        lastCreditExhaustedSessionKey = sessionKey;
        // Restart the ACP subprocess (see restartAfterCreditExhausted above).
        // The fresh process clears any SDK drain-state poisoning; the next
        // query on each session naturally session/resumes from disk.
        restartAfterCreditExhausted(sessionKey);
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
        clearToolTimersForSession(sessionId);

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
      // 1M-context entitlement error: API rejects requests when the model has a [1m]
      // suffix but the user's Claude account isn't on the 1M-context tier. Auto-fall-back
      // to the standard-context variant by stripping [1m] and retrying once. Without
      // this, the user sees a raw "Extra usage is required for 1M context · enable
      // extra usage at claude.ai/settings/usage" message and is stuck.
      const is1mContextError = /extra usage is required for 1m context|enable extra usage at claude\.ai\/settings\/usage/i.test(errMsg);
      const has1mSuffix = /\[1m\]/i.test(requestedModel);
      if (is1mContextError && has1mSuffix && _retryDepth < MAX_QUERY_RETRIES) {
        const downgraded = requestedModel.replace(/\s*\[1m\]/gi, "");
        logErr(`1M context not available, retrying with downgraded model: ${requestedModel} -> ${downgraded}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearToolTimersForSession(sessionId);
        unregisterSession(sessionKey);
        imageTurnCounts.delete(sessionKey);
        activeSessionId = "";
        msg.resume = undefined;
        msg.model = downgraded;
        lastApiRetry = null;
        return handleQuery(msg, _retryDepth + 1);
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
      // Reuse classifyApiFailure so an upstream 529 doesn't get bucketed into
      // credit_exhausted here just because the message contains "limit".
      if (isNonRetryable) {
        logErr(`Non-retryable error, surfacing to user: ${errMsg}`);
        for (const name of pendingTools) {
          sendWithSession(sessionId, { type: "tool_activity", name, status: "completed" });
        }
        pendingTools.length = 0;
        clearToolTimersForSession(sessionId);
        const fallbackKind = classifyApiFailure(errMsg, apiRetryInfo);
        if (fallbackKind === "overloaded") {
          sendWithSession(sessionId, { type: "upstream_overloaded", message: errMsg });
        } else if (fallbackKind === "credit") {
          sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
          lastCreditExhaustedAt = Date.now();
          lastCreditExhaustedSessionKey = sessionKey;
          // Restart subprocess — see restartAfterCreditExhausted comment.
          restartAfterCreditExhausted(sessionKey);
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
        clearToolTimersForSession(sessionId);
        sendWithSession(sessionId, { type: "result", text: fullText, sessionId, costUsd: 0, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 });
      }
      return;
    }
    // AUTH_REQUIRED: -32000 explicitly, or -32603 wrapping a 401
    if (isAcpAuthError(err)) {
      // Built-in mode: bundled API key is invalid. See the matching block in
      // the session/prompt path above for rationale.
      if (isBuiltinKeyMode()) {
        const errMsg = err instanceof Error ? err.message : String(err);
        logErr(`Query auth error in builtin mode (key may be rotated/invalid): ${errMsg}`);
        sendWithSession(sessionId, { type: "builtin_key_invalid", message: errMsg });
        return;
      }
      if (authRetryCount >= MAX_AUTH_RETRIES) {
        logErr(`Query auth error but max retries (${MAX_AUTH_RETRIES}) reached, giving up`);
        sendWithSession(sessionId, { type: "error", message: "Authentication required. Please disconnect and reconnect your Claude account in Settings." });
        return;
      }
      authRetryCount++;
      logErr(`Query failed with auth error (code=${(err as AcpError).code}), starting OAuth flow (attempt ${authRetryCount})`);
      try {
        await startAuthFlow();
      } catch (authErr) {
        if (isUserAbortedAuth(authErr)) {
          logErr(`Query OAuth flow ${authErr instanceof Error ? authErr.message : String(authErr)} — surfacing as assistant result`);
          sendAuthCancelledResult(sessionId, authErr);
          return;
        }
        throw authErr;
      }
      return handleQuery(msg, _retryDepth + 1);
    }
    const errMsg = err instanceof Error ? err.message : String(err);
    // Classify the outer-catch failure (overloaded / credit / other) via the
    // same helper used by the inner sites, so a 529 outage doesn't get bucketed
    // as credit_exhausted just because the SDK labels its retry events as
    // errorType="rate_limit".
    const outerApiRetryInfo = lastApiRetry as { httpStatus: number | null; errorType: string } | null;
    const outerFailureKind = classifyApiFailure(errMsg, outerApiRetryInfo);
    if (outerFailureKind === "overloaded") {
      logErr(`Upstream overload (outer): ${errMsg}`);
      sendWithSession(sessionId, { type: "upstream_overloaded", message: errMsg });
      lastApiRetry = null;
      return;
    }
    if (outerFailureKind === "credit") {
      logErr(`Credit/rate limit exhausted (outer): ${errMsg}`);
      sendWithSession(sessionId, { type: "credit_exhausted", message: errMsg });
      lastCreditExhaustedAt = Date.now();
      lastCreditExhaustedSessionKey = incomingSessionKey;
      // Restart subprocess — see restartAfterCreditExhausted comment.
      // incomingSessionKey is used here because the inner-scoped sessionKey
      // is not visible in this outer catch.
      restartAfterCreditExhausted(incomingSessionKey);
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

/** Whether the next text delta should be preceded by a boundary (e.g. after tool use) */
let pendingBoundary = false;

/**
 * Fork the live session under `fromSessionKey` and register the new branch
 * under `toSessionKey`. Calls upstream `session/fork` (unstable; provided by
 * `@agentclientprotocol/claude-agent-acp` via `unstable_forkSession`). The
 * branch starts at the end of the source session's conversation; the source
 * remains intact and resumable.
 */
async function handleForkSession(msg: import("./protocol.js").ForkSessionMessage): Promise<void> {
  const sourceEntry = sessions.get(msg.fromSessionKey);
  if (!sourceEntry) {
    logErr(`forkSession: source session not active (key=${msg.fromSessionKey}); cannot fork`);
    send({
      type: "error",
      message: `Cannot fork: no active session under key ${msg.fromSessionKey}`,
    });
    return;
  }

  // Two valid modes:
  //   1. In-place fork: `toSessionKey === fromSessionKey`. The new branch
  //      replaces the source under the same key (the source sessionId is
  //      still resumable on disk via Conversation History). This is the
  //      "fork the current chat" button UX.
  //   2. Side-by-side fork: a distinct `toSessionKey` (must not already be
  //      registered). The source remains live under `fromSessionKey` and the
  //      new branch is bound to `toSessionKey`. Reserved for a future
  //      "open fork in new pop-out" UX.
  const inPlace = msg.fromSessionKey === msg.toSessionKey;
  if (!inPlace && sessions.has(msg.toSessionKey)) {
    logErr(`forkSession: destination key already in use (${msg.toSessionKey}); aborting`);
    send({
      type: "error",
      message: `Cannot fork: session key ${msg.toSessionKey} is already active`,
    });
    return;
  }

  const cwd = msg.cwd ?? sourceEntry.cwd;
  const model = msg.model ?? sourceEntry.model;
  // Fork inherits the source's mode by default. We don't carry the mode in the
  // sessions Map, so fall back to "act" (most common) for MCP server selection
  // on the new branch; Swift can re-issue a `setMode` later if needed.
  const mode = "act";

  try {
    const result = (await acpRequest("session/fork", {
      sessionId: sourceEntry.sessionId,
      cwd,
      mcpServers: buildMcpServers(mode, cwd, msg.toSessionKey),
    })) as { sessionId: string };

    // For in-place fork, unregister the source first so the same key cleanly
    // points at the new sessionId. The source's sessionId is left on disk and
    // is recoverable via the Conversation History list (which scans the SDK's
    // JSONL store), so this is non-destructive.
    if (inPlace) {
      unregisterSession(msg.fromSessionKey);
    }

    registerSession(msg.toSessionKey, { sessionId: result.sessionId, cwd, model });
    if (model) {
      try {
        await acpRequest("session/set_model", { sessionId: result.sessionId, modelId: model });
      } catch (setModelErr) {
        logErr(`forkSession: set_model failed on new session ${result.sessionId}: ${setModelErr}`);
      }
    }
    logErr(
      `Session forked${inPlace ? " (in-place)" : ""}: ${sourceEntry.sessionId} -> ${result.sessionId} ` +
        `(key ${msg.fromSessionKey} -> ${msg.toSessionKey}, model=${model || "default"}, cwd=${cwd})`
    );
    send({
      type: "session_forked",
      fromSessionId: sourceEntry.sessionId,
      toSessionId: result.sessionId,
      fromSessionKey: msg.fromSessionKey,
      toSessionKey: msg.toSessionKey,
    });
  } catch (err) {
    const errMsg = err instanceof Error ? err.message : String(err);
    logErr(`session/fork failed: ${errMsg}`);
    send({ type: "error", message: `Fork failed: ${errMsg}` });
  }
}

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
      if (text) {
        // NOTE: Do NOT auto-complete pendingTools or clear watchdogs here.
        // The model can emit text WHILE tools are still in flight (parallel
        // tool use, interleaved reasoning, etc.). Tool completion is handled
        // exclusively by the `tool_call_update` case below, which receives a
        // terminal status (completed/failed/cancelled) per toolCallId. Clearing
        // watchdogs on text chunks caused 180s ACPBridge inactivity timeouts
        // because hung MCP tools (e.g. mcp__playwright__browser_tabs) had
        // their 120s safety net killed by interleaved assistant text.

        // Strip leading harness leaks (`(your turn — ...)` + `<system-reminder>`
        // blocks) before forwarding. We only buffer at the start of a query
        // turn; once stripping resolves, it short-circuits for the rest of
        // the turn so we don't add latency to normal text deltas.
        let outText = text;
        if (ctx && !ctx.prefixStripDone) {
          ctx.prefixBuffer += text;

          if (ctx.prefixBuffer.length > PREFIX_BUFFER_FLUSH_BYTES) {
            // Safety: don't swallow real content forever if the model emits
            // something we don't recognise. Flush whatever we have.
            outText = ctx.prefixBuffer;
            ctx.prefixBuffer = "";
            ctx.prefixStripDone = true;
          } else {
            const result = stripHarnessPrefix(ctx.prefixBuffer);
            if (result.done) {
              outText = result.suffix;
              ctx.prefixBuffer = "";
              ctx.prefixStripDone = true;
            } else {
              // Still inside (or possibly inside) the harness. Suppress this
              // chunk; the next one will retry the strip with more context.
              outText = "";
            }
          }
        }

        if (!outText) break;

        // Signal a boundary between text blocks only when resuming text
        // after a tool call (pendingBoundary). We no longer split on content
        // block index changes because the API can use multiple text blocks
        // within a single logical message, causing mid-word/mid-sentence splits.
        const effPendingBoundary = ctx ? ctx.pendingBoundary : pendingBoundary;
        if (effPendingBoundary) {
          sendWithSession(sid, { type: "text_block_boundary" });
          if (ctx) ctx.pendingBoundary = false; else pendingBoundary = false;
        }

        onText(outText);
        sendWithSession(sid, { type: "text_delta", text: outText });
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
        const inputSummary = summarizeToolInput(title, rawInput);
        const sessionKeyForLog = sid ? sessionIdToKey.get(sid) : undefined;
        logErr(
          `Tool started: ${title} (id=${toolCallId}, kind=${kind}, ` +
            `session=${sessionKeyForLog ?? sid ?? "?"})` +
            (inputSummary ? ` [${inputSummary}]` : " [no input yet]"),
        );

        // Track this tool so we can dump what's stuck when an interrupt fires
        inFlightTools.set(toolCallId, {
          title,
          kind,
          sessionId: sid,
          sessionKey: sessionKeyForLog,
          startedAt: Date.now(),
          rawInput,
          lastStatus: status,
          lastLoggedInputFingerprint: fingerprintInput(rawInput),
        });

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

      // Pending/in_progress updates often carry the *populated* rawInput that
      // was empty at tool_call time (Claude streams arguments). Record the
      // new payload and log once per distinct fingerprint so the Bash command
      // or Write target shows up in the log even if the tool later hangs.
      if (status === "pending" || status === "in_progress") {
        const rawInput = update.rawInput as Record<string, unknown> | undefined;
        const tracked = inFlightTools.get(toolCallId);
        if (tracked) {
          tracked.lastStatus = status;
          if (rawInput && Object.keys(rawInput).length > 0) {
            const fp = fingerprintInput(rawInput);
            if (fp !== tracked.lastLoggedInputFingerprint) {
              tracked.rawInput = rawInput;
              tracked.lastLoggedInputFingerprint = fp;
              const summary = summarizeToolInput(title, rawInput);
              if (summary) {
                logErr(
                  `Tool input: ${title} (id=${toolCallId}, session=${tracked.sessionKey ?? tracked.sessionId ?? "?"}) [${summary}]`,
                );
              }
            }
          }
        }
      }

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

        // Pull the final summary + duration from our in-flight tracker,
        // then drop the entry so it doesn't get flagged as stuck later.
        const tracked = inFlightTools.get(toolCallId);
        const finalRawInput =
          (update.rawInput as Record<string, unknown> | undefined) ?? tracked?.rawInput;
        const summary = summarizeToolInput(title, finalRawInput);
        const elapsedStr = tracked
          ? ` elapsed=${((Date.now() - tracked.startedAt) / 1000).toFixed(1)}s`
          : "";
        const sessionTag = tracked
          ? ` session=${tracked.sessionKey ?? tracked.sessionId ?? "?"}`
          : "";
        inFlightTools.delete(toolCallId);

        logErr(
          `Tool completed: ${title} (id=${toolCallId}${sessionTag}) status=${status} ` +
            `output=${output ? output.length + " chars" : "none"}${elapsedStr}` +
            (summary ? ` [${summary}]` : ""),
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
      // Arm the subagent-liveness watchdog so a silently-dead subagent
      // can't keep the SDK's `hasRunningDeferrableTasks` true forever.
      // ctx.sessionKey + sid let us route the cancel later; without either
      // we skip (watchdog can't recover the session without them).
      if (sid && ctx?.sessionKey) {
        startTaskTimer(taskId, description, sid, ctx.sessionKey);
      }
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
      // Real completion (not stale) — disarm the subagent watchdog.
      clearTaskTimer(taskId);
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

    case "available_commands_update": {
      // Slash-command list advertised by the agent. Forward to Swift so the
      // input-field popover can render the active set. Spec shape:
      // { availableCommands: [{ name, description, input?: { hint } }] }
      const rawCmds =
        (update.availableCommands as unknown[] | undefined) ??
        (update.available_commands as unknown[] | undefined) ??
        [];
      const commands = rawCmds
        .filter((c): c is Record<string, unknown> => typeof c === "object" && c !== null)
        .map((c) => {
          const name = typeof c.name === "string" ? c.name : "";
          const description = typeof c.description === "string" ? c.description : "";
          const inputObj = c.input as Record<string, unknown> | undefined;
          const inputHint = inputObj && typeof inputObj.hint === "string" ? inputObj.hint : undefined;
          return { name, description, inputHint };
        })
        .filter((c) => c.name.length > 0);
      sendWithSession(sid, { type: "available_commands_update", commands });
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

// SIGUSR2: dump bridge state to /tmp/fazm-bridge-state.json. Triggered by the
// Swift `getBridgeState` control command so the app and external tools can
// inspect the live session→PID map, in-flight queries, and per-session metadata
// without depending on stdio JSON-RPC. Used for CPU-regression A/B testing,
// orphan-subprocess audits, and customer-support diagnostics. We use SIGUSR2
// rather than SIGUSR1 because Node.js reserves SIGUSR1 for the inspector.
process.on("SIGUSR2", () => {
  try {
    const now = Date.now();
    const sessionRows: Array<Record<string, unknown>> = [];
    for (const [key, entry] of sessions) {
      const active = activeQueries.get(key);
      sessionRows.push({
        sessionKey: key,
        sessionId: entry.sessionId,
        sessionIdShort: entry.sessionId.slice(0, 8),
        cwd: entry.cwd,
        model: entry.model ?? null,
        hasActiveQuery: !!active,
        activeQueryMode: active?.mode ?? null,
        activeQueryInterruptRequested: active?.interruptRequested ?? null,
        activeQueryAborted: active?.abortController?.signal?.aborted ?? null,
      });
    }
    const orphanQueries: Array<Record<string, unknown>> = [];
    for (const [key, ctx] of activeQueries) {
      if (!sessions.has(key)) {
        orphanQueries.push({
          sessionKey: key,
          sessionId: ctx.sessionId,
          mode: ctx.mode,
          interruptRequested: ctx.interruptRequested,
          aborted: ctx.abortController?.signal?.aborted ?? null,
        });
      }
    }
    const payload = {
      timestamp: now,
      timestampIso: new Date(now).toISOString(),
      bridgePid: process.pid,
      bridgePpid: process.ppid,
      uptimeSec: Math.round(process.uptime()),
      sessionCount: sessions.size,
      activeQueryCount: activeQueries.size,
      sessionIdToKeyCount: sessionIdToKey.size,
      sessions: sessionRows,
      orphanQueries,
      memoryRss: process.memoryUsage().rss,
      memoryHeapUsed: process.memoryUsage().heapUsed,
    };
    const path = "/tmp/fazm-bridge-state.json";
    // `writeFileSync` is the ESM-imported top-of-file binding (line ~34).
    // Don't use `require("fs")` — this is an ES module so `require` is undefined.
    writeFileSync(path, JSON.stringify(payload, null, 2));
    logErr(`[CONTROL] SIGUSR2: bridge state dumped to ${path} (sessions=${sessions.size}, activeQueries=${activeQueries.size})`);
  } catch (err) {
    logErr(`[CONTROL] SIGUSR2 dump failed: ${(err as Error).message}`);
  }
});

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
  logErr(`MCP versions: playwright=${playwrightVersion}, macos-use=${existsSync(macosUseBinary) ? "bundled" : "missing"}, whatsapp=${existsSync(whatsappMcpBinary) ? "bundled" : "missing"}, google-workspace=${existsSync(googleWorkspaceMcpPython) ? "bundled" : "missing"}, browser-harness=${existsSync(browserHarnessMcpPython) ? "bundled" : "missing"}, ai-browser-profile=${existsSync(aiBrowserProfilePython) ? "bundled" : "missing"}, browserMode=${browserMode}`);
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

  // 2a. Start the long-running-tool heartbeat. When a tool runs for a while
  // (especially `kind=think` Task sub-agents) it can stop emitting status
  // updates while still doing real work. The Swift waitForMessage inactivity
  // timer would then fire and kill the conversation. Emit a periodic
  // `status_change` for each in-flight tool that's been running >60s; the
  // message itself is enough to reset Swift's timer because every inbound
  // message resets the per-session continuation. We don't emit anything for
  // freshly-started tools (they typically complete fast) or for tools that
  // already finished.
  const HEARTBEAT_INTERVAL_MS = 30_000;          // tick every 30s
  const HEARTBEAT_QUIET_THRESHOLD_MS = 60_000;   // start emitting after 60s
  const lastHeartbeatAt = new Map<string, number>();
  setInterval(() => {
    if (inFlightTools.size === 0) return;
    const now = Date.now();
    for (const [toolCallId, tool] of inFlightTools) {
      const elapsedMs = now - tool.startedAt;
      if (elapsedMs < HEARTBEAT_QUIET_THRESHOLD_MS) continue;
      const lastBeat = lastHeartbeatAt.get(toolCallId) ?? 0;
      if (now - lastBeat < HEARTBEAT_INTERVAL_MS) continue;
      lastHeartbeatAt.set(toolCallId, now);
      // Send a status_change "working" so Swift's waitForMessage timer resets.
      // Include the tool name so logs make sense.
      sendWithSession(tool.sessionId, {
        type: "status_change",
        status: `working:${tool.title}@${(elapsedMs / 1000).toFixed(0)}s`,
      });
      logErr(
        `Tool heartbeat: ${tool.title} (id=${toolCallId}, kind=${tool.kind}, ` +
          `session=${tool.sessionKey ?? tool.sessionId ?? "?"}) ` +
          `still running, elapsed=${(elapsedMs / 1000).toFixed(1)}s`,
      );
    }
    // Drop heartbeat timestamps for tools that have completed
    for (const id of lastHeartbeatAt.keys()) {
      if (!inFlightTools.has(id)) lastHeartbeatAt.delete(id);
    }
  }, HEARTBEAT_INTERVAL_MS).unref();

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
        // Emit warmup_complete with timing once preWarmSession resolves so the
        // Swift client can fire `bridge_warmup_ready` and we can directly measure
        // the cold-start window (paired with bridge_warmup_started in Swift).
        const warmupStartMs = Date.now();
        const sessionKeys: string[] = wm.sessions && wm.sessions.length > 0
          ? wm.sessions.map((s) => s.key)
          : (wm.models ?? (wm.model ? [wm.model] : []));
        if (wm.sessions && wm.sessions.length > 0) {
          logErr(`Warmup requested (cwd=${wm.cwd || "default"}, sessions=${sessionKeys.join(", ")})`);
          preWarmPromise = preWarmSession(wm.cwd, wm.sessions);
        } else {
          // Backward compat: models array or single model
          const models = wm.models ?? (wm.model ? [wm.model] : undefined);
          logErr(`Warmup requested (cwd=${wm.cwd || "default"}, models=${JSON.stringify(models) || "default"})`);
          preWarmPromise = preWarmSession(wm.cwd, undefined, models);
        }
        // Fire-and-forget: do not await here; let the main message loop continue.
        // The warmup_complete event reports total duration + outcome so Swift
        // can compute warmup-race exposure without polling.
        preWarmPromise
          .then((result) => {
            const durationMs = Date.now() - warmupStartMs;
            const failed = result?.failedSessions ?? [];
            if (failed.length === 0) {
              logErr(`Warmup complete in ${durationMs}ms (sessions=${sessionKeys.join(",")})`);
              send({
                type: "warmup_complete",
                durationMs,
                sessionKeys,
                ok: true,
              });
              return;
            }
            // Some (or all) sessions hung or threw — report which, the coarse
            // stage, and the claude-agent-acp stderr tail so we can diagnose
            // a stuck warmup remotely instead of needing the user's log file.
            const failureStage = classifyWarmupFailure(failed);
            const errMsg = failed.map((f) => `${f.key}: ${f.error}`).join("; ");
            logErr(`Warmup PARTIAL/FAILED after ${durationMs}ms — stage=${failureStage}, failed=[${failed.map((f) => f.key).join(",")}]`);
            send({
              type: "warmup_complete",
              durationMs,
              sessionKeys,
              ok: false,
              error: errMsg,
              failureStage,
              failedSessions: failed.map((f) => f.key),
              stderrTail: getAcpStderrTail(),
            });
          })
          .catch((err) => {
            const durationMs = Date.now() - warmupStartMs;
            const errMsg = err instanceof Error ? err.message : String(err);
            logErr(`Warmup failed after ${durationMs}ms: ${errMsg}`);
            send({
              type: "warmup_complete",
              durationMs,
              sessionKeys,
              ok: false,
              error: errMsg,
              failureStage: classifyWarmupFailure([{ key: "warmup", error: errMsg }]),
              stderrTail: getAcpStderrTail(),
            });
          });
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
            logStuckToolsOnInterrupt(`user interrupt (key=${targetKey})`, ctx.sessionId);
            ctx.interruptRequested = true;
            ctx.abortController.abort();
            acpNotify("session/cancel", { sessionId: ctx.sessionId });
            interruptedSessions.add(ctx.sessionId);
            // Invalidate the cached session entry so the next prompt forces a
            // fresh session via stuck-session recovery (priorContext replay).
            // Reusing a mid-stream-cancelled session is unsafe: the upstream
            // SDK may keep producing chunks for the cancelled prompt and
            // deliver them as the result of the NEXT prompt on the same
            // sessionId, contaminating the new turn (Apr 29 2026 incident —
            // Q1's deferred response was served as Q2's answer). The resume
            // path below picks this up via interruptedSessions.has(msg.resume)
            // and skips resume entirely.
            unregisterSession(targetKey);
            imageTurnCounts.delete(targetKey);
            logErr(`Session ${ctx.sessionId} marked as interrupted and invalidated (next prompt will force fresh session with priorContext replay)`);
          } else if (codexProvider && interruptCodexSession(targetKey, codexProvider)) {
            // Same key may be a codex session — interrupt and drop it.
            logErr(`Interrupt requested for codex session key=${targetKey} (cancelled + dropped)`);
          } else {
            logErr(`Interrupt requested for session key=${targetKey} but no active query found`);
          }
        } else {
          // Legacy: no sessionKey specified, interrupt all active queries
          logErr("Interrupt requested by user (all sessions)");
          logStuckToolsOnInterrupt("user interrupt (all sessions)");
          interruptRequested = true;
          if (activeAbort) activeAbort.abort();
          for (const [key, ctx] of activeQueries) {
            ctx.interruptRequested = true;
            ctx.abortController.abort();
            acpNotify("session/cancel", { sessionId: ctx.sessionId });
            interruptedSessions.add(ctx.sessionId);
            // Same invalidation as the per-session branch above: drop the
            // cached entry so the next prompt cannot reuse a dirty session.
            unregisterSession(key);
            imageTurnCounts.delete(key);
            logErr(`Session ${ctx.sessionId} (key=${key}) marked as interrupted and invalidated`);
          }
          if (activeSessionId && !activeQueries.size) {
            // Fallback for legacy single-query path
            acpNotify("session/cancel", { sessionId: activeSessionId });
            interruptedSessions.add(activeSessionId);
            logErr(`Session ${activeSessionId} marked as interrupted (legacy fallback)`);
          }
          // Cancel any in-flight codex sessions too.
          if (codexProvider && codexSessionCount() > 0) {
            const n = interruptAllCodexSessions(codexProvider);
            logErr(`Interrupted ${n} codex session(s)`);
          }
        }
        break;
      }

      case "close_session": {
        // Swift's pop-out windowWillClose calls this so the bridge fully tears
        // down the session: cancel any in-flight query, ask the SDK to close
        // its session (which terminates the underlying `claude` subprocess via
        // the agent-acp library), drop the in-memory entry. Without this, the
        // pre-warmed session map kept warm subprocesses alive forever, which
        // was the structural cause of the CPU regression reported 2026-05-14.
        const closeKey = (msg as { sessionKey?: string }).sessionKey;
        if (!closeKey) {
          logErr("close_session: missing sessionKey");
          break;
        }
        const entry = sessions.get(closeKey);
        const ctx = activeQueries.get(closeKey);
        if (ctx && !ctx.abortController.signal.aborted) {
          logErr(`close_session: aborting in-flight query for key=${closeKey} sessionId=${ctx.sessionId.slice(0, 8)}`);
          ctx.interruptRequested = true;
          ctx.abortController.abort();
          acpNotify("session/cancel", { sessionId: ctx.sessionId });
        }
        if (entry) {
          logErr(`close_session: closing key=${closeKey} sessionId=${entry.sessionId.slice(0, 8)}`);
          // session/close instructs the SDK to terminate the claude subprocess
          // tied to this session. Fire-and-forget — we don't gate the unregister
          // on its completion because the bridge has authoritative session state
          // and the subprocess will exit regardless.
          acpRequest("session/close", { sessionId: entry.sessionId }).catch((err) => {
            logErr(`close_session: session/close RPC failed for ${entry.sessionId.slice(0, 8)}: ${err}`);
          });
          unregisterSession(closeKey);
          imageTurnCounts.delete(closeKey);
        } else {
          logErr(`close_session: no session found for key=${closeKey} (already closed?)`);
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

      case "forkSession": {
        handleForkSession(msg as import("./protocol.js").ForkSessionMessage).catch((err) => {
          logErr(`Unhandled forkSession error: ${err}`);
          send({ type: "error", message: `Fork failed: ${err}` });
        });
        break;
      }

      case "transferSession": {
        const { fromKey, toKey } = msg as import("./protocol.js").TransferSessionMessage;
        if (fromKey && toKey && sessions.has(fromKey)) {
          const entry = sessions.get(fromKey)!;
          unregisterSession(fromKey);
          // P4: a spare-pool session is warmed at homedir, not the pop-out's
          // real workspace. Mark it uncommitted so the pop-out's first query
          // can switch cwd silently — there is no conversation to preserve yet.
          // A floating->detached transfer carries a real conversation, so it
          // stays committed (a later cwd flap there must go through recovery).
          if (fromKey === "spare") entry.uncommitted = true;
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
        // Drop any codex session under this key first — same key can map to
        // either provider depending on the user's selected model.
        if (key && codexProvider) {
          dropCodexSession(key, codexProvider);
        }
        if (key && sessions.has(key)) {
          const oldSessionId = sessions.get(key)?.sessionId;
          if (oldSessionId) interruptedSessions.delete(oldSessionId);
          unregisterSession(key);
          imageTurnCounts.delete(key);
          logErr(`Session reset: ${key}`);
        }
        // Immediately pre-warm a fresh session so the first query doesn't wait.
        // This runs even when the key is no longer registered: `transferSession`
        // removes the key from `sessions`, so a transfer-then-reset (the pop-out
        // path) would otherwise silently skip the re-warm the caller asked for.
        if (key && !sessions.has(key)) {
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
        if (codexProvider?.isRunning()) {
          try { codexProvider.shutdown(); } catch { /* already gone */ }
        }
        process.exit(0);
        break;

      case "codex_init_probe":
        handleCodexInitProbe().catch((err) => {
          logErr(`codex probe handler threw: ${err}`);
        });
        break;

      case "codex_login":
        handleCodexLogin().catch((err) => {
          logErr(`codex login handler threw: ${err}`);
        });
        break;

      case "codex_login_cancel":
        if (activeCodexLogin) {
          activeCodexLogin.cancel();
          activeCodexLogin = null;
          logErr("[codex-oauth] login cancelled by user");
        }
        break;

      case "codex_logout":
        handleCodexLogout().catch((err) => {
          logErr(`codex logout handler threw: ${err}`);
        });
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

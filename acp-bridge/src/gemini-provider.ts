/**
 * GeminiProvider — wrapper around `@google/gemini-cli`'s `--experimental-acp`
 * mode. Spawns the bundled gemini.js (Node script, not a native binary) and
 * speaks the ACP JSON-RPC dialect over stdio.
 *
 * Mirrors CodexProvider so the two ACP-shaped backends share the same surface
 * (request/notify, session handler registration, server-request handling).
 * The two differences from Codex:
 *   1. The binary is a JS entry, so we spawn `node bundle/gemini.js` rather
 *      than a native binary.
 *   2. Gemini CLI requires an explicit `authenticate` JSON-RPC call after
 *      `initialize` (Codex authenticates implicitly via ~/.codex/auth.json).
 *
 * This module is feature-flagged at the index.ts level via
 * FAZM_GEMINI_ENABLED=true; the file itself is dormant otherwise.
 */

import { spawn, type ChildProcess } from "child_process";
import { createInterface } from "readline";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { existsSync } from "fs";
import type { PermissionReply } from "./approval-gate.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

type ResponseHandler = {
  resolve: (result: unknown) => void;
  reject: (err: Error) => void;
};

type NotificationHandler = (method: string, params: unknown) => void;

export class GeminiAcpError extends Error {
  code: number;
  data?: unknown;
  constructor(message: string, code: number, data?: unknown) {
    super(message);
    this.name = "GeminiAcpError";
    this.code = code;
    this.data = data;
  }
}

export interface GeminiProviderOptions {
  /** Override the resolved gemini.js entry path (used by tests). */
  entryPath?: string;
  env?: NodeJS.ProcessEnv;
  logErr?: (msg: string) => void;
  onExit?: (code: number | null) => void;
  onNotification?: NotificationHandler;
  onPermissionRequest?: (params: unknown) => string;
  /** When set, fully owns replying to session/request_permission (may defer
   *  the reply — approval gate). Takes precedence over onPermissionRequest. */
  onPermissionGate?: (rpcId: number, params: unknown, reply: (result: PermissionReply) => void) => void;
}

export interface GeminiInitResult {
  protocolVersion: number;
  agentCapabilities?: Record<string, unknown>;
  agentInfo?: { name: string; version: string; title?: string };
  authMethods?: Array<{
    id: string;
    name: string;
    description?: string;
  }>;
}

/** Relative path to the bundled CLI entry inside acp-bridge/node_modules. */
const DEFAULT_ENTRY_REL = join(
  "node_modules",
  "@google",
  "gemini-cli",
  "bundle",
  "gemini.js",
);

/** Decide which gemini-cli auth method to use based on environment. */
export function pickGeminiAuthMethod(env: NodeJS.ProcessEnv): string | null {
  if (env.GOOGLE_GENAI_USE_VERTEXAI === "true" || env.GOOGLE_GENAI_USE_VERTEXAI === "1") {
    return "vertex-ai";
  }
  if (env.GEMINI_API_KEY || env.GOOGLE_API_KEY) {
    return "gemini-api-key";
  }
  // OAuth-personal requires an interactive browser flow that's hostile to a
  // background subprocess; refuse rather than hang.
  return null;
}

/**
 * Decide where an inbound gemini-cli notification should go.
 *
 * Normally the notification's sessionId matches a registered session handler
 * and we route directly. But gemini-cli (0.42.0) is observed in production to
 * emit `session/update` notifications under a sessionId that does NOT match the
 * one `session/new`/`session/load` returned (heavy on resumed sessions, model
 * switches, and concurrent floating+detached sessions). Those carry the
 * assistant text, so dropping them surfaces as an empty turn or a timeout.
 *
 * Rescue rule: when an unmatched `session/update` arrives AND exactly one prompt
 * is in flight, attribute it to that prompt's session. We require exactly one
 * active prompt so we never misattribute text across concurrent turns; with 0
 * or 2+ active prompts we fall back to the legacy "unrouted" path (drop) rather
 * than guess. Non-`session/update` notifications are never rescued.
 *
 * Pure + exported so it can be unit-tested without spawning gemini-cli.
 */
export function decideGeminiRoute(args: {
  updateSessionId: string | undefined;
  hasHandler: (id: string) => boolean;
  activePromptSessionIds: ReadonlySet<string>;
  isSessionUpdate: boolean;
}): { kind: "direct" | "rescue"; sessionId: string } | { kind: "unrouted" } {
  const { updateSessionId, hasHandler, activePromptSessionIds, isSessionUpdate } = args;
  if (updateSessionId && hasHandler(updateSessionId)) {
    return { kind: "direct", sessionId: updateSessionId };
  }
  if (isSessionUpdate && activePromptSessionIds.size === 1) {
    const activeId = [...activePromptSessionIds][0];
    if (hasHandler(activeId)) return { kind: "rescue", sessionId: activeId };
  }
  return { kind: "unrouted" };
}

export class GeminiProvider {
  readonly name = "gemini";

  private process: ChildProcess | null = null;
  private stdinWriter: ((line: string) => void) | null = null;
  private responseHandlers = new Map<number, ResponseHandler>();
  private sessionNotificationHandlers = new Map<string, NotificationHandler>();
  private nextRpcId = 1;
  private isInitialized = false;
  private initPromise: Promise<GeminiInitResult> | null = null;
  private cachedInit: GeminiInitResult | null = null;
  private authComplete = false;
  /** Most recent stderr blob containing a turn error so query.ts can replace
   *  the generic JSON-RPC "Internal error" with the real reason. */
  private lastTurnError: { message: string; at: number } | null = null;
  /** sessionIds with a `session/prompt` currently in flight. Drives the
   *  unmatched-`session/update` rescue in routeNotification (see
   *  decideGeminiRoute). */
  private activePromptSessionIds = new Set<string>();
  /** Count of rescued (id-mismatched) session/update notifications, for logging. */
  private rescuedUpdateCount = 0;

  private readonly entryPath: string;
  private readonly env: NodeJS.ProcessEnv;
  private readonly logErr: (msg: string) => void;
  private readonly onExitHook?: (code: number | null) => void;
  private readonly onNotificationHook?: NotificationHandler;
  private readonly onPermissionRequest: (params: unknown) => string;
  private readonly onPermissionGate?: GeminiProviderOptions["onPermissionGate"];

  constructor(opts: GeminiProviderOptions = {}) {
    this.entryPath = opts.entryPath ?? GeminiProvider.resolveDefaultEntry();
    this.env = opts.env ?? process.env;
    this.logErr = opts.logErr ?? ((m) => process.stderr.write(`[gemini-provider] ${m}\n`));
    this.onExitHook = opts.onExit;
    this.onNotificationHook = opts.onNotification;
    this.onPermissionRequest = opts.onPermissionRequest ?? GeminiProvider.defaultPermissionResolver;
    this.onPermissionGate = opts.onPermissionGate;
  }

  static resolveDefaultEntry(): string {
    const bridgeRoot = join(__dirname, "..");
    return join(bridgeRoot, DEFAULT_ENTRY_REL);
  }

  static defaultPermissionResolver(params: unknown): string {
    const p = params as Record<string, unknown> | undefined;
    const options = (p?.options as Array<{ kind: string; optionId: string }>) ?? [];
    return (
      options.find((o) => o.kind === "allow_always")?.optionId
      ?? options.find((o) => o.kind === "allow_once")?.optionId
      ?? options[0]?.optionId
      ?? "allow"
    );
  }

  isRunning(): boolean {
    return this.process !== null;
  }

  registerSessionHandler(sessionId: string, handler: NotificationHandler): void {
    this.sessionNotificationHandlers.set(sessionId, handler);
  }

  unregisterSessionHandler(sessionId: string): void {
    this.sessionNotificationHandlers.delete(sessionId);
  }

  /** Mark a session/prompt as in flight so unmatched session/update can be
   *  rescued to it (see decideGeminiRoute). Idempotent. */
  beginActivePrompt(sessionId: string): void {
    this.activePromptSessionIds.add(sessionId);
  }

  /** Clear the in-flight marker once a prompt resolves/errors. */
  endActivePrompt(sessionId: string): void {
    this.activePromptSessionIds.delete(sessionId);
  }

  start(): void {
    if (this.process) return;

    if (!existsSync(this.entryPath)) {
      throw new Error(`gemini-cli entry not found: ${this.entryPath}`);
    }

    this.logErr(`spawning gemini-cli: node ${this.entryPath} --experimental-acp`);
    // gemini-cli silently skips MCP server registration when the workspace
    // isn't in `~/.gemini/trustedFolders.json` (see chunk-7VVHSNDQ.js
    // `McpClientManager.startConfiguredMcpServers()`: returns early if
    // `!isTrustedFolder()`). `GEMINI_CLI_TRUST_WORKSPACE=true` is the
    // documented env-var escape hatch in `checkPathTrust()` that short-
    // circuits the whole trust check. Setting it only in the subprocess
    // env keeps user-level gemini-cli settings untouched.
    const spawnEnv: NodeJS.ProcessEnv = {
      ...this.env,
      GEMINI_CLI_TRUST_WORKSPACE: "true",
    };
    const proc = spawn(process.execPath, [this.entryPath, "--experimental-acp"], {
      env: spawnEnv,
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });

    if (!proc.stdin || !proc.stdout || !proc.stderr) {
      throw new Error("gemini-cli subprocess pipes not available");
    }

    this.process = proc;

    this.stdinWriter = (line: string) => {
      try {
        proc.stdin?.write(line + "\n");
      } catch (err) {
        this.logErr(`stdin write failed: ${err}`);
      }
    };

    const stdoutRl = createInterface({ input: proc.stdout, terminal: false });
    stdoutRl.on("line", (line) => this.handleStdoutLine(line));

    proc.stderr.on("data", (data: Buffer) => {
      const text = data.toString().trim();
      if (!text) return;
      this.logErr(`(stderr) ${text}`);
      for (const line of text.split("\n")) {
        const turnErr = GeminiProvider.extractTurnError(line);
        if (turnErr) this.lastTurnError = { message: turnErr, at: Date.now() };
      }
    });

    proc.on("exit", (code) => {
      this.logErr(`gemini-cli exited code=${code}`);
      this.process = null;
      this.stdinWriter = null;
      this.isInitialized = false;
      this.authComplete = false;
      this.initPromise = null;
      this.cachedInit = null;
      for (const [, handler] of this.responseHandlers) {
        handler.reject(new Error(`gemini-cli exited (code ${code})`));
      }
      this.responseHandlers.clear();
      this.onExitHook?.(code);
    });
  }

  shutdown(): void {
    const proc = this.process;
    if (!proc) return;
    const pid = proc.pid;
    try {
      if (pid) process.kill(-pid, "SIGTERM");
      else proc.kill("SIGTERM");
    } catch {
      try { proc.kill("SIGTERM"); } catch { /* already dead */ }
    }
    this.process = null;
  }

  request(method: string, params: Record<string, unknown> = {}): Promise<unknown> {
    if (!this.process) this.start();
    const id = this.nextRpcId++;
    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });

    return new Promise((resolve, reject) => {
      this.responseHandlers.set(id, { resolve, reject });
      if (this.stdinWriter) {
        this.stdinWriter(msg);
      } else {
        this.responseHandlers.delete(id);
        reject(new Error("gemini-cli stdin not available"));
      }
    });
  }

  notify(method: string, params: Record<string, unknown> = {}): void {
    if (!this.process) this.start();
    const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
    this.stdinWriter?.(msg);
  }

  async initialize(): Promise<GeminiInitResult> {
    if (this.cachedInit) return this.cachedInit;
    if (this.initPromise) return this.initPromise;

    this.initPromise = (async () => {
      const result = (await this.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      })) as GeminiInitResult;
      this.isInitialized = true;
      this.cachedInit = result;
      this.logErr(
        `initialized: protocol=${result.protocolVersion}, agent=${result.agentInfo?.name}@${result.agentInfo?.version}`,
      );
      return result;
    })();

    try {
      return await this.initPromise;
    } catch (err) {
      this.initPromise = null;
      throw err;
    }
  }

  /**
   * Pick an auth method from env and send `authenticate` to the agent.
   * Idempotent: once successful, subsequent calls short-circuit.
   * Throws if no usable auth method is configured (e.g. no GEMINI_API_KEY
   * and Vertex mode is off).
   */
  async authenticate(): Promise<void> {
    if (this.authComplete) return;
    const methodId = pickGeminiAuthMethod(this.env);
    if (!methodId) {
      throw new Error(
        "No usable Gemini auth method: set GEMINI_API_KEY, or GOOGLE_GENAI_USE_VERTEXAI=true with GOOGLE_CLOUD_PROJECT.",
      );
    }
    await this.request("authenticate", { methodId });
    this.authComplete = true;
    this.logErr(`authenticated via ${methodId}`);
  }

  /** Get cached init result (or null if not yet initialized). */
  getInitResult(): GeminiInitResult | null {
    return this.cachedInit;
  }

  /** Return the most recent gemini-cli turn error if it was captured within
   *  `maxAgeMs`. gemini-query uses this to replace the generic JSON-RPC
   *  "Internal error" with the real reason. */
  getRecentTurnError(maxAgeMs = 8000): string | null {
    if (!this.lastTurnError) return null;
    if (Date.now() - this.lastTurnError.at > maxAgeMs) return null;
    return this.lastTurnError.message;
  }

  /**
   * Parse a gemini-cli stderr line for an error message worth surfacing.
   * gemini-cli prints various non-fatal lines (telemetry, "Skipping project
   * agents"). Only treat lines containing "Error:" or "RESOURCE_EXHAUSTED" or
   * "exhausted your daily quota" as turn errors.
   */
  static extractTurnError(line: string): string | null {
    // eslint-disable-next-line no-control-regex
    const clean = line.replace(/\x1b\[[0-9;]*m/g, "").trim();
    if (!clean) return null;
    if (
      clean.includes("RESOURCE_EXHAUSTED") ||
      clean.toLowerCase().includes("exhausted your daily quota") ||
      /\bError:\s/.test(clean)
    ) {
      return clean.length > 400 ? clean.slice(0, 400) + "…" : clean;
    }
    return null;
  }

  private handleStdoutLine(line: string): void {
    if (!line.trim()) return;
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.logErr(`failed to parse stdout: ${line.slice(0, 200)}`);
      return;
    }

    const id = msg.id;
    const method = msg.method;

    if (typeof method === "string" && id !== undefined && id !== null) {
      this.handleServerRequest(id as number, method, msg.params);
      return;
    }

    if (id !== undefined && id !== null) {
      const handler = this.responseHandlers.get(id as number);
      if (!handler) return;
      this.responseHandlers.delete(id as number);
      if ("error" in msg) {
        const err = msg.error as { code: number; message: string; data?: unknown };
        handler.reject(new GeminiAcpError(err.message, err.code, err.data));
      } else {
        handler.resolve(msg.result);
      }
      return;
    }

    if (typeof method === "string") {
      this.routeNotification(method, msg.params);
    }
  }

  private handleServerRequest(id: number, method: string, params: unknown): void {
    if (method === "session/request_permission") {
      if (this.onPermissionGate) {
        // Approval gate owns the reply (may defer it pending a user decision).
        this.onPermissionGate(id, params, (result) => {
          this.stdinWriter?.(JSON.stringify({ jsonrpc: "2.0", id, result }));
        });
        return;
      }
      const optionId = this.onPermissionRequest(params);
      this.stdinWriter?.(JSON.stringify({
        jsonrpc: "2.0",
        id,
        result: { outcome: { outcome: "selected", optionId } },
      }));
      return;
    }
    if (method === "session/update") {
      this.routeNotification(method, params);
      this.stdinWriter?.(JSON.stringify({ jsonrpc: "2.0", id, result: null }));
      return;
    }
    this.logErr(`unhandled server request: ${method} (id=${id})`);
    this.stdinWriter?.(JSON.stringify({
      jsonrpc: "2.0",
      id,
      error: { code: -32601, message: `Method not handled: ${method}` },
    }));
  }

  private routeNotification(method: string, params: unknown): void {
    const sessionId = GeminiProvider.extractSessionId(params);
    const decision = decideGeminiRoute({
      updateSessionId: sessionId,
      hasHandler: (id) => this.sessionNotificationHandlers.has(id),
      activePromptSessionIds: this.activePromptSessionIds,
      isSessionUpdate: method === "session/update",
    });

    if (decision.kind === "direct") {
      this.sessionNotificationHandlers.get(decision.sessionId)?.(method, params);
      return;
    }

    if (decision.kind === "rescue") {
      this.rescuedUpdateCount++;
      // Log the first few and then sample, so a long stream doesn't flood stderr
      // but the bug stays visible in support logs.
      if (this.rescuedUpdateCount <= 3 || this.rescuedUpdateCount % 50 === 0) {
        const kind = (params as Record<string, unknown> | undefined)?.update as Record<string, unknown> | undefined;
        this.logErr(
          `rescued id-mismatched session/update (${(kind?.sessionUpdate as string) ?? "?"}) from sessionId=${sessionId ?? "?"} -> active session ${decision.sessionId.slice(0, 8)} (count=${this.rescuedUpdateCount})`,
        );
      }
      this.sessionNotificationHandlers.get(decision.sessionId)?.(method, params);
      return;
    }

    if (this.onNotificationHook) this.onNotificationHook(method, params);
  }

  private static extractSessionId(params: unknown): string | undefined {
    const p = params as Record<string, unknown> | undefined;
    if (typeof p?.sessionId === "string") return p.sessionId;
    const update = p?.update as Record<string, unknown> | undefined;
    if (typeof update?.sessionId === "string") return update.sessionId;
    return undefined;
  }
}

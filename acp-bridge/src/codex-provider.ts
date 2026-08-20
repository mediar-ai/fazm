/**
 * CodexProvider — isolated wrapper around @zed-industries/codex-acp.
 *
 * Mirrors the JSON-RPC over stdio surface that the existing claude-acp
 * spawn code in index.ts exposes (acpRequest / acpNotify / response handler
 * map / per-session notification routing), but as a self-contained class
 * so it can run alongside the Claude provider without sharing globals.
 *
 * Phase 1: this module is unused by index.ts. It exists so it can be
 * exercised in isolation by a smoke test before Phase 2 wires it in.
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

export class CodexAcpError extends Error {
  code: number;
  data?: unknown;
  constructor(message: string, code: number, data?: unknown) {
    super(message);
    this.name = "CodexAcpError";
    this.code = code;
    this.data = data;
  }
}

export interface CodexProviderOptions {
  binaryPath?: string;
  env?: NodeJS.ProcessEnv;
  logErr?: (msg: string) => void;
  onExit?: (code: number | null) => void;
  onNotification?: NotificationHandler;
  onPermissionRequest?: (params: unknown) => string;
  /** When set, fully owns replying to session/request_permission (may defer
   *  the reply — approval gate). Takes precedence over onPermissionRequest. */
  onPermissionGate?: (rpcId: number, params: unknown, reply: (result: PermissionReply) => void) => void;
}

export interface CodexInitResult {
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
}

const DEFAULT_BINARY_REL = join(
  "node_modules",
  "@zed-industries",
  process.arch === "arm64" ? "codex-acp-darwin-arm64" : "codex-acp-darwin-x64",
  "bin",
  "codex-acp"
);

export class CodexProvider {
  readonly name = "codex";

  private process: ChildProcess | null = null;
  private stdinWriter: ((line: string) => void) | null = null;
  private responseHandlers = new Map<number, ResponseHandler>();
  private sessionNotificationHandlers = new Map<string, NotificationHandler>();
  private nextRpcId = 1;
  private isInitialized = false;
  private initPromise: Promise<CodexInitResult> | null = null;
  private cachedInit: CodexInitResult | null = null;
  /** Most recent "Unhandled error during turn" message scraped from codex-acp
   *  stderr. The JSON-RPC error for a failed session/prompt is just a generic
   *  "Internal error"; the actionable reason (usage limit, auth, etc.) only
   *  shows up on stderr, so we capture it here for codex-query to surface. */
  private lastTurnError: { message: string; at: number } | null = null;

  private readonly binaryPath: string;
  private readonly env: NodeJS.ProcessEnv;
  private readonly logErr: (msg: string) => void;
  private readonly onExitHook?: (code: number | null) => void;
  private readonly onNotificationHook?: NotificationHandler;
  private readonly onPermissionRequest: (params: unknown) => string;
  private readonly onPermissionGate?: CodexProviderOptions["onPermissionGate"];

  constructor(opts: CodexProviderOptions = {}) {
    this.binaryPath = opts.binaryPath ?? CodexProvider.resolveDefaultBinary();
    this.env = opts.env ?? process.env;
    this.logErr = opts.logErr ?? ((m) => process.stderr.write(`[codex-provider] ${m}\n`));
    this.onExitHook = opts.onExit;
    this.onNotificationHook = opts.onNotification;
    this.onPermissionRequest = opts.onPermissionRequest ?? CodexProvider.defaultPermissionResolver;
    this.onPermissionGate = opts.onPermissionGate;
  }

  static resolveDefaultBinary(): string {
    const bridgeRoot = join(__dirname, "..");
    return join(bridgeRoot, DEFAULT_BINARY_REL);
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

  start(): void {
    if (this.process) return;

    if (!existsSync(this.binaryPath)) {
      throw new Error(`codex-acp binary not found: ${this.binaryPath}`);
    }

    this.logErr(`spawning codex-acp: ${this.binaryPath}`);
    const proc = spawn(this.binaryPath, [], {
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });

    if (!proc.stdin || !proc.stdout || !proc.stderr) {
      throw new Error("codex-acp subprocess pipes not available");
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
        const turnErr = CodexProvider.extractTurnError(line);
        if (turnErr) this.lastTurnError = { message: turnErr, at: Date.now() };
      }
    });

    proc.on("exit", (code) => {
      this.logErr(`codex-acp exited code=${code}`);
      this.process = null;
      this.stdinWriter = null;
      this.isInitialized = false;
      this.initPromise = null;
      this.cachedInit = null;
      for (const [, handler] of this.responseHandlers) {
        handler.reject(new Error(`codex-acp exited (code ${code})`));
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
        reject(new Error("codex-acp stdin not available"));
      }
    });
  }

  notify(method: string, params: Record<string, unknown> = {}): void {
    if (!this.process) this.start();
    const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
    this.stdinWriter?.(msg);
  }

  async initialize(): Promise<CodexInitResult> {
    if (this.cachedInit) return this.cachedInit;
    if (this.initPromise) return this.initPromise;

    this.initPromise = (async () => {
      const result = (await this.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
      })) as CodexInitResult;
      this.isInitialized = true;
      this.cachedInit = result;
      this.logErr(
        `initialized: protocol=${result.protocolVersion}, agent=${result.agentInfo?.name}@${result.agentInfo?.version}`
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

  /** Get cached init result (or null if not yet initialized). */
  getInitResult(): CodexInitResult | null {
    return this.cachedInit;
  }

  /** Return the most recent codex-acp turn error if it was captured within
   *  `maxAgeMs`. codex-query uses this to replace the generic JSON-RPC
   *  "Internal error" with the real reason (e.g. "You've hit your usage limit"). */
  getRecentTurnError(maxAgeMs = 8000): string | null {
    if (!this.lastTurnError) return null;
    if (Date.now() - this.lastTurnError.at > maxAgeMs) return null;
    return this.lastTurnError.message;
  }

  /** Parse a codex-acp stderr line for an "Unhandled error during turn:"
   *  message, stripping ANSI color codes and the trailing rust debug suffix
   *  (e.g. " Some(UsageLimitExceeded)"). Returns null if the line isn't one. */
  static extractTurnError(line: string): string | null {
    // eslint-disable-next-line no-control-regex
    const clean = line.replace(/\x1b\[[0-9;]*m/g, "");
    const marker = "Unhandled error during turn:";
    const idx = clean.indexOf(marker);
    if (idx === -1) return null;
    const msg = clean
      .slice(idx + marker.length)
      .replace(/\s+Some\([^)]*\)\s*$/, "")
      .trim();
    return msg || null;
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
        handler.reject(new CodexAcpError(err.message, err.code, err.data));
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
    const sessionId = CodexProvider.extractSessionId(params);
    const sessionHandler = sessionId ? this.sessionNotificationHandlers.get(sessionId) : undefined;
    if (sessionHandler) {
      sessionHandler(method, params);
    } else if (this.onNotificationHook) {
      this.onNotificationHook(method, params);
    }
  }

  private static extractSessionId(params: unknown): string | undefined {
    const p = params as Record<string, unknown> | undefined;
    if (typeof p?.sessionId === "string") return p.sessionId;
    const update = p?.update as Record<string, unknown> | undefined;
    if (typeof update?.sessionId === "string") return update.sessionId;
    return undefined;
  }
}

// Approval gate for ACP `session/request_permission` requests ("cage mode").
//
// Historically every provider (claude / codex / gemini) blanket-auto-approved
// tool permissions, which let the agent run destructive actions (rm, cache
// clears, file edits) without the user ever seeing them. This module gates
// those requests behind an explicit user decision, controlled by the
// FAZM_APPROVAL_MODE env var (read at bridge spawn time, like FAZM_BROWSER_MODE):
//
//   off          (default) — auto-approve everything, exactly today's behavior.
//                 Headless runners (cron-runner.mjs, founder-chat) never set the
//                 var, so they stay on `off` and can never hang on approval.
//   destructive  — gate only requests whose toolCall `kind` is edit / delete /
//                 move / execute; read / search / fetch / think / other stay
//                 auto-approved.
//   always       — gate every request.
//
// Gating = do NOT reply to the JSON-RPC request yet. Instead emit a
// `permission_request` event to the Swift app, and reply when Swift sends the
// `permission_response` stdin command (or the 300s timeout / an interrupt /
// close_session / bridge shutdown flushes the request as cancelled — a pending
// gate must never hang a session forever).

export type ApprovalMode = "off" | "destructive" | "always";

/** ACP tool-call kinds considered destructive in `destructive` mode. */
const DESTRUCTIVE_KINDS = new Set(["edit", "delete", "move", "execute"]);

export function currentApprovalMode(env: NodeJS.ProcessEnv = process.env): ApprovalMode {
  const v = env.FAZM_APPROVAL_MODE;
  return v === "destructive" || v === "always" ? v : "off";
}

/** Whether a request with the given toolCall `kind` must be gated under `mode`.
 *  A missing/unknown kind is NOT gated in destructive mode (matches the spec:
 *  only the explicit destructive kinds pause; everything else auto-approves). */
export function shouldGate(mode: ApprovalMode, kind: string | undefined): boolean {
  if (mode === "always") return true;
  if (mode === "destructive") return kind !== undefined && DESTRUCTIVE_KINDS.has(kind);
  return false;
}

export interface PermissionOptionInfo {
  optionId: string;
  kind: string;
  name: string;
}

export type PermissionReply =
  | { outcome: { outcome: "selected"; optionId: string } }
  | { outcome: { outcome: "cancelled" } };

/** Default auto-approve option resolution (mirrors the historical per-provider
 *  resolvers): prefer allow_always, then allow_once, then the first option. */
export function defaultAllowOptionId(options: PermissionOptionInfo[]): string {
  return (
    options.find((o) => o.kind === "allow_always")?.optionId
    ?? options.find((o) => o.kind === "allow_once")?.optionId
    ?? options[0]?.optionId
    ?? "allow"
  );
}

interface ParsedPermissionParams {
  sessionId?: string;
  toolCallId: string;
  title: string;
  kind?: string;
  options: PermissionOptionInfo[];
}

function parseParams(params: unknown): ParsedPermissionParams {
  const p = params as Record<string, unknown> | undefined;
  const toolCall = p?.toolCall as Record<string, unknown> | undefined;
  const rawOptions = (p?.options as Array<Record<string, unknown>>) ?? [];
  return {
    sessionId: typeof p?.sessionId === "string" ? p.sessionId : undefined,
    toolCallId: typeof toolCall?.toolCallId === "string" ? toolCall.toolCallId : "",
    title: typeof toolCall?.title === "string" ? toolCall.title : "",
    kind: typeof toolCall?.kind === "string" ? toolCall.kind : undefined,
    options: rawOptions
      .filter((o) => typeof o?.optionId === "string")
      .map((o) => ({
        optionId: o.optionId as string,
        kind: typeof o.kind === "string" ? o.kind : "",
        name: typeof o.name === "string" ? o.name : "",
      })),
  };
}

interface PendingGate {
  reply: (result: PermissionReply) => void;
  timer: NodeJS.Timeout;
  sessionId?: string;
  title: string;
}

export interface ApprovalGateOptions {
  /** Emit an event line to the Swift app. `sessionId` (when known) lets the
   *  caller attach a sessionKey for per-window routing. */
  emit: (msg: Record<string, unknown>, sessionId?: string) => void;
  logErr: (msg: string) => void;
  timeoutMs?: number;
  /** Test seam — defaults to reading FAZM_APPROVAL_MODE per request, so the
   *  mode is fixed for the bridge's lifetime (toggling restarts the bridge). */
  getMode?: () => ApprovalMode;
}

export const APPROVAL_TIMEOUT_MS = 300_000;

export class ApprovalGate {
  private readonly pending = new Map<string, PendingGate>();
  private seq = 0;
  private readonly emit: ApprovalGateOptions["emit"];
  private readonly logErr: (msg: string) => void;
  private readonly timeoutMs: number;
  private readonly getMode: () => ApprovalMode;

  constructor(opts: ApprovalGateOptions) {
    this.emit = opts.emit;
    this.logErr = opts.logErr;
    this.timeoutMs = opts.timeoutMs ?? APPROVAL_TIMEOUT_MS;
    this.getMode = opts.getMode ?? (() => currentApprovalMode());
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  /** First pending gate's title (diagnostics / getState). */
  get firstPendingTitle(): string | undefined {
    const first = this.pending.values().next();
    return first.done ? undefined : first.value.title;
  }

  /**
   * Handle a `session/request_permission` server request. Either replies
   * immediately (auto-approve) or parks the reply behind a `permission_request`
   * event + `permission_response` command round-trip with Swift.
   *
   * `provider` namespaces the gate id — each provider subprocess has its own
   * JSON-RPC id counter, so raw ids collide across providers.
   */
  handleRequest(provider: string, rpcId: number | string, params: unknown, reply: (result: PermissionReply) => void): void {
    const parsed = parseParams(params);
    const mode = this.getMode();
    if (!shouldGate(mode, parsed.kind)) {
      reply({ outcome: { outcome: "selected", optionId: defaultAllowOptionId(parsed.options) } });
      return;
    }

    const id = `${provider}:${rpcId}:${++this.seq}`;
    const timer = setTimeout(() => {
      if (!this.pending.delete(id)) return;
      this.logErr(`[approval-gate] timeout after ${Math.round(this.timeoutMs / 1000)}s — cancelling ${id} (${parsed.title})`);
      reply({ outcome: { outcome: "cancelled" } });
      this.emit({ type: "permission_timeout", id, reason: "timeout" }, parsed.sessionId);
    }, this.timeoutMs);
    timer.unref?.();

    this.pending.set(id, { reply, timer, sessionId: parsed.sessionId, title: parsed.title });
    this.logErr(
      `[approval-gate] gating ${id} (mode=${mode}, kind=${parsed.kind ?? "?"}, title=${parsed.title.slice(0, 80)})`,
    );
    this.emit(
      {
        type: "permission_request",
        id,
        toolCallId: parsed.toolCallId,
        title: parsed.title,
        kind: parsed.kind ?? "other",
        options: parsed.options,
      },
      parsed.sessionId,
    );
  }

  /** Swift's `permission_response`: select an option, or cancel. */
  handleResponse(id: string, optionId: string | undefined, cancelled: boolean | undefined): boolean {
    const gate = this.pending.get(id);
    if (!gate) {
      this.logErr(`[approval-gate] permission_response for unknown/expired id=${id} — ignoring`);
      return false;
    }
    this.pending.delete(id);
    clearTimeout(gate.timer);
    if (cancelled || !optionId) {
      this.logErr(`[approval-gate] ${id} cancelled by user`);
      gate.reply({ outcome: { outcome: "cancelled" } });
    } else {
      this.logErr(`[approval-gate] ${id} resolved with optionId=${optionId}`);
      gate.reply({ outcome: { outcome: "selected", optionId } });
    }
    return true;
  }

  /** Flush pending gates for one session as cancelled (interrupt / close_session). */
  cancelForSession(sessionId: string, reason: string): number {
    let n = 0;
    for (const [id, gate] of [...this.pending]) {
      if (gate.sessionId !== sessionId) continue;
      this.pending.delete(id);
      clearTimeout(gate.timer);
      gate.reply({ outcome: { outcome: "cancelled" } });
      this.emit({ type: "permission_timeout", id, reason }, sessionId);
      n++;
    }
    if (n > 0) this.logErr(`[approval-gate] flushed ${n} pending gate(s) for session ${sessionId.slice(0, 8)} (${reason})`);
    return n;
  }

  /** Flush ALL pending gates as cancelled (interrupt-all / bridge shutdown).
   *  Sessions must never hang on a gate that no one can answer anymore. */
  cancelAll(reason: string): number {
    let n = 0;
    for (const [id, gate] of [...this.pending]) {
      this.pending.delete(id);
      clearTimeout(gate.timer);
      gate.reply({ outcome: { outcome: "cancelled" } });
      this.emit({ type: "permission_timeout", id, reason }, gate.sessionId);
      n++;
    }
    if (n > 0) this.logErr(`[approval-gate] flushed ${n} pending gate(s) (${reason})`);
    return n;
  }
}
